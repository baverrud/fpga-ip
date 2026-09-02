# axis_mux

A parameterizable AXI4-Stream beat multiplexer with fair round-robin
arbitration and a shared output `axis_fifo`.

License: Zero-Clause BSD (0BSD)

## Features

- VHDL-2008 implementation with a configurable number of input sources.
- AXI4-Stream `tdata`, `tvalid`, and `tready` only.
- Fair round-robin arbitration across all input sources.
- One-beat holding slot per input source.
- Shared output `axis_fifo` for burst absorption and registered downstream
  flow control.
- Output FIFO occupancy monitor.
- Synchronous active-low reset.
- Comprehensive self-checking testbench.
- Small hand-editable smoke-test testbench.
- UVVM VVC testbench with deterministic, stalled, reset, and randomized cases.
- VHDL synthesis wrapper for standalone packaging.

## Interface

### Generics

| Generic | Type | Default | Description |
|---|---|---:|---|
| `GC_NUM_INPUTS` | `positive` | 4 | Number of independent input streams. |
| `GC_TDATA_WIDTH` | `positive` | 32 | Width of every `tdata` payload. |
| `GC_FIFO_DEPTH` | `positive range 2 to positive'high` | 8 | Capacity of the shared output FIFO. |

### Ports

| Port | Direction | Width | Description |
|---|---|---|---|
| `aclk` | in | 1 | Common rising-edge clock. |
| `aresetn` | in | 1 | Synchronous active-low reset. |
| `s_axis_tdata` | in | `GC_NUM_INPUTS` x `GC_TDATA_WIDTH` | Payload from each input source. |
| `s_axis_tvalid` | in | `GC_NUM_INPUTS` | Valid flag for each input source. |
| `s_axis_tready` | out | `GC_NUM_INPUTS` | Ready flag for each input source. |
| `m_axis_tdata` | out | `GC_TDATA_WIDTH` | Merged output payload. |
| `m_axis_tvalid` | out | 1 | Merged output valid flag. |
| `m_axis_tready` | in | 1 | Downstream output ready flag. |
| `fifo_count` | out | `log2ceil(GC_FIFO_DEPTH) + 1` | Occupancy of the shared output FIFO. |

Every transfer is accepted only on a rising clock edge where both the source
`valid` and sink `ready` are high. Input array indexes run from `0` through
`GC_NUM_INPUTS - 1`.

## Arbitration Contract

The mux is a beat multiplexer. It does not have `tlast`, packet IDs, or any
other packet boundary signal.

- After reset, input zero has the first opportunity to win.
- After a successful transfer from input `i` into the output FIFO, arbitration
  starts at input `i + 1`, wrapping to zero.
- Only one input holding slot is selected for each output FIFO write.
- An input source that is not selected may remain valid; its payload is stored
  in its own holding slot when its input handshake completes.
- A selected input remains represented by its holding slot until the output
  FIFO accepts it.
- If several sources remain continuously active, accepted beats follow cyclic
  round-robin order.
- If only one source is active, it can sustain output line rate after the
  initial holding-slot fill.
- Because `tlast` is absent, beats from different packets can be interleaved.
  Applications requiring packet atomicity must add packet framing or use a
  packet-aware arbiter.

The `fifo_count` port reports only the shared output FIFO occupancy. It does
not include beats waiting in the per-input holding slots.

## Architecture

```text
  input 0 tdata/valid  ----+                         +-------------------+
  input 0 ready       <----|                         |                   |
  input 1 tdata/valid  ----|--> holding slots -----> |   output FIFO     |----> m_axis_tdata
  input 1 ready       <----|    round-robin          |   (axis_fifo)      |----> m_axis_tvalid
  input N tdata/valid  ----+    arbitration          |                   |<---- m_axis_tready
  input N ready       <----------------------------- +-------------------+
```

### Input Holding Slots

Each input has one registered slot containing `valid` and `data`.

- An empty slot asserts that input's `tready`.
- A selected slot can be refilled on the same edge that its previous beat is
  accepted by the output FIFO.
- A full, unselected slot holds its data and deasserts its input `tready`.
- Reset clears every slot.

This structure prevents a stalled output from allowing a different input to
change the selected payload. It also gives each source independent storage,
so simultaneous requests can be captured before arbitration drains them.

### Round-Robin Arbiter

The registered `rr_pointer` records the most recently accepted input. The
combinational arbitration scan starts at the next input and wraps around the
input array. The pointer changes only when the output FIFO accepts a beat,
which means downstream backpressure cannot consume arbitration turns.

### Output FIFO

The output path instantiates the existing `axis_fifo` IP. The FIFO provides:

- First-word fall-through output data.
- Registered `tvalid` and `tready` flow control.
- Burst storage between the mux and downstream consumer.
- A FIFO occupancy monitor.

The output FIFO has its own registered flow-control latency. Testbenches must
use valid/ready handshakes instead of assuming a fixed cycle count.

## File Structure

