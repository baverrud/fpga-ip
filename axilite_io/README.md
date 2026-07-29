# axilite_io — AXI4-Lite Slave to Register & Stream Bridge

A compact, parameterizable AXI4-Lite slave module that maps CPU-visible memory-mapped
transactions to three resource types: **registered outputs**, **unregistered inputs**,
and **AXI-Stream** push/pop ports. Designed as a lightweight control plane for
FPGA IP where a microcontroller (or any AXI4-Lite master) needs to read/write
status/control registers and transfer data through streaming interfaces.

---

## Features

- **Single-beat AXI4-Lite slave** — 16-bit address, 32-bit data, standard 5-channel
  handshake (AW, W, B, AR, R).
- **Output registers** — `NUM_ODATA` × 32-bit registered outputs, writable via
  AXI4-Lite with byte-enable support (`wstrb`). Readback returns the current value.
- **Input ports** — `NUM_IDATA` × 32-bit unregistered inputs, readable from the
  AXI4-Lite bus. Driven externally; not stored internally.
- **AXI-Stream outputs** — `NUM_OSTREAM` streaming master channels. Writing to the
  stream address region drives `m_axis_tdata` and pulses `m_axis_tvalid`.
- **AXI-Stream inputs** — `NUM_ISTREAM` streaming slave channels. Reading from the
  stream address region captures `s_axis_tdata` and pulses `s_axis_tready` to
  consume one beat.
- **0BSD Licensed** — Free to use, modify, and distribute.

---

## Parameters

| Parameter      | Type | Default | Description                            |
|----------------|------|---------|----------------------------------------|
| `NUM_ODATA`    | int  | 2       | Number of output register slots (× 32-bit) |
| `NUM_IDATA`    | int  | 2       | Number of input ports (× 32-bit)       |
| `NUM_OSTREAM`  | int  | 2       | Number of AXI-Stream master channels    |
| `NUM_ISTREAM`  | int  | 2       | Number of AXI-Stream slave channels     |

---

## Ports

### Clock & Reset

| Port             | Direction | Width | Description                     |
|------------------|-----------|-------|---------------------------------|
| `aclk`           | in        | 1     | Global clock, rising-edge active |
| `aresetn`        | in        | 1     | Synchronous reset, active-low    |

### AXI4-Lite Write Address Channel (AW)

| Port             | Direction | Width | Description                     |
|------------------|-----------|-------|---------------------------------|
| `s_axi_awaddr`   | in        | 16    | Write address                   |
| `s_axi_awprot`   | in        | 3     | Protection (unused by core)     |
| `s_axi_awvalid`  | in        | 1     | Address valid                   |
| `s_axi_awready`  | out       | 1     | Address ready                   |

### AXI4-Lite Write Data Channel (W)

| Port             | Direction | Width   | Description                     |
|------------------|-----------|---------|---------------------------------|
| `s_axi_wdata`    | in        | 4×8     | Write data (32-bit, packed)     |
| `s_axi_wstrb`    | in        | 4       | Byte enables: bit `[i]` qualifies byte lane `i` |
| `s_axi_wvalid`   | in        | 1       | Write data valid                |
| `s_axi_wready`   | out       | 1       | Write data ready                |

### AXI4-Lite Write Response Channel (B)

| Port             | Direction | Width | Description                     |
|------------------|-----------|-------|---------------------------------|
| `s_axi_bresp`    | out       | 2     | Write response (always OKAY = 0)|
| `s_axi_bvalid`   | out       | 1     | Response valid                  |
| `s_axi_bready`   | in        | 1     | Response ready                  |

### AXI4-Lite Read Address Channel (AR)

| Port             | Direction | Width | Description                     |
|------------------|-----------|-------|---------------------------------|
| `s_axi_araddr`   | in        | 16    | Read address                    |
| `s_axi_arprot`   | in        | 3     | Protection (unused by core)     |
| `s_axi_arvalid`  | in        | 1     | Address valid                   |
| `s_axi_arready`  | out       | 1     | Address ready                   |

### AXI4-Lite Read Data Channel (R)

| Port             | Direction | Width | Description                     |
|------------------|-----------|-------|---------------------------------|
| `s_axi_rdata`    | out       | 32    | Read data                       |
| `s_axi_rresp`    | out       | 2     | Read response (always OKAY = 0) |
| `s_axi_rvalid`   | out       | 1     | Read data valid                 |
| `s_axi_rready`   | in        | 1     | Read data ready                 |

### Data I/O

| Port     | Direction | Width                     | Description                              |
|----------|-----------|---------------------------|------------------------------------------|
| `o_data` | out       | `[NUM_ODATA-1:0][31:0]`   | Registered outputs (AXI-Lite writable)    |
| `i_data` | in        | `[NUM_IDATA-1:0][31:0]`   | Unregistered inputs (AXI-Lite readable)   |

