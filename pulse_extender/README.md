# Pulse Extender

Level-gated pulse extender. When the output is idle, a high level on
`trigger` sampled at a rising clock edge drives `pulse_out` high for exactly
`GC_PULSE_LEN` clock cycles. The trigger is sampled only while the output is
idle (no edge detection).

License: Zero-Clause BSD (0BSD)

## Features

- Level-triggered while idle: a high on `trigger` at a rising clock edge starts
  a pulse.
- Output pulse length configurable in clock cycles via `GC_PULSE_LEN`.
- Trigger during an active pulse is ignored (no extension).
- A held-high trigger restarts the pulse each time it expires (a repeating
  pulse with a one-cycle gap).
- With `trigger` held at `'1'`, `pulse_out` produces a train of extended
  pulses: `GC_PULSE_LEN` high clock cycles followed by one low clock cycle.
- Two-process RTL (combinational + registered state).
- Registered `pulse_out` output (no combinational path to the port).
- Self-checking testbench, including the `GC_PULSE_LEN = 1` edge case.

## Interface

| Generic | Type | Default | Description |
|---------|------|---------|-------------|
| `GC_PULSE_LEN` | positive | 4 | Output pulse length in clock cycles (>= 1). |

| Port | Direction | Width | Description |
|------|-----------|-------|-------------|
| `clk` | in | 1 | Clock |
| `rstn` | in | 1 | Active-low synchronous reset |
| `trigger` | in | 1 | Synchronous trigger input; sampled on rising clock edges while the output is idle |
| `pulse_out` | out | 1 | Extended output pulse |

## Architecture

Two-process RTL:

- `p_comb` (combinational): when the counter is idle (`cnt = 0`) and
  `trigger` is high, loads the counter to `GC_PULSE_LEN`; otherwise it
  decrements the counter while it is active. The trigger is ignored while
  the pulse is active.
- `p_reg` (registered): updates the state on `clk`; `rstn = '0'` restores
  the default state.

`pulse_out` is a registered output, driven from the `pulse` field of the
state record. It asserts and deasserts on rising clock edges. Deriving it
from the next-state counter keeps the exact pulse timing (no added latency).

Timing (GC_PULSE_LEN = 4):

- A trigger sampled high at a rising edge makes the output high for 4 cycles,
  then low.
- Holding `trigger` high does not extend the active pulse; once the pulse
  expires the trigger is sampled again and a new pulse starts, producing a
  repeating train of 4 high cycles and 1 low cycle.

## File Structure

```text
pulse_extender/
├── README.md
├── rtl/
│   ├── pulse_extender.vhd
├── top/
│   ├── pulse_extender_top.vhd
│   └── pulse_extender_top.sv
├── scripts/
│   └── vhdl.f
└── tb/
    └── pulse_extender_tb.vhd
```

## Verification

From the fpga-ip repository root:

```text
run pulse_extender vhdl modelsim      # simulation (batch)
run pulse_extender vhdl questa        # simulation with Questa
run pulse_extender vhdl vivado        # synthesis
```

The testbench covers no-reset power-on operation, reset, idle, synchronous
registered-output timing, single-trigger pulse length, held-high trigger
(no extension, re-trigger after expiry), two pulses with a gap, and the
`GC_PULSE_LEN = 1` edge case.

## Instantiation

Ready-to-copy templates for instantiating `pulse_extender` in a design.
Signal names match the ports; the pulse length is set via the
`C_PULSE_LEN` constant.

### Synthesis wrappers

Ready-made synthesis tops are provided in both languages, so
`pulse_extender` can be used as a standalone netlist top without writing an
instance by hand. Both pass the `GC_PULSE_LEN` generic through to the core.
The VHDL wrapper is used by the standard `vhdl.f` synthesis flow; the
SystemVerilog wrapper is supplemental mixed-language support and is verified
by compiling it together with the VHDL core.

- [top/pulse_extender_top.vhd](top/pulse_extender_top.vhd) - VHDL wrapper:
  `entity pulse_extender_top` instantiates the core with a direct
  `entity work.pulse_extender` binding.
- [top/pulse_extender_top.sv](top/pulse_extender_top.sv) - SystemVerilog
  wrapper: `module pulse_extender_top` instantiates the VHDL core directly
  via mixed-language binding (no extra glue), passing `GC_PULSE_LEN`
  through.

### VHDL

```vhdl
architecture rtl of <your_design> is

  constant C_PULSE_LEN : positive := 8;  -- output pulse length in clock cycles

  -- Clock, reset, and trigger
  signal clk     : std_logic;  -- clock
  signal rstn    : std_logic;  -- active-low synchronous reset
  signal trigger : std_logic;  -- sampled only while idle

  -- Extended output pulse
  signal pulse_out : std_logic;  -- registered output

begin

  u_pulse_extender : entity work.pulse_extender
    generic map (
      GC_PULSE_LEN => C_PULSE_LEN
    )
    port map (
      -- Clock, reset, and trigger
      clk     => clk,
      rstn    => rstn,
      trigger => trigger,

      -- Extended output pulse
      pulse_out => pulse_out
    );

end architecture;
```

### Verilog/SystemVerilog

```systemverilog
module <your_module>;

  localparam int unsigned C_PULSE_LEN = 8;  // output pulse length in clock cycles

  // Clock, reset, and trigger
  logic clk;       // clock
  logic rstn;      // active-low synchronous reset
  logic trigger;   // sampled only while idle

  // Extended output pulse
  logic pulse_out; // registered output

  pulse_extender #(
    .GC_PULSE_LEN (C_PULSE_LEN)
  ) u_pulse_extender (
    // Clock, reset, and trigger
    .clk     (clk),
    .rstn    (rstn),
    .trigger (trigger),

    // Extended output pulse
    .pulse_out (pulse_out)
  );

endmodule
```
