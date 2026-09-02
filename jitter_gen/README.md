# jitter_gen — CDF-Based Jitter Generator

Combines a selectable internal PRNG (xorshift32 or xorshift128) with a CDF
comparator to produce non-uniform jitter values. On each `step` pulse, the
internal PRNG advances and the lowest 8 bits of its output are compared against
configurable cumulative thresholds to select one of four jitter output values.

Typical use case: injecting non-uniform timing jitter into delay generators
(e.g., `axis_latency_gen`) to model real-world DRAM or interconnect behaviour
where small delays are common and large outliers are rare.

Licensed under Zero-Clause BSD (0BSD).

## Features

- **Selectable built-in PRNG** — xorshift32 or xorshift128, chosen via the
  `GC_USE_XORSHIFT128` generic (no source-code editing needed).
- **CDF-based distribution** — Configurable thresholds shape the probability
  density of each jitter value.
- **4 jitter buckets** — Three thresholds split the 0–255 range into four
  zones, each with a configurable output value.
- **Enable gating** — `enable = '0'` forces output to zero, independent of
  `step`.
- **Elaboration-time safety checks** — Assertions verify thresholds are
  strictly ascending and fit within 8 bits.

## Interface

### Generics

| Generic | Type | Default | Description |
|---------|------|---------|-------------|
| `GC_JITTER_WIDTH` | positive | 8 | Width of output `jitter` port (unsigned) |
| `GC_USE_XORSHIFT128` | boolean | false | PRNG selection: `false` = xorshift32, `true` = xorshift128 |
| `GC_SEED` | slv(31:0) | x"DEADBEEF" | xorshift32 seed (ignored when `GC_USE_XORSHIFT128=true`) |
| `GC_SEED0` | slv(63:0) | x"DEADBEEFCAFEBABE" | xorshift128 seed 0 (ignored when `GC_USE_XORSHIFT128=false`) |
| `GC_SEED1` | slv(63:0) | x"0123456789ABCDEF" | xorshift128 seed 1 (ignored when `GC_USE_XORSHIFT128=false`) |
| `GC_VAL_0` | integer | 0 | Jitter value when `slice < GC_TH_0` (~50% probability) |
| `GC_VAL_1` | integer | 1 | Jitter value when `slice < GC_TH_1` (~25% probability) |
| `GC_VAL_2` | integer | 3 | Jitter value when `slice < GC_TH_2` (~19% probability) |
| `GC_VAL_3` | integer | 7 | Jitter value when `slice >= GC_TH_2` (~6% probability) |
| `GC_TH_0` | integer | 128 | First CDF threshold (0–255, must be < GC_TH_1) |
| `GC_TH_1` | integer | 192 | Second CDF threshold (must be > GC_TH_0, < GC_TH_2) |
| `GC_TH_2` | integer | 240 | Third CDF threshold (must be > GC_TH_1, < 256) |

### Ports

| Port | Direction | Width | Description |
|------|-----------|-------|-------------|
| `clk` | in | 1 | System clock |
| `rstn` | in | 1 | Synchronous reset (active low) |
| `step` | in | 1 | Pulse high to advance PRNG and update jitter |
| `enable` | in | 1 | Gating; output held at 0 when low |
| `jitter` | out | GC_JITTER_WIDTH | Selected unsigned jitter value |

## Architecture

One of two PRNGs is instantiated internally, selected by the
`GC_USE_XORSHIFT128` generic:

- **xorshift32** (`false`) — 32-bit state, single seed `GC_SEED`, 32-bit output.
  Lower 8 bits used for CDF comparison.
- **xorshift128** (`true`) — 128-bit state, two 64-bit seeds `GC_SEED0`/`GC_SEED1`,
  64-bit output. Lower 8 bits used for CDF comparison.

On each `step` pulse, the selected PRNG advances and its lowest 8 bits are
compared against three cumulative thresholds. The `enable` port gates the
output — when low, `jitter` is forced to zero regardless of `step`.

A synthesis wrapper (`jitter_gen_top.vhd`) passes all generics through for
top-level instantiation.

**CDF (Cumulative Distribution Function)** — the 8-bit random value (0–255)
is used as a probability axis. Each threshold divides the range into segments
whose widths determine the probability of each output value:

```
0              128             192          240     255
├─────50%──────┼──────25%──────┼────19%─────┼──6%──┤
    GC_VAL_0       GC_VAL_1      GC_VAL_2    GC_VAL_3
```

Each threshold is the cumulative sum of probabilities before it:

| Condition | Probability | Output |
|-----------|-------------|--------|
| `slice < GC_TH_0` (e.g. < 128) | 128/256 = 50.00% | `GC_VAL_0` |
| `slice < GC_TH_1` (e.g. < 192) | 64/256  = 25.00% | `GC_VAL_1` |
| `slice < GC_TH_2` (e.g. < 240) | 48/256  = 18.75% | `GC_VAL_2` |
| `slice >= GC_TH_2` | 16/256  =  6.25% | `GC_VAL_3` |

Elaboration-time assertions catch invalid threshold configurations (not
strictly ascending or out of range).

## File Structure

