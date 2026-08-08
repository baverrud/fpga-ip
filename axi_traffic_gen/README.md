# axi_traffic_gen

Collection of lightweight AXI3/AXI4 traffic generators.  Each generator is a
self-contained entity; today the IP provides the read-address generator
(`axi_ar_gen`) with room for additional specialized generators (e.g. a
write-address generator) in the same IP.

Licensed under Zero-Clause BSD (0BSD).

## AR generator (`axi_ar_gen`)

A lightweight AXI3/AXI4 read-address generator.  It issues AR bursts at a
configurable cfg_pace, decoupled from R completion:

- `cfg_pace=0` -> a new AR can be issued every clock cycle (back-to-back)
- `cfg_pace=1` -> every second cycle, `cfg_pace=2` -> every third, ...

It supports linear sweep and pseudo-random (XOR-shift) addressing within
a configured window.  Every presented start address is aligned to
`C_DATA_BYTES` and clamped to `[base, base+range-bsize]` (the full burst
always fits inside the window).  The `cfg_arlen` port is sized by
`GC_MAX_BURST` (`log2ceil(GC_MAX_BURST)` bits) and carries the AXI
ARLEN value (beats-1), so the largest expressible burst is
`GC_MAX_BURST` beats.  It has no scoreboard output -- consumers that
need data verification build their own scoreboard from the tapped AR
bus.

The full AR payload (`ar_id`, `ar_len`, `ar_addr`) is latched when a
burst is presented and held stable until the handshake, so configuration
changes during backpressure cannot alter an in-flight transfer.

Dependencies: `util_pkg` and the `xorshift128` entity from
`parallel_prng`.  That entity implements the xoroshiro128+ algorithm
used by `axi_ar_gen` for random-address mode.

### Generics

| Generic | Default | Description |
|---------|---------|-------------|
| `GC_DATA_BYTES` | 16 | Bytes per beat (drives `ar_size` and alignment) |
| `GC_ADDR_WIDTH` | 49 | AXI address width |
| `GC_ID_WIDTH` | 6 | AXI ID width |
| `GC_MAX_BURST` | 256 | Max beats per burst: 256 (AXI4) / 16 (AXI3) |

### Ports

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `aclk` / `aresetn` | in | 1 | Clock / synchronous active-low reset |
| `enable` | in | 1 | Per-instance enable (gates generation) |
| `aperture` | in | 1 | Measurement window (gates generation) |
| `stat_rst` | in | 1 | Clears statistic counters (not the FSM); takes priority over a coincident handshake |
| `cfg_id` | in | `GC_ID_WIDTH` | AR ID to tag each burst |
| `cfg_arlen` | in | `log2ceil(GC_MAX_BURST)` | AXI ARLEN value (beats-1); 0 = 1 beat |
| `cfg_pace` | in | 32 | Idle cycles between ARs (0 = every cycle) |
| `cfg_pace_init` | in | 32 | Initial delay before first burst (first AR appears `cfg_pace_init+1` cycles after reset) |
| `cfg_base_addr` | in | `GC_ADDR_WIDTH` | Start of address window |
| `cfg_addr_range` | in | `GC_ADDR_WIDTH` | Size of address window |
| `cfg_addr_mode` | in | 1 | `'0'` = linear sweep, `'1'` = pseudo-random |
| `ar_valid` / `ar_ready` | out/in | 1 | AXI AR handshake |
| `ar_id` | out | `GC_ID_WIDTH` | AXI ARID |
| `ar_addr` | out | `GC_ADDR_WIDTH` | AXI ARADDR |
| `ar_len` | out | 8 | AXI ARLEN (beats-1) |
| `ar_size` | out | 3 | AXI ARSIZE (log2 of bytes/beat) |
| `ar_burst` | out | 2 | AXI ARBURST (always INCR) |
| `stat_ar_stall` | out | 32 | AR stall events (valid, not ready) |
| `stat_ar_issued` | out | 32 | ARs successfully issued |
| `stat_cfg_errors` | out | 32 | Configuration error count |

> Note: random mode (`cfg_addr_mode='1'`) requires `cfg_addr_range` to be a
> power of two (the offset is a bit-mask).  Linear mode accepts any
> range.

## Instantiation

Ready-to-copy templates for instantiating `axi_ar_gen` in a design.
Signal names match the ports; the data width, address width, ID width,
and maximum burst length are set via the `C_*` constants.

### Synthesis wrappers

Ready-made synthesis tops are provided in both languages, so `axi_ar_gen`
can be used as a standalone netlist top without writing an instance by
hand:

- [rtl/axi_ar_gen_top.vhd](rtl/axi_ar_gen_top.vhd) - VHDL wrapper.
- [rtl/axi_ar_gen_top.sv](rtl/axi_ar_gen_top.sv) - SystemVerilog wrapper
  (binds the VHDL core directly).

### VHDL

