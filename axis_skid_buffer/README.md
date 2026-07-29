# axis_skid_buffer — AXI4-Stream Skid Buffer

A **2-deep pipeline register + skid register** that absorbs one beat of
backpressure on an AXI4-Stream interface, with a direct bypass path when
no stall occurs. Provides maximum $F_{max}$ on the data output path by
driving `m_axis_tdata` directly from the pipeline register Q output with
no intervening combinational logic.

Zero-Clause BSD (0BSD) license.

---

## Features

- **Two-stage storage** — Pipeline register (output stage) + skid register
  (overflow stage) absorb exactly one backpressure beat.
- **Bypass path** — When no stall, data flows pipeline-reg $\rightarrow$
  output with zero combinational delay beyond the register Q output.
- **Three-state FSM** (`EMPTY` / `ONE` / `TWO`) for cycle-accurate
  handshake control.
- **Fully registered handshake outputs** — `s_axis_tready` and
  `m_axis_tvalid` are driven from state register bits, with no
  combinational cascade from upstream signals.
- **AMBA AXI4-Stream Compliant Ports** — Directly compatible with Vivado
  IP integrator automatic packaging.
- **100% Self-Contained** — No external dependencies (the util_pkg
  `log2ceil` function is not needed since depth is fixed at 2).
- **Zero-Clause BSD (0BSD) License** — Free to use, modify, and
  distribute for any purpose.

---

## Interface

### Generics

| Generic          | Type      | Description                    |
|------------------|-----------|--------------------------------|
| `GC_TDATA_WIDTH` | positive  | Width of the `tdata` bus       |

### Ports

| Port             | Direction | Width                  | Description                              |
|------------------|-----------|------------------------|------------------------------------------|
| `aclk`           | in        | 1                      | Global clock, rising-edge active         |
| `aresetn`        | in        | 1                      | Synchronous reset, active-low            |
| `s_axis_tdata`   | in        | `GC_TDATA_WIDTH`       | Slave (write) data bus                   |
| `s_axis_tvalid`  | in        | 1                      | Slave write valid                        |
| `s_axis_tready`  | out       | 1                      | Slave ready (flow control)               |
| `m_axis_tdata`   | out       | `GC_TDATA_WIDTH`       | Master (read) data bus                   |
| `m_axis_tvalid`  | out       | 1                      | Master read valid                        |
| `m_axis_tready`  | in        | 1                      | Master ready (flow control)              |

### AXI4-Stream Handshaking

All transfers follow the standard AXI4-Stream valid-ready protocol:

- A transfer occurs on the rising clock edge when both **valid** and
  **ready** are asserted.
- The source drives **valid** and holds it stable until **ready** asserts.
- The destination asserts **ready** when it can accept a transfer.

---

## Architecture

### Block Diagram

```
                     +------------------------------+
                     |                              |
  s_axis_tdata ----->|         +--------+           |
                     |         |        |           |
                     |  +----->| SKID   |           |
                     |  |      | REG    |           |
                     |  |      +--------+           |
                     |  |          |                |
                     |  |    +-----v----+           |
                     |  |    |          |           |
                     |  +----|  MUX     |           |
                     |       |          |           |
                     |       +----+-----+           |
                     |            |                 |
                     |    +-------v-------+         |
                     |    |               |         |
                     |    |  PIPELINE REG |         |--------> m_axis_tdata
                     |    |               |         |
                     |    +---------------+         |
  s_axis_tvalid ---->|                              |--------> m_axis_tvalid
  s_axis_tready <----|   FSM CONTROL                |
                     |   (EMPTY/ONE/TWO)            |
  m_axis_tready ---->|                              |
                     +------------------------------+
```

### Three-State FSM

| State  | `s_axis_tready` | `m_axis_tvalid` | Meaning                        |
|--------|-----------------|------------------|--------------------------------|
| EMPTY  | 1               | 0                | No data in buffer              |
| ONE    | 1               | 1                | Pipeline valid, skid empty     |
| TWO    | 0               | 1                | Pipeline and skid both valid   |

**State transitions:**

- **EMPTY + input valid** $\rightarrow$ **ONE**: data captured into
  pipeline register.
- **ONE + downstream ready**: data consumed. If new input valid, reload
  pipeline (stay ONE); otherwise go EMPTY.
- **ONE + downstream stall + input valid** $\rightarrow$ **TWO**: pipeline
  data saved into skid, new data captured into pipeline.
- **TWO + downstream ready** $\rightarrow$ **ONE**: skid data shifts into
  pipeline, pipeline data consumed.

### Timing Paths

| Output           | Source                        | Combinational delay       |
|------------------|-------------------------------|---------------------------|
| `m_axis_tdata`   | `pipe_data` register Q        | ~0 (register-to-wire)     |
| `m_axis_tvalid`  | `state(0)` register Q bit     | ~0 (register-to-wire)     |
| `s_axis_tready`  | `state(1)` register Q bit     | ~0 (register-to-wire)     |

No combinational path exists from input signals (`s_axis_tdata`,
`s_axis_tvalid`) to output signals (`m_axis_tdata`, `m_axis_tvalid`),
ensuring timing isolation between upstream and downstream domains.

---

## File Structure

```
axis_skid_buffer/
├── README.md                    # This file
├── rtl/
│   ├── axis_skid_buffer.sv       # Main RTL (SystemVerilog)
│   ├── axis_skid_buffer.vhd      # Main RTL (VHDL)
│   └── axis_skid_buffer_top.vhd  # Synthesis top wrapper (VHDL)
├── scripts/
│   ├── sv.f                      # SV RTL + simple TB
│   ├── vhdl.f                    # VHDL RTL + simple TB
│   ├── uvvm.f                    # UVVM with VHDL DUT
│   ├── sv-uvvm.f                 # UVVM with SV DUT
│   └── wave.do                   # Waveform setup
└── tb/
  ├── axis_skid_buffer_tb.vhd       # Lean directed TB
  ├── axis_skid_buffer_uvvm_th.vhd  # UVVM harness
  └── axis_skid_buffer_uvvm_tb.vhd  # UVVM sequencer
```

---

## Verification

From the `sub/fpga-ip/` root (with EDA tools initialized):

```bash
run axis_skid_buffer sv modelsim      # ModelSim/Questa simulation (SV)
run axis_skid_buffer vhdl modelsim    # ModelSim/Questa simulation (VHDL)
run axis_skid_buffer uvvm modelsim    # UVVM with VHDL DUT
run axis_skid_buffer sv-uvvm modelsim # UVVM with SV DUT
run axis_skid_buffer sv vivado        # Vivado synthesis (SV)
run axis_skid_buffer vhdl vivado      # Vivado synthesis (VHDL)
```

To run manually with your simulator (after environment/tool setup):

```batch
cd sub\fpga-ip
vlib axis_skid_buffer\modelsim\work
vlog -sv -work axis_skid_buffer/modelsim/work axis_skid_buffer/rtl/axis_skid_buffer.sv
vcom -2008 -work axis_skid_buffer/modelsim/work axis_skid_buffer/tb/axis_skid_buffer_tb.vhd
vsim -voptargs=+acc work.axis_skid_buffer_tb
run -all
```