```
jitter_gen/
├── README.md
├── rtl/
│   ├── jitter_gen.vhd        — Core CDF jitter generator
├── top/
│   ├── jitter_gen_top.vhd    — Synthesis wrapper (VHDL)
│   └── jitter_gen_top.sv     — Synthesis wrapper (SystemVerilog)
├── scripts/
│   └── vhdl.f
└── tb/
    └── jitter_gen_tb.vhd
```

## Verification

Before running, initialize your EDA tool environment. Then, from the fpga-ip
root:

```
run jitter_gen all
```

## Instantiation

Ready-to-copy templates for instantiating `jitter_gen` in a design. Signal
names match the ports; the PRNG, seeds, and CDF thresholds are set via
constants (names prefixed `C_`).

### Synthesis wrappers

Ready-made synthesis tops are provided in both languages:

- [top/jitter_gen_top.vhd](top/jitter_gen_top.vhd) - VHDL wrapper.
- [top/jitter_gen_top.sv](top/jitter_gen_top.sv) - SystemVerilog wrapper
  (binds the VHDL core via mixed language).

### VHDL

```vhdl
architecture rtl of <your_design> is

  constant C_JITTER_WIDTH    : positive := 8;
  constant C_USE_XORSHIFT128 : boolean := false;
  constant C_SEED            : std_logic_vector(31 downto 0) := x"DEADBEEF";
  constant C_SEED0           : std_logic_vector(63 downto 0) := x"DEADBEEFCAFEBABE";
  constant C_SEED1           : std_logic_vector(63 downto 0) := x"0123456789ABCDEF";
  constant C_VAL_0           : integer := 0;
  constant C_VAL_1           : integer := 1;
  constant C_VAL_2           : integer := 3;
  constant C_VAL_3           : integer := 7;
  constant C_TH_0            : integer := 128;
  constant C_TH_1            : integer := 192;
  constant C_TH_2            : integer := 240;

  -- Clock, reset, and controls
  signal clk    : std_logic;  -- clock
  signal rstn   : std_logic;  -- active-low synchronous reset
  signal step   : std_logic;  -- advance the generator one step
  signal enable : std_logic;  -- enable the generator

  -- Generated jitter value
  signal jitter : unsigned(C_JITTER_WIDTH-1 downto 0);  -- requires ieee.numeric_std

begin

  u_jitter_gen : entity work.jitter_gen
    generic map (
      GC_JITTER_WIDTH    => C_JITTER_WIDTH,
      GC_USE_XORSHIFT128 => C_USE_XORSHIFT128,
      GC_SEED            => C_SEED,
      GC_SEED0           => C_SEED0,
      GC_SEED1           => C_SEED1,
      GC_VAL_0           => C_VAL_0,
      GC_VAL_1           => C_VAL_1,
      GC_VAL_2           => C_VAL_2,
      GC_VAL_3           => C_VAL_3,
      GC_TH_0            => C_TH_0,
      GC_TH_1            => C_TH_1,
      GC_TH_2            => C_TH_2
    )
    port map (
      -- Clock, reset, and controls
      clk    => clk,
      rstn   => rstn,
      step   => step,
      enable => enable,

      -- Generated jitter value
      jitter => jitter
    );

end architecture;
```

### Verilog/SystemVerilog

```systemverilog
module <your_module>;

  localparam int unsigned C_JITTER_WIDTH    = 8;
  localparam bit          C_USE_XORSHIFT128 = 0;
  localparam logic [31:0] C_SEED            = 32'hDEADBEEF;
  localparam logic [63:0] C_SEED0           = 64'hDEADBEEFCAFEBABE;
  localparam logic [63:0] C_SEED1           = 64'h0123456789ABCDEF;
  localparam int          C_VAL_0           = 0;
  localparam int          C_VAL_1           = 1;
  localparam int          C_VAL_2           = 3;
  localparam int          C_VAL_3           = 7;
  localparam int          C_TH_0            = 128;
  localparam int          C_TH_1            = 192;
  localparam int          C_TH_2            = 240;

  // Clock, reset, and controls
  logic  clk;     // clock
  logic  rstn;    // active-low synchronous reset
  logic  step;    // advance the generator one step
  logic  enable;  // enable the generator

  // Generated jitter value
  logic [C_JITTER_WIDTH-1:0] jitter;  // generated jitter value

  jitter_gen #(
    .GC_JITTER_WIDTH    (C_JITTER_WIDTH),
    .GC_USE_XORSHIFT128 (C_USE_XORSHIFT128),
    .GC_SEED            (C_SEED),
    .GC_SEED0           (C_SEED0),
    .GC_SEED1           (C_SEED1),
    .GC_VAL_0           (C_VAL_0),
    .GC_VAL_1           (C_VAL_1),
    .GC_VAL_2           (C_VAL_2),
    .GC_VAL_3           (C_VAL_3),
    .GC_TH_0            (C_TH_0),
    .GC_TH_1            (C_TH_1),
    .GC_TH_2            (C_TH_2)
  ) u_jitter_gen (
    // Clock, reset, and controls
    .clk    (clk),
    .rstn   (rstn),
    .step   (step),
    .enable (enable),

    // Generated jitter value
    .jitter (jitter)
  );

endmodule
```