```vhdl
architecture rtl of <your_design> is

  constant C_DATA_BYTES : positive := 16;   -- bytes per beat
  constant C_ADDR_WIDTH : positive := 49;   -- AXI address width
  constant C_ID_WIDTH   : positive := 6;    -- AXI ID width
  constant C_MAX_BURST  : positive := 256;  -- max beats per burst

  -- Clock and reset
  signal aclk    : std_logic;  -- clock
  signal aresetn : std_logic;  -- active-low synchronous reset

  -- Control
  signal enable   : std_logic;  -- per-instance enable
  signal aperture : std_logic;  -- measurement window
  signal stat_rst : std_logic;  -- clears statistic counters

  -- Runtime configuration
  signal cfg_id         : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal cfg_arlen      : std_logic_vector(log2ceil(C_MAX_BURST)-1 downto 0);  -- from work.util_pkg
  signal cfg_pace       : std_logic_vector(31 downto 0);
  signal cfg_pace_init  : std_logic_vector(31 downto 0);
  signal cfg_base_addr  : std_logic_vector(C_ADDR_WIDTH-1 downto 0);
  signal cfg_addr_range : std_logic_vector(C_ADDR_WIDTH-1 downto 0);
  signal cfg_addr_mode  : std_logic;

  -- AXI Read-Address Channel
  signal ar_valid : std_logic;
  signal ar_ready : std_logic;
  signal ar_id    : std_logic_vector(C_ID_WIDTH-1 downto 0);
  signal ar_addr  : std_logic_vector(C_ADDR_WIDTH-1 downto 0);
  signal ar_len   : std_logic_vector(7 downto 0);
  signal ar_size  : std_logic_vector(2 downto 0);
  signal ar_burst : std_logic_vector(1 downto 0);

  -- Statistics
  signal stat_ar_stall   : std_logic_vector(31 downto 0);
  signal stat_ar_issued  : std_logic_vector(31 downto 0);
  signal stat_cfg_errors : std_logic_vector(31 downto 0);

begin

  u_axi_ar_gen : entity work.axi_ar_gen
    generic map (
      GC_DATA_BYTES => C_DATA_BYTES,
      GC_ADDR_WIDTH => C_ADDR_WIDTH,
      GC_ID_WIDTH   => C_ID_WIDTH,
      GC_MAX_BURST  => C_MAX_BURST
    )
    port map (
      -- Clock and reset
      aclk    => aclk,
      aresetn => aresetn,

      -- Control
      enable   => enable,
      aperture => aperture,
      stat_rst => stat_rst,

      -- Runtime configuration
      cfg_id         => cfg_id,
      cfg_arlen      => cfg_arlen,
      cfg_pace       => cfg_pace,
      cfg_pace_init  => cfg_pace_init,
      cfg_base_addr  => cfg_base_addr,
      cfg_addr_range => cfg_addr_range,
      cfg_addr_mode  => cfg_addr_mode,

      -- AXI Read-Address Channel
      ar_valid => ar_valid,
      ar_ready => ar_ready,
      ar_id    => ar_id,
      ar_addr  => ar_addr,
      ar_len   => ar_len,
      ar_size  => ar_size,
      ar_burst => ar_burst,

      -- Statistics
      stat_ar_stall   => stat_ar_stall,
      stat_ar_issued  => stat_ar_issued,
      stat_cfg_errors => stat_cfg_errors
    );

end architecture;
```

### SystemVerilog

