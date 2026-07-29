# axis_fifo — Safe, Parameterizable AXI4-Stream FIFO

A **First-Word Fall-Through (FWFT)** elastic buffer with Xilinx SRL inference,
simulation-safe non-power-of-2 depth support, registered handshaking for
timing isolation, and a fully self-contained VHDL-93 core (no external
dependencies).

---

## Features

- **FWFT (First-Word Fall-Through)** — The first written word appears on the
  master output without waiting for a read request.
- **Xilinx SRL Inference** — Depths > 2 map to SRL16E/SRL32E primitives;
  depth = 2 maps to a double-buffer register pair.
- **Non-Power-of-2 Depth Support** — Safely guarded simulation address
  decoding prevents out-of-range crashes on strict IEEE simulators.
- **Timing Isolation** — All flow-control flags (`tready`, `tvalid`) are
  fully registered, breaking combinational paths between upstream and
  downstream domains for maximum $F_{max}$.
- **AMBA AXI4-Stream Compliant Ports** — Directly compatible with Vivado
  IP integrator automatic packaging.
- **Occupancy Monitor** — `fifo_count` output port provides real-time
  occupancy level as an unsigned vector.
- **100% Self-Contained** — No external dependencies beyond IEEE standard
  libraries. The `log2ceil` utility is in the shared `util_pkg` under `common/`.
- **VHDL-93 Compliant** — Compatible with Xilinx Vivado block design tools
  and strict simulation environments.
- **Zero-Clause BSD (0BSD) License** — Free to use, modify, and distribute
  for any purpose.

---

## Interface

### Generics

| Generic          | Type      | Description                                              |
|------------------|-----------|----------------------------------------------------------|
| `GC_TDATA_WIDTH` | positive  | Width of the `tdata` bus (can pack data + sideband bits) |
| `GC_DATA_DEPTH`  | positive  | FIFO capacity (minimum 2, maximum `positive'high`)        |

### Ports

| Port             | Direction | Width                          | Description                              |
|------------------|-----------|--------------------------------|------------------------------------------|
| `aclk`           | in        | 1                              | Global clock, rising-edge active         |
| `aresetn`        | in        | 1                              | Synchronous reset, active-low            |
| `s_axis_tdata`   | in        | `GC_TDATA_WIDTH`               | Slave (write) data bus                   |
| `s_axis_tvalid`  | in        | 1                              | Slave write valid                        |
| `s_axis_tready`  | out       | 1                              | Slave ready (flow control)               |
| `m_axis_tdata`   | out       | `GC_TDATA_WIDTH`               | Master (read) data bus                   |
| `m_axis_tvalid`  | out       | 1                              | Master read valid                        |
| `m_axis_tready`  | in        | 1                              | Master ready (flow control)              |
| `fifo_count`     | out       | `log2ceil(GC_DATA_DEPTH) + 1`  | Current occupancy level (unsigned)       |

### AXI4-Stream Handshaking

All transfers follow the standard AXI4-Stream valid-ready protocol:

- A transfer occurs on the rising clock edge when both **valid** and
  **ready** are asserted.
- The source drives **valid** and holds it stable until **ready** asserts.
- The destination asserts **ready** when it can accept a transfer.

---

## Architecture

### Top-Level Structure

```
                      +-------------------+
                      |                   |
  s_axis_tdata   ---->|                   |-----> m_axis_tdata
  s_axis_tvalid  ---->|     axis_fifo     |-----> m_axis_tvalid
  s_axis_tready  <----|                   |<----- m_axis_tready
                      |                   |-----> fifo_count
                      +-------------------+
```

### Two-Process FSM Design

The core uses a classic two-process register-transfer style:

1. **`p_logic`** — Combinatorial process that computes next-state values
   based on current state (`r`) and input signals. It handles:
   - Shift-register data management
   - Index pointer increment/decrement
   - Flow-control flag generation (`tready`, `tvalid`)
   - Address guard for empty-state reads

2. **`p_reg`** — Synchronous process that updates the state register
   on each rising clock edge, with active-low synchronous reset.

### Shift-Register Implementation

The storage array is modelled as:

```vhdl
type t_srl is array (0 to GC_DATA_DEPTH-1) of
  std_logic_vector(GC_TDATA_WIDTH-1 downto 0);
```

On a write, the entire array shifts forward by one position and new data
is placed at index 0:

```vhdl
v.fifo_data(1 to GC_DATA_DEPTH-1) := v.fifo_data(0 to GC_DATA_DEPTH-2);
v.fifo_data(0)                    := s_axis_tdata;
```

