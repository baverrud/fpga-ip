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
│   └── pulse_extender_top.vhd
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

Ready-to-copy template. Signal names match the ports. Set `GC_PULSE_LEN`
to the desired pulse length in clock cycles (8 here); if your enclosing
entity declares its own `GC_PULSE_LEN` generic, map it directly instead.

```vhdl
architecture rtl of <your_design> is

  -- Signal list (names match the ports)
  signal clk       : std_logic;
  signal rstn      : std_logic;
  signal trigger   : std_logic;
  signal pulse_out : std_logic;

begin

  u_pulse_extender : entity work.pulse_extender
    generic map (
      GC_PULSE_LEN => 8   -- output pulse length in clock cycles
    )
    port map (
      clk       => clk,
      rstn      => rstn,
      trigger   => trigger,
      pulse_out => pulse_out
    );

end architecture;
```

### SystemVerilog

Mixed-language instantiation of the VHDL entity from a SystemVerilog
module. Signal names match the ports; the VHDL generic `GC_PULSE_LEN`
is mapped like a module parameter.

```systemverilog
module <your_module> (/* ports */);

  // Signal list (names match the ports)
  logic clk;
  logic rstn;
  logic trigger;
  logic pulse_out;

  pulse_extender #(
    .GC_PULSE_LEN (8)   // output pulse length in clock cycles
  ) u_pulse_extender (
    .clk       (clk),
    .rstn      (rstn),
    .trigger   (trigger),
    .pulse_out (pulse_out)
  );

endmodule
```