```systemverilog
module <your_design> #(
    parameter int unsigned C_DATA_BYTES = 16,  // bytes per beat
    parameter int unsigned C_ADDR_WIDTH = 49,  // AXI address width
    parameter int unsigned C_ID_WIDTH   = 6,   // AXI ID width
    parameter int unsigned C_MAX_BURST  = 256  // max beats per burst
) (
    // Clock and reset
    input logic aclk,     // clock
    input logic aresetn,  // active-low synchronous reset

    // Control
    input logic enable,    // per-instance enable
    input logic aperture,  // measurement window
    input logic stat_rst,  // clears statistic counters

    // Runtime configuration
    input logic [C_ID_WIDTH-1:0]          cfg_id,          // AR ID to tag each burst
    input logic [$clog2(C_MAX_BURST)-1:0] cfg_arlen,       // AXI arlen (beats-1)
    input logic [31:0]                    cfg_pace,        // idle cycles between ARs
    input logic [31:0]                    cfg_pace_init,   // delay before first burst
    input logic [C_ADDR_WIDTH-1:0]        cfg_base_addr,   // window start
    input logic [C_ADDR_WIDTH-1:0]        cfg_addr_range,  // window size
    input logic                           cfg_addr_mode,   // 0 = linear, 1 = random

    // AXI Read-Address Channel
    output logic                    ar_valid,  // address valid
    input  logic                    ar_ready,  // address ready
    output logic [C_ID_WIDTH-1:0]   ar_id,     // AR ID
    output logic [C_ADDR_WIDTH-1:0] ar_addr,   // AR address
    output logic [7:0]              ar_len,    // burst length (beats-1)
    output logic [2:0]              ar_size,   // bytes per beat
    output logic [1:0]              ar_burst,  // burst type (always INCR)

    // Statistics
    output logic [31:0] stat_ar_stall,   // AR stall events
    output logic [31:0] stat_ar_issued,  // ARs issued
    output logic [31:0] stat_cfg_errors  // config error count
);

  axi_ar_gen #(
      .GC_DATA_BYTES (C_DATA_BYTES),
      .GC_ADDR_WIDTH (C_ADDR_WIDTH),
      .GC_ID_WIDTH   (C_ID_WIDTH),
      .GC_MAX_BURST  (C_MAX_BURST)
  ) u_axi_ar_gen (
      // Clock and reset
      .aclk    (aclk),
      .aresetn (aresetn),

      // Control
      .enable   (enable),
      .aperture (aperture),
      .stat_rst (stat_rst),

      // Runtime configuration
      .cfg_id         (cfg_id),
      .cfg_arlen      (cfg_arlen),
      .cfg_pace       (cfg_pace),
      .cfg_pace_init  (cfg_pace_init),
      .cfg_base_addr  (cfg_base_addr),
      .cfg_addr_range (cfg_addr_range),
      .cfg_addr_mode  (cfg_addr_mode),

      // AXI Read-Address Channel
      .ar_valid (ar_valid),
      .ar_ready (ar_ready),
      .ar_id    (ar_id),
      .ar_addr  (ar_addr),
      .ar_len   (ar_len),
      .ar_size  (ar_size),
      .ar_burst (ar_burst),

      // Statistics
      .stat_ar_stall   (stat_ar_stall),
      .stat_ar_issued  (stat_ar_issued),
      .stat_cfg_errors (stat_cfg_errors)
  );

endmodule
```

## Testbenches

### `axi_ar_gen_tb` (comprehensive)

A comprehensive, self-checking testbench for `axi_ar_gen` alone (no
monitor, no memory model -- the AR channel is tapped directly).  It
instantiates **six DUT copies** with `GC_DATA_BYTES` in
{1,2,4,8,16,32}, all sharing one config and one `ar_ready`, so valid/
pacing timing is checked in lockstep while address generation is
verified per data width.

A spec-based **reference model** recomputes the address the DUT must
present every cycle (linear wrap-around, random offset mask + window
clamp, and the `fit_addr` align/clamp), driven by a mirror
`xorshift128` stepped in lockstep with the DUT PRNG.  A clocked checker
compares the DUT outputs against the model and runs independent
protocol checks:

- `ar_addr` aligned to `C_DATA_BYTES`
- full burst fits inside `[base, base+range]`
- `ar_len`/`ar_id` match the latched burst payload (not live config),
  `ar_size == log2(GC_DATA_BYTES)`, `ar_burst == INCR`
- VALID held and address stable until the handshake (AXI valid/ready
  protocol)

Corner cases covered:

- **T1** -- linear wrap-around, `cfg_pace=0` back-to-back
- **T2** -- unaligned base (align-down clamp)
- **T3** -- wrap boundary at a non-aligned window end
- **T4** -- random mode + offset window clamp (200 issues)
- **T5** -- `cfg_pace`/`cfg_pace_init` first-burst delay
- **T5B** -- `cfg_pace=1` issues every 2nd cycle (gap regression)
- **T5C** -- `cfg_pace_init` first-burst delay increases with value
- **T6** -- backpressure: VALID-hold, no address skip, stall counting
- **T6A** -- ARID/ARLEN held while configuration changes during a stall
- **T7** -- enable/aperture gating, incl. VALID-hold while the gate
  drops mid-presentation
- **T8** -- `cfg_arlen` extremes (1-beat and 256-beat bursts) and the
  degenerate burst>window clamp
- **T9** -- `stat_rst` clears counters mid-run

```bash
run axi_traffic_gen vhdl modelsim            # default tb: axi_ar_gen_tb
```

### `axi_ar_gen_simple_tb` (hand-editable skeleton)

A minimal, hand-editable testbench.  Uses plain signal initialization
(defaults in the declarations) so tests can be added by editing the
sequencer process.  Only `axi_ar_gen` is instantiated; the AR channel is
tapped directly (`ar_ready` driven by the TB).  No monitor, no
mem_model -- the focus is purely on the generator's AR output.

```bash
run axi_traffic_gen vhdl modelsim --tb simple
```

## Synthesis

Standalone synthesis uses the synthesis wrapper
[rtl/axi_ar_gen_top.vhd](rtl/axi_ar_gen_top.vhd) as the top (an
[rtl/axi_ar_gen_top.sv](rtl/axi_ar_gen_top.sv) SystemVerilog wrapper is
also provided):

```bash
run axi_traffic_gen vhdl vivado
```