This VHDL shift pattern maps natively to Xilinx SRL primitives.

### Timing Isolation

All flow-control signals are **registered** (not combinatorial):

| Signal | Source | Latency |
|--------|--------|---------|
| `s_axis_tready` | Registered from `p_reg` | 1 clock cycle |
| `m_axis_tvalid` | Registered from `p_reg` | 1 clock cycle |
| `m_axis_tdata` | Combinatorial from `r.fifo_data` | 0 (FWFT) |
| `fifo_count` | Combinatorial from `r.fifo_index` | 0 |

This means:
- `tready` and `tvalid` change only on clock edges, never in response to
  input changes within a cycle.
- No combinational path exists between `s_axis_tvalid → m_axis_tvalid`
  or `m_axis_tready → s_axis_tready`.
- This maximizes $F_{max}$ by breaking potential critical paths across
  the FIFO boundary.

### First-Word Fall-Through (FWFT)

`m_axis_tdata` is driven combinatorially from the current read pointer:

```vhdl
m_axis_tdata <= r.fifo_data(read_index);
```

The `m_axis_tvalid` flag indicates whether that data is valid. After
reset (or when empty), `m_axis_tvalid` is `0` and `read_index` is
guarded to 0 to prevent out-of-range array access.

---

## SRL Inference Notes

### Critical: Array Reset Don't-Cares

For Xilinx synthesis to map the storage array to SRL primitives, the
array **must not** have a hardware reset network. This is achieved by
initializing `fifo_data` elements to **don't-care** (`'-'`) in the reset
constant:

```vhdl
constant C_REC_DEFAULT : t_rec := (
  fifo_data      => (others => (others => '-')),  -- SRL-friendly
  fifo_index     => to_signed(-1, ...),
  s_axis_tready  => '1',
  m_axis_tvalid  => '0');
```

If `fifo_data` were initialized to `(others => '0')`, the synthesis tool
would infer FDRE flip-flops with reset inputs for every storage bit,
consuming significantly more logic resources and increasing routing
congestion.

### Depth Mapping

| `GC_DATA_DEPTH` | Inferred Primitive |
|-----------------|-------------------|
| 2 | Double-buffer (FDRE pair) |
| 3–16 | SRL16E |
| 17–32 | SRL32E |
| 33–64 | Cascaded SRL32E + SRL16E |
| > 64 | Cascaded SRL32Es |

### Simulation Address Guard

When the FIFO is empty, `r.fifo_index = -1` (signed). A direct array
access with index -1 would crash strict IEEE simulators. The guard
clamps the read index:

```vhdl
if r.fifo_index < 0 then
  read_index := 0;
else
  read_index := to_integer(r.fifo_index);
end if;
```

---

## File Structure

```
axis_fifo/
├── rtl/
│   ├── axis_fifo_pkg.vhd           # Shared utility package (log2ceil)
│   ├── axis_fifo.vhd               # Production VHDL core (VHDL-93)
│   ├── axis_fifo.sv                # Production SystemVerilog core
│   └── axis_fifo_top.vhd           # Synthesis top wrapper
├── tb/
│   ├── axis_fifo_tb.vhd            # Self-contained testbench (VHDL-93)
│   ├── axis_fifo_uvvm_th.vhd       # UVVM test harness (VHDL-2008)
│   └── axis_fifo_uvvm_tb.vhd       # UVVM sequencer (VHDL-2008)
├── scripts/
│   ├── vhdl.f                      # VHDL file list (simple TB)
│   ├── sv.f                        # SystemVerilog file list (simple TB)
│   ├── uvvm.f                      # UVVM file list (VHDL, language-agnostic)
│   ├── sv-uvvm.f                   # UVVM file list (SystemVerilog core)
│   └── wave.do                     # Waveform configuration (GUI)
└── README.md                       # This file
```

> All simulation artifacts are transient and land in `modelsim/`, `xsim/`,
> or `vivado/` working directories outside version control.

---

## Simulation Guide

### Prerequisites

- A supported VHDL simulator (ModelSim, Questa, Vivado Simulator, etc.)
  with the `vsim` executable available on the system PATH.
- **UVVM libraries** — Pre-compiled `uvvm_util`, `uvvm_vvc_framework`,
  and `bitvis_vip_axistream` must be available in the simulator
  installation.

### Quick Start

From the repository root, use the unified launcher:

```
run axis_fifo vhdl  modelsim          # ModelSim VHDL (batch)
run axis_fifo uvvm  modelsim          # ModelSim UVVM (batch)
run axis_fifo sv    modelsim          # ModelSim SV (batch)
run axis_fifo vhdl  xsim              # XSim VHDL (batch)
run axis_fifo sv    xsim              # XSim SV (batch)
run axis_fifo vhdl  vivado            # Vivado VHDL synthesis (batch)
run axis_fifo sv    vivado            # Vivado SV synthesis (batch)
run axis_fifo all                     # All batch permutations
run axis_fifo all   modelsim          # All .f files, ModelSim only
run axis_fifo clean                   # Remove all artifacts
```

> **Prerequisites:** Initialize your EDA tool environment before running any
> scripts. Environment/toolchain setup is user-managed.

### What Each File List Does

| File List | Compiles | Simulates | Output | Notes |
|-----------|----------|-----------|--------|-------|
| `vhdl.f` | `axis_fifo_pkg.vhd` + `axis_fifo.vhd` + `axis_fifo_top.vhd` + `axis_fifo_tb.vhd` | VHDL simple tests | Console | Works in modelsim, xsim, vivado |
| `sv.f` | `axis_fifo_pkg.vhd` + `axis_fifo.sv` + `axis_fifo_top.vhd` + `axis_fifo_tb.vhd` | SystemVerilog simple tests | Console | Works in modelsim, xsim, vivado |
| `uvvm.f` | `axis_fifo_pkg.vhd` + `axis_fifo.vhd` + UVVM harness/sequencer | UVVM tests | Console + UVVM report | Modelsim only (no [top] — skipped by vivado) |
| `uvvm_util.f` | `axis_fifo_pkg.vhd` + `axis_fifo.vhd` + `axis_fifo_uvvm_util_tb.vhd` | Direct-DUT util-only checks | Console + UVVM alert report | Works in modelsim; stock xsim flow currently fails because `uvvm_util` is not compiled/mapped |
| `sv-uvvm.f` | `axis_fifo_pkg.vhd` + `axis_fifo.sv` + UVVM harness/sequencer | UVVM tests (SV core) | Console + UVVM report | Modelsim only (no [top] — skipped by vivado) |

---

## Testbenches

### Simple Testbench (`axis_fifo_tb`)

A self-contained VHDL-93 testbench with no external dependencies. Tests:

| Test Case | Description |
|-----------|-------------|
| **Reset** | 1-cycle `aresetn` assertion; verifies `fifo_count = 0` |
| **Fill** | Writes 3 unique values (`0xA1`, `0xB2`, `0xC3`) to depth-3 FIFO |
| **FWFT Verify** | Confirms first word appears at output without read request |
| **Simultaneous Push-Pop** | Writes and reads on the same clock cycle |
| **Drain** | Reads back all 4 values (including simultaneous push) in order |
| **Corner 1: Empty Read** | Asserts `m_axis_tready` when empty — ensures no crash |
| **Corner 2: Full Write** | Asserts `s_axis_tvalid` when full — ensures no data corruption |
| **Corner 3: Single-Cycle Transit** | Pushes and immediately pops each item back-to-back |

### UVVM Testbench (`axis_fifo_uvvm_tb`)

An advanced VVC-based testbench using the UVVM framework with AXI-Stream
VIP. Tests:

| Test Phase | Description |
|------------|-------------|
| **Fill** | Pushes `C_DEPTH` items with randomized back-pressure (30% valid/ready drop) |
| **Drain & Verify** | Pops and checks each item via `axistream_expect` |
| **Interleaved** | Single-word push/pop sequences with concurrent VVC execution |
| **Burst** | Queues 4 pushes, then 4 expects — verifies back-to-back throughput |
| **Negative: Stall Timeout** | Expects data from idle interface — verifies alert counting |
| **5 Random Seeds** | Entire suite repeated with different randomization seeds |

---

## Resource Usage

The core uses minimal logic:

| Resource | Depth = 4, Width = 8 | Depth = 16, Width = 32 |
|----------|----------------------|------------------------|
| SRL LUTs | 4 | 64 |
| Flip-Flops | ~6 | ~8 |
| Carry Logic | 0 | 0 |
| Block RAM | 0 | 0 |

The flip-flop count is constant (index counter + flow-control flags)
regardless of depth or width. All storage maps to SRL primitives.

---

## Licensing

Zero-Clause BSD (0BSD)

```
Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
```

---

## Revision History

| Revision | Date | Description |
|----------|------|-------------|
| 1.00 | 2026-07-17 | Initial release: FWFT SRL-based FIFO with AMBA AXI4-Stream ports, simulation guard, UVVM testbench, and documentation |
| 0.9 | — | Original `srl_fifo` baseline (predecessor) |