### AXI-Stream Master (Output) Channels

| Port              | Direction | Width                     | Description                              |
|-------------------|-----------|---------------------------|------------------------------------------|
| `m_axis_tdata`    | out       | 32                        | Stream data output                       |
| `m_axis_tvalid`   | out       | `[NUM_OSTREAM-1:0]`        | Per-channel stream valid                 |
| `m_axis_tready`   | —         | —                         | **Not implemented** (see *Backpressure* below) |

### AXI-Stream Slave (Input) Channels

| Port              | Direction | Width                     | Description                              |
|-------------------|-----------|---------------------------|------------------------------------------|
| `s_axis_tdata`    | in        | `[NUM_ISTREAM-1:0][31:0]` | Per-channel stream data input             |
| `s_axis_tvalid`   | —         | —                         | **Not implemented** (see *Backpressure* below) |
| `s_axis_tready`   | out       | `[NUM_ISTREAM-1:0]`       | Per-channel stream ready (consumes one beat) |

---

## Address Map

The AXI4-Lite address space is partitioned into four 16 kB regions decoded
from `addr[15:14]`:

| `addr[15:14]` | Address Range   | Region               | Access      | Description                                   |
|:-------------:|-----------------|----------------------|-------------|-----------------------------------------------|
| `2'b00`       | `0x0000–0x3FFF` | **Output Registers** | Read/Write  | Access `o_data[slot]`. Byte-enable writes via `wstrb`. |
| `2'b01`       | `0x4000–0x7FFF` | **Stream Master**    | Write-only  | Push data to `m_axis_tdata` and assert the selected `m_axis_tvalid`. |
| `2'b10`       | `0x8000–0xBFFF` | **Input Ports**      | Read-only   | Read `i_data[slot]`.                           |
| `2'b11`       | `0xC000–0xFFFF` | **Stream Slave**     | Read-only   | Pop data from selected `s_axis_tdata` and assert `s_axis_tready`. |

### Sub-Index Decoding

Within each region, the per-slot index is extracted from the address
using `$clog2` to compute the minimum required address bits:

| Region            | Slot Index Field                         | Max Slots |
|-------------------|------------------------------------------|-----------|
| Output Registers  | `addr[$clog2(NUM_ODATA)+1:2]`            | 4096      |
| Stream Master     | `addr[$clog2(NUM_OSTREAM)+1:2]`          | 4096      |
| Input Ports       | `addr[$clog2(NUM_IDATA)+1:2]`            | 4096      |
| Stream Slave      | `addr[$clog2(NUM_ISTREAM)+1:2]`          | 4096      |

Address bits `[1:0]` are not used for slot selection (word-aligned access).
For the output register region, address bits below `$clog2(NUM_ODATA)+1:2`
are unused, so registers are spaced at the natural word distance determined
by `NUM_ODATA`.

---

## Operation

### Write Transaction

A write completes in two clock cycles:

1. **Cycle 1** — The CPU asserts `s_axi_awvalid` and `s_axi_wvalid`
   simultaneously. The core asserts `s_axi_awready` and `s_axi_wready` in
   the same cycle, captures the data, and schedules the write response.
2. **Cycle 2** — `s_axi_bvalid` asserts. The CPU responds with
   `s_axi_bready` to clear the response.

> **Note:** This core requires **both** `awvalid` and `wvalid` to be asserted
> in the same cycle. Unlike full AXI4-Lite, it does not support the case
> where AW and W arrive independently. If only one is asserted, the write
> will not be accepted — neither `awready` nor `wready` will assert.

### Read Transaction

A read also takes two clock cycles:

1. **Cycle 1** — The CPU asserts `s_axi_arvalid`. The core captures the
   address, asserts `s_axi_arready`, multiplexes the selected data onto
   `s_axi_rdata`, and schedules the read response.
2. **Cycle 2** — `s_axi_rvalid` asserts. The CPU responds with
   `s_axi_rready` to clear the response.

### Back-to-Back Transactions

The core will not accept a new write while `r.bvalid` is still asserted,
nor a new read while `r.rvalid` is still asserted. The CPU must complete
the response handshake (`bready` / `rready`) before issuing the next
transaction of the same type. Writes and reads are otherwise independent
and can be interleaved.

---

## Stream Interface — Backpressure Model

The stream backpressure signals are **not implemented inside this core**.
They are instead exposed as external signals that the CPU polls directly:

### Stream Output (Master) — Push

- `m_axis_tready` is **not a port of this module** (commented out as
  `// NOT IMPLEMENTED` in the RTL).
- The external `m_axis_tready` signal from the downstream sink must be
  wired to a **GPIO input** visible to the CPU.