```text
axis_mux/
├── README.md
├── rtl/
│   ├── axis_mux.vhd
├── top/
│   └── axis_mux_top.vhd
├── scripts/
│   ├── vhdl.f
│   └── uvvm.f
└── tb/
    ├── axis_mux_tb.vhd
    ├── axis_mux_simple_tb.vhd
    ├── axis_mux_uvvm_th.vhd
    └── axis_mux_uvvm_tb.vhd
```

## Instantiation

The synthesis wrapper is the recommended top-level interface. The declaration
and port map below are complete and can be copied into a VHDL architecture.

```vhdl
library ieee;
use ieee.std_logic_1164.all;
use work.util_pkg.all;

architecture example of your_design is
  constant C_NUM_INPUTS  : positive := 4;
  constant C_TDATA_WIDTH : positive := 32;
  constant C_FIFO_DEPTH  : positive := 8;

  signal aclk    : std_logic;  -- common rising-edge clock
  signal aresetn : std_logic;  -- synchronous active-low reset

  signal s_axis_tdata  : slv_array_t(0 to C_NUM_INPUTS-1)(C_TDATA_WIDTH-1 downto 0);  -- input payloads
  signal s_axis_tvalid : std_logic_vector(0 to C_NUM_INPUTS-1);  -- input valid flags
  signal s_axis_tready : std_logic_vector(0 to C_NUM_INPUTS-1);  -- input ready flags

  signal m_axis_tdata  : std_logic_vector(C_TDATA_WIDTH-1 downto 0);  -- merged payload
  signal m_axis_tvalid : std_logic;  -- merged output valid
  signal m_axis_tready : std_logic;  -- downstream ready
  signal fifo_count    : std_logic_vector(log2ceil(C_FIFO_DEPTH) downto 0);  -- output FIFO occupancy
begin

  u_axis_mux : entity work.axis_mux_top
    generic map (
      GC_NUM_INPUTS  => C_NUM_INPUTS,
      GC_TDATA_WIDTH => C_TDATA_WIDTH,
      GC_FIFO_DEPTH  => C_FIFO_DEPTH
    )
    port map (
      aclk          => aclk,
      aresetn       => aresetn,
      s_axis_tdata  => s_axis_tdata,
      s_axis_tvalid => s_axis_tvalid,
      s_axis_tready => s_axis_tready,
      m_axis_tdata  => m_axis_tdata,
      m_axis_tvalid => m_axis_tvalid,
      m_axis_tready => m_axis_tready,
      fifo_count    => fifo_count
    );

end architecture example;
```

### Synthesis Wrapper

Use [top/axis_mux_top.vhd](top/axis_mux_top.vhd) as the synthesis and
packaging wrapper. The core implementation is
[rtl/axis_mux.vhd](rtl/axis_mux.vhd).

## Verification

### Comprehensive VHDL Testbench

`axis_mux_tb.vhd` is the default regression test. It checks:

- Reset idle behavior and empty output behavior.
- Independent transfers from every configured input.
- Simultaneous requests and deterministic round-robin ordering.
- Repeated fair service of all sources.
- Output data and valid stability during downstream stalls.
- Input holding-slot backpressure and the output FIFO full boundary.
- In-flight reset flushing of queued data.
- Post-reset recovery and absence of stale pre-reset data.
- Configurations with one input, two-deep FIFO, many inputs, and 512-bit data.

### Simple Testbench

`axis_mux_simple_tb.vhd` is intentionally small and easy to edit. It sends one
beat from two sources and checks the expected round-robin order. It is a
starting point for waveform-driven experiments, not a replacement for the
comprehensive regression.

### UVVM Testbench

`axis_mux_uvvm_th.vhd` is the structural harness. It instantiates three input
AXI-Stream master VVCs, one output slave VVC, the DUT, and a deterministic
output-stall override.

`axis_mux_uvvm_tb.vhd` is the portless sequencer. It covers:

- Simultaneous source requests and round-robin ordering.
- Repeated wrap-around fairness rounds.
- Forced output stalls with stable data and valid checks.
- Queued-data reset flushing and post-reset recovery.
- Randomized source valid and output ready gaps.

The UVVM manifest uses a maximum 256-bit payload for its wide configuration,
because the precompiled AXI-Stream VIP has a 256-bit payload limit. The direct
VHDL testbench covers 512-bit payloads.

### Commands

Run from the `sub/fpga-ip` repository root after initializing the toolchain.
ModelSim 2020.1 (`m20`) is the default simulator for this VHDL-2008 IP:

```text
cmd.exe /c "m20 & run axis_mux vhdl modelsim"
cmd.exe /c "m20 & run axis_mux vhdl modelsim --tb all"
cmd.exe /c "m20 & run axis_mux uvvm modelsim --tb all"
cmd.exe /c "v23 & run axis_mux vhdl vivado"
```

The VHDL synthesis flow compiles `axis_mux_top.vhd` and the reused
`axis_fifo.vhd`. UVVM runs require precompiled UVVM libraries and are skipped by
XSim because XSim does not provide the UVVM framework libraries.

All automated artifacts are written below `axis_mux/.runs/`.