- **CPU sequence to push data:**
  1. Poll the GPIO input connected to `m_axis_tready`.
  2. When ready is high, write to address `0x4xxx`.
  3. The core drives `m_axis_tdata` and asserts `m_axis_tvalid` for the
     selected stream index for one clock cycle.
- If the CPU writes when the sink is not ready, the data is presented on
  `m_axis_tdata`/`m_axis_tvalid` regardless — the downstream must be
  tolerant or the CPU must check first.

### Stream Input (Slave) — Pop

- `s_axis_tvalid` is **not a port of this module** (commented out as
  `// NOT IMPLEMENTED` in the RTL).
- The external `s_axis_tvalid` signal from the upstream source must be
  wired to a **GPIO input** visible to the CPU.
- **CPU sequence to pop data:**
  1. Poll the GPIO input connected to `s_axis_tvalid`.
  2. When valid is high, read from address `0xCxxx`.
  3. The core asserts `s_axis_tready` for the selected stream index for
     one clock cycle, consuming one beat from the upstream source, and
     returns the data via `s_axi_rdata`.

> This polling-based model is suitable for low-throughput CPU-driven
> streaming. For high-throughput or DMA-driven streaming, add a dedicated
> AXI4-Stream FIFO (such as `axis_fifo`) between this core and the
> streaming endpoint, or replace this core with a full DMA engine.

---

## Reset and Initial Values

| Signal / Field  | Reset Value | Notes                              |
|-----------------|-------------|------------------------------------|
| `o_data` (all)  | `'0`        | All register outputs clear to zero |
| `s_axi_rdata`   | `'x`        | Unknown after reset — read returns X until a valid read populates it |
| `m_axis_tdata`  | `'x`        | Unknown after reset — driven to X when no write is active |
| `m_axis_tvalid` | `0`         | De-asserted after reset            |
| `s_axi_rvalid`  | `0`         | De-asserted after reset            |
| `s_axi_bvalid`  | `0`         | De-asserted after reset            |

The X defaults for `rdata` and `m_axis_tdata` are intentional: they
propagate unknown values in simulation if an uninitialized register is
read or a stream transaction fires spuriously, making it easier to detect
bugs.

---

## Limitations

| Limitation | Detail |
|---|---|
| **No DECERR** | Both `bresp` and `rresp` are always `OKAY` (2'b00). Accessing an unmapped address (regions 2 and 3 have no write decode; reads always return data) does not signal an error. |
| **No stream backpressure** | `m_axis_tready` and `s_axis_tvalid` are not module ports. The CPU must poll these externally. |
| **Simultaneous AW+W required** | The core ANDs `awvalid` and `wvalid` — they must be asserted in the same cycle for a write to be accepted. |
| **Fixed 32-bit data width** | `s_axi_wdata`, `m_axis_tdata`, and `s_axis_tdata` are all hardcoded to 32 bits. |
| **X on uninitialized reads** | `s_axi_rdata` defaults to `'x` after reset, which may cause X-propagation in gate-level simulation if read before a valid transaction. |
| **No transaction timeout** | If `s_axi_bready` or `s_axi_rready` never arrives, the core stalls on that channel until the handshake completes. |

---

## File Structure

```
axilite_io/
├── README.md                    # This file
├── rtl/
│   ├── axilite_io.sv            # Core RTL (SystemVerilog)
│   └── axilite_io.vhd           # VHDL translation (cycle-accurate)
├── tb/
│   ├── axilite_io_wrap.sv       # SV wrapper: packed arrays → flattened slv
│   ├── axilite_io_wrap.vhd      # VHDL wrapper: t_slv32_array → flattened slv
│   ├── axilite_io_harness.vhd   # Array-port wrapper (t_slv32_array ↔ flattened)
│   ├── axilite_io_th.vhd        # Test harness: adds FIFO loopback + status i_data
│   └── axilite_io_tb.vhd        # Shared TB (21 tests via axilite_io_th)
├── scripts/
│   ├── vhdl.f                   # File list — VHDL DUT + wrappers + TB
│   ├── sv.f                     # File list — SV DUT + wrappers + TB
│   ├── simulate.do              # ModelSim/Questa simulation script
│   └── wave.do                  # Waveform groups
```

Shared utilities live in `../common/rtl/util_pkg.vhd` (log2ceil, t_slv32_array, t_slv_array).

---

## Why Wrappers?

The VHDL and SV DUTs use incompatible port types for their multi-slot
data/stream arrays:

| DUT | Array port type | Example |
|-----|----------------|---------|
| `axilite_io.vhd` (VHDL) | `t_slv32_array(0 to N-1)` | `o_data : out t_slv32_array(0 to GC_NUM_ODATA-1)` |
| `axilite_io.sv` (SV) | Packed 2D array `[N-1:0][31:0]` | `output reg [NUM_ODATA-1:0][31:0] o_data` |

Neither representation can be directly instantiated from the other
language — VHDL's `std_logic_vector` is a 1D type, and SV's packed
arrays have no VHDL equivalent.  Each wrapper normalises to a common
flattened `std_logic_vector` interface so that **one VHDL testbench**
can drive whichever DUT is compiled for that run.

The hierarchy is:

```
axilite_io_tb
  └── axilite_io_th            (t_slv32_array ports + FIFO loopback)
        ├── axis_fifo x2       (m_axis → s_axis loopback)
        └── axilite_io_harness  (t_slv32_array ↔ flattened conversion)
              └── axilite_io_wrap (flattened slv ports, VHDL or SV)
                    └── axilite_io.vhd or axilite_io.sv

---

## Simulation & Verification

### Testbenches

| File | What it does |
|------|--------------|
| `tb/axilite_io_tb.vhd` | **Shared TB**: instantiates `axilite_io_th` which provides FIFO loopback and FIFO-status i_data. Runs 21 tests covering register access, byte strobes, stream push/pop, FIFO ordering, FIFO backpressure, reset state, back-to-back transactions, unmapped access, and consecutive-read stability. |
| `tb/axilite_io_th.vhd` | **Test harness**: wraps `axilite_io_harness`, adds AXI-Stream loopback FIFOs (axis_fifo) between m_axis and s_axis, and exposes FIFO status on dedicated i_data slots. |
| `tb/axilite_io_harness.vhd` | **Array-port wrapper**: converts between flattened `std_logic_vector` and `t_slv32_array`. No FIFOs — just array↔flattened conversion. |

### Running (from fpga-ip root)

| Test | Command |
|------|---------|
| VHDL DUT (via VHDL wrapper) | `run axilite_io vhdl modelsim` |
| SV DUT (via SV wrapper) | `run axilite_io sv modelsim` |

---

## Dual-Language Support

This core exists in both SystemVerilog (`axilite_io.sv`) and VHDL
(`axilite_io.vhd`) — selected via the `.f` file list at compile time.

### VHDL → SV Instantiation

Instantiating a VHDL entity from SV works **natively** with no wrapper:
```systemverilog
axilite_io #(
  .GC_NUM_ODATA  (2),
  .GC_NUM_IDATA  (2),
  .GC_NUM_OSTREAM(2),
  .GC_NUM_ISTREAM(2)
) dut_vhd (
  .aclk         (clk),
  .s_axi_awaddr (awaddr),
  .o_data       (vhdl_o_data),
  ...
);
```
- `std_logic` ↔ `logic` maps 1:1
- `std_logic_vector` ↔ `logic [N-1:0]` maps 1:1
- VHDL `t_slv32_array` ports connect to SV unpacked arrays
  (`logic [31:0] arr[0:N-1]`)

### SV → VHDL Instantiation

Instantiating an SV module from VHDL works for scalar and simple vector
ports. However, **parameterized packed 2D arrays** (`[N-1:0][31:0]`) can
cause Questa mixed-language type-mapping issues at elaboration.

A thin SV wrapper with flattened ports is provided:
`tb/axilite_io_wrap.sv`

| Original port | Wrapper port | VHDL connection type |
|---|---|---|
| `[3:0][7:0] s_axi_wdata` | `[31:0] s_axi_wdata` | `std_logic_vector(31 downto 0)` |
| `[N-1:0][31:0] o_data` | `[N*32-1:0] o_data` | `std_logic_vector(N*32-1 downto 0)` |
| `[N-1:0][31:0] i_data` | `[N*32-1:0] i_data` | `std_logic_vector(N*32-1 downto 0)` |
| `[N-1:0][31:0] s_axis_tdata` | `[N*32-1:0] s_axis_tdata` | `std_logic_vector(N*32-1 downto 0)` |

From VHDL:
```vhdl
axilite_io_wrap
  generic map (NUM_ODATA => 2, NUM_IDATA => 2, ...)
  port map (
    s_axi_wdata => wdata,        -- std_logic_vector(31 downto 0)
    o_data      => o_data_flat,  -- std_logic_vector(63 downto 0)
    ...
  );
```

### Mixed-Language Summary

| Direction | Works natively? | Notes |
|-----------|----------------|-------|
| VHDL in SV | ✅ Yes | No wrapper needed. All port types map cleanly. |
| SV in VHDL | ⚠️ With caveats | Scalar/vector ports work. Parameterized packed 2D array ports need a flattened wrapper (provided). |

---

## License

Zero-Clause BSD (0BSD) — See headers in individual source files.
