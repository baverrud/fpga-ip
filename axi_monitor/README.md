# axi_monitor

Passive AXI3/AXI4 read-transaction monitor.  Non-intrusively taps the AR and
R channels of a bus (all AR/R signals are inputs -- it never drives
them), captures every AR transaction into a scoreboard FIFO, and
validates every R beat against it while accumulating transaction,
latency, burst-length, and protocol-error statistics.

Because it is fully passive, it cannot stall or alter real traffic:
there is no backpressure and no state machine that could drop an event.
Every accepted beat (`r_valid & r_ready`) and every AR handshake
(`ar_valid & ar_ready`) is captured on the cycle it occurs.

## Files

```
rtl/axi_monitor_ar.vhd    # passive AR tap -> pushes scoreboard descriptor
rtl/axi_monitor_r.vhd     # passive R tap -> validates beats, accumulates stats
rtl/axi_monitor.vhd       # core: ar -> axis_fifo -> r (+ max-outstanding)
rtl/axi_monitor_top.vhd   # synthesis wrapper (VHDL)
rtl/axi_monitor_top.sv    # synthesis wrapper (SystemVerilog, mixed-language)
tb/axi_monitor_tb.vhd     # testbench (uses axi_ar_gen + axi_mem_model)
tb/axi_monitor_reg_tb.vhd # register testbench (axilite_bfm_pkg + axi_mem_model)
tb/axi_monitor_simple_tb.vhd # hand-editable skeleton TB
scripts/vhdl.f            # file list (sim / synth)
```

> The AR traffic source (`axi_ar_gen`) and its standalone testbenches live
> in the separate [`axi_traffic_gen`](../axi_traffic_gen/README.md) IP.
> axi_monitor depends on it (via `scripts/vhdl.f`) but does not own it.

## Data flow

```
AR tap --(sb_tf)--> axis_fifo --(sb_ff)--> R tap
  |                                          |
  +---- ar_valid/ar_addr/ar_len ----------> external bus
  +---- r_valid/r_data/r_last <------------ external bus
```

The scoreboard FIFO decouples AR capture from R completion (one
descriptor per burst, FWFT).  The AR tap pushes when it sees
`ar_valid & ar_ready`; the R tap pops when the first R beat arrives.

> **Known limitation:** the R tap tracks a single burst at a time and
> assumes bursts complete in AR-issue order (one scoreboard entry popped
> per burst).  It does **not** support interleaved / out-of-order R
> responses from multiple outstanding transactions (different IDs): an
> interleaved beat would be attributed to the wrong burst and flagged as
> an ID/data error.  For such traffic a per-ID scoreboard is required.
> The `axi_mem_model` used in the testbenches responds in-order, so this
> case is deliberately out of scope here.

## Statistics

- AR side: `stat_ar_seen`, `stat_ar_stall`, `stat_sb_backpressure`
- Transactions/beats: `stat_xactions`, `stat_beats`
- Latency: `stat_latency_*`, `stat_first_latency_*`
- Beat spacing: `stat_interbeat_gap_*`
- Burst length: `stat_burst_len_sum/min/max`
- Bus health: `stat_r_stall`, `stat_elapsed_cycles`, `pipeline_busy`,
  `stat_max_outstanding`
- Errors: `stat_data_errors` (gated by `data_check_en`),
  `stat_id_errors`, `stat_rlast_errors`, `stat_resp_errors`,
  `stat_sb_underflow_errors`

All values are integer counts or clock-cycle counts, captured while
`enable` is high (the monitor has no aperture input -- that is a
generator concept).  Sums are `GC_STAT_WIDTH` bits (default 48);
counters and min/max are 32 bits.  Latency/gap values are measured
against the free-running `global_time` counter (`GC_TIME_WIDTH` bits,
default 48).

| Signal | Width | Reset | Definition |
|---|---|---|---|
| `stat_ar_seen` | 32 | 0 | Number of AR handshakes (`ar_valid & ar_ready`) captured. Counted while `enable` is high. One per issued read transaction. |
| `stat_ar_stall` | 32 | 0 | Number of cycles where the master presented an AR request but the slave did not accept (`ar_valid=1`, `ar_ready=0`) -- AR-channel backpressure applied by the slave. Gated by `enable`. |
| `stat_sb_backpressure` | 32 | 0 | Number of AR handshakes that occurred while the scoreboard FIFO was full (`sb_tready=0`). The descriptor for that transaction was **dropped**; its R beats will be counted but flagged as `stat_sb_underflow_errors` downstream. Indicates the scoreboard depth (`GC_SB_FIFO_DEPTH`) was exceeded. |
| `stat_xactions` | 32 | 0 | Completed read transactions (bursts) -- incremented on the last accepted beat of each burst (when the burst's remaining-beat count reaches 0). Only counts bursts that had a matching scoreboard entry. |
| `stat_beats` | 32 | 0 | Total accepted R beats (`r_valid & r_ready`, with `enable` high). Counted **unconditionally** on every accepted beat -- including beats with no scoreboard entry (those also increment `stat_sb_underflow_errors`) and beats where data validation is disabled. |
| `stat_latency_sum` | 48 | 0 | Sum of per-transaction latencies, in clock cycles. A transaction's latency = `global_time - ts_ar` taken on its **last** beat, where `ts_ar` is the timestamp captured at the AR handshake. Divide by `stat_xactions` for mean latency. |
| `stat_latency_min` | 32 | all-ones ("unset") | Minimum transaction latency in cycles. The all-ones reset means "no sample yet"; after the first transaction it always holds a real value. |
| `stat_latency_max` | 32 | 0 | Maximum transaction latency in cycles. |
| `stat_first_latency_sum` | 48 | 0 | Sum of **first-beat** latencies (latency from AR handshake to the first R beat of that transaction, `global_time - ts_ar` at `beat_idx=1`). Distinct from `stat_latency_*`, which measures to the *last* beat. Divide by `stat_xactions` for mean first-beat latency. |
| `stat_first_latency_min` | 32 | all-ones ("unset") | Minimum first-beat latency in cycles. |
| `stat_first_latency_max` | 32 | 0 | Maximum first-beat latency in cycles. |
| `stat_interbeat_gap_sum` | 48 | 0 | Sum of inter-beat intervals, in clock cycles. For every beat after the first in a burst (`beat_idx > 1`), gap = `global_time - ts_prev_beat`. This is the **elapsed time between consecutive accepted beats** (a modular time difference, always >= 1). Back-to-back beats give a gap of 1 (zero idle cycles). Divide by `stat_beats - stat_xactions` for the mean. |
| `stat_interbeat_gap_min` | 32 | all-ones ("unset") | Minimum inter-beat interval in cycles. A value of 1 means at least one pair of beats transferred back-to-back with no idle cycles. |
| `stat_interbeat_gap_max` | 32 | 0 | Maximum inter-beat interval in cycles. Any value > 1 means the R channel stalled between beats (slave or consumer backpressure). |
| `stat_burst_len_sum` | 48 | 0 | Sum of observed burst lengths, in beats (one sample per completed transaction). Divide by `stat_xactions` for the mean burst length. |
| `stat_burst_len_min` | 32 | all-ones ("unset") | Minimum observed burst length in beats. |
| `stat_burst_len_max` | 32 | 0 | Maximum observed burst length in beats. |
| `stat_elapsed_cycles` | 32 | 0 | Free-running clock-cycle counter, incremented every cycle while `enable` is high. Gives the length of the measurement window (in cycles) so rates can be computed (e.g. beats/cycle). Cleared by `stat_rst`. |
| `stat_r_stall` | 32 | 0 | Number of cycles where the consumer backpressured the R channel (`r_valid=1`, `r_ready=0`), while `enable` is high. R-channel stall/backpressure counter. |
| `stat_max_outstanding` | 32 | 0 | Peak occupancy of the scoreboard FIFO -- the maximum number of read transactions issued but not yet completed (in-flight bursts) at any instant. Derived from the FIFO fill count; reset by `stat_rst`. A value well below `GC_SB_FIFO_DEPTH` indicates the scoreboard never bottlenecked. |
| `stat_data_errors` | 32 | 0 | Number of accepted beats whose `r_data` did not match the expected address-derived pattern. Only counted when `data_check_en=1` (the check is skipped when `data_check_en=0`, so this stays 0). |
| `stat_id_errors` | 32 | 0 | Number of accepted beats whose `r_id` did not match the `ar_id` from the matching scoreboard entry. Checked regardless of `data_check_en`. |
| `stat_rlast_errors` | 32 | 0 | Number of RLAST protocol violations: `r_last` asserted early (burst still has beats remaining), a missing `r_last` (burst ends without RLAST), or a spurious `r_last` with no active burst and no scoreboard entry. |
| `stat_resp_errors` | 32 | 0 | Number of accepted beats whose `r_resp` was not `OKAY` (0b00) -- any slave error/retry response. |
| `stat_sb_underflow_errors` | 32 | 0 | Number of accepted R beats for which **no scoreboard entry was available** when the burst began. The beat is still counted in `stat_beats` and validated where possible, but its data/ID/latency checks are skipped. Usually caused by `stat_sb_backpressure` (dropped descriptors) or by real traffic with no preceding AR capture. |

> Related status output: `pipeline_busy` (1 bit, not a counter) is high
> while the scoreboard has entries or a burst is in flight.

Notes:

- `stat_rst` clears all counters (AR-side, R-side, and
  `stat_max_outstanding`) without disrupting in-flight burst tracking.
- `err_rst` clears only the five error counters
  (`stat_data_errors` ... `stat_sb_underflow_errors`).
- The `min` stats reset to all-ones ("unset") so a genuine zero never
  reads as "no data"; the `max`/sum/counter stats reset to 0.
- `stat_rst` / `err_rst` take priority over the next-state logic:  an
  event (AR handshake, accepted R beat, burst completion, or error) that
  coincides with the reset cycle is suppressed -- it cannot resurrect a
  counter the reset just cleared.  Burst tracking is never affected.
- `stat_xactions` requires a scoreboard entry (a burst with an underflow
  cannot complete a transaction), whereas `stat_beats` counts everything
  -- so in a clean run `beats == xactions * mean_burst_len`, but after
  underflows the two diverge.

`data_check_en` selects whether R data is verified against the
address-derived pattern (suited for `axi_mem_model` / known-pattern
slaves).  When low, beats are still counted and all protocol checks
(ID/RLAST/RRESP) still run, but data is not compared -- for monitoring
real traffic where the slave's data pattern is unknown.

`aperture` is a traffic-generator concept (see
[`axi_traffic_gen`](../axi_traffic_gen/README.md)):  the AR generator
only issues requests while `aperture` is high.  The monitor itself is
purely `enable`-gated -- it counts every AR handshake and R beat while
`enable` is high, regardless of the generator window.  Use `stat_rst`
to reset statistics at a measurement-window boundary.

`enable` is the per-instance master switch:  when low the whole monitor
is inert (no scoreboard descriptors pushed, no stats counted, no data
validation).  It gates the AR tap and the R monitor in lock-step, so a
disabled instance neither produces descriptors nor reports false
underflow.  Deassert it to disable one monitor instance while other
instances keep monitoring.

## Simulation

From `sub/fpga-ip/`:

```bash
run axi_monitor vhdl modelsim              # default tb: axi_monitor_tb
run axi_monitor vhdl modelsim --tb simple  # hand-editable skeleton TB
run axi_monitor vhdl modelsim --tb reg     # register testbench
```

The manifest (`scripts/vhdl.f`) compiles all RTL + the selected TB
sources and runs the full test suite:

- **T1** -- passive monitoring of 16-beat linear bursts, data check ON
  (ar_seen == ar_issued, xactions == ar_seen, beats == xactions*16,
  burst_len 16/16, no data/id/rlast/resp/underflow errors)
- **T2** -- `stat_rst` clears counters
- **T3** -- `data_check_en='0'`: beats still counted, no data errors
- **T4** -- random addressing (power-of-two range), full match + no errors
- **T5** -- paced generation (`pace=1`, 8-beat bursts) exercises the
  `S_PACE_WAIT` path; ar_seen/xactions/beats all match, no errors
- **T6** -- `cfg_pace=2`, non-zero `cfg_pace_init`, and one-beat bursts
- **T7** -- R-channel backpressure (`r_ready=0`), stall statistic and
  error-free recovery
- **T8** -- per-instance monitor disable while traffic continues; monitor
  remains inert without false underflow errors
- **T9** -- injected data, ID, RRESP, and RLAST errors, followed by
  independent `err_rst` verification
- **T10** -- AR format, configured-window, and transfer-size alignment
  checks; burst start near the window end is clamped/wrapped so the
  full burst always fits
- **T11** -- maximum burst length:  `cfg_arlen = x"FF"` drives a full
  256-beat burst; the `cfg_arlen` port is sized by `GC_MAX_BURST`
  (`log2ceil(GC_MAX_BURST)` bits), so an over-large value cannot be
  expressed
- **T12** -- generator `aperture` gates AR generation; the enable-only
  monitor counts every AR issued while enabled (`ar_seen == ar_issued`)
- **T13** -- scoreboard underflow:  spurious R beats with no AR
  descriptor are counted as beats and flagged as underflow errors,
  without spurious data errors
- **T14** -- scoreboard backpressure:  a second monitor instance with a
  tiny (depth-4) scoreboard FIFO reports `stat_sb_backpressure` when R
  is held back under load, while the deep instance drains error-free
  with correct beat accounting
- **T15** -- `stat_rst` asserted mid-traffic:  counters clear without
  corrupting in-flight burst tracking; a clean second window shows
  exact accounting
- **T16** -- disable, drain, re-enable:  the monitor resumes cleanly
  with no underflow or protocol errors
- **T17** -- non-zero AR ID end-to-end:  ID matching holds for a
  non-zero `cfg_id`
- **T18** -- RLAST early-guard:  a spurious `r_last` with no active
  burst and no scoreboard entry increments `stat_rlast_errors`
- **T19** -- stat tightening:  AR-stall counter cross-checked against
  the generator, elapsed-cycle counter vs a reference, internal
  min/max/sum consistency for latency/first-latency/gap/burst-length,
  and `pipeline_busy` high-during-traffic / low-after-drain
- **T20** -- mixed burst lengths in one window (1-beat then 16-beat):
  `burst_len` min/max capture the spread
- **T21** -- narrow data-bytes path (`GC_DATA_BYTES=2`):  exercises the
  2-byte data-check branch of `axi_monitor_r` on an independent
  generator/mem/monitor path
- **T22** -- `err_rst` asserted while data errors are still being
  detected:  the reset wins over the coincident error detection

T1 additionally asserts timing-statistic bounds consistent with the
`axi_mem_model` configuration (`latency_min >= base_latency`,
`first_latency_min >= base_latency`, `interbeat_gap_min >= 1`).

T10 exercises the generator's window-end clamp:  with a burst start
near `cfg_base_addr+cfg_addr_range`, every issued address still satisfies
`ar_addr + burst_bytes <= cfg_base_addr + cfg_addr_range` and is aligned
to `C_DATA_BYTES`.

T11 drives a full-length burst (`cfg_arlen = x"FF"` at
`GC_MAX_BURST=256`).  It previously found and fixed a monitor issue:  the
R monitor's 8-bit beat index wrapped at the end of a 256-beat burst,
corrupting burst-length statistics.  The index is now 9 bits wide.

### Register testbench (`axi_monitor_reg_tb`)

The register wrapper is verified end-to-end via AXI4-Lite:

```bash
run axi_monitor vhdl modelsim --tb reg
```

It instantiates `axi_monitor_reg` (which contains `axi_monitor` + a
`axi_ar_gen` from `axi_traffic_gen` + `axilite_io`), connects
`axi_mem_model` as the responding slave, and drives the flat AXI4-Lite
port with `axilite_bfm_pkg`
(simplified `write_reg`/`read_reg` procedures wrapping
`axilite_write`/`axilite_read`).  Checks:

- **T1** -- configure the generator (16-beat linear bursts over a
  64 KiB window) and monitor via registers, run a traffic window, then
  verify ar_seen == ar_issued, xactions == ar_seen,
  beats == xactions*16, no errors, and `pipeline_busy` drains.
  Also reads back the wide statistics through the register bank
  (burst_len min/max, latency_min, elapsed, max_outstanding) and checks
  the generator's `ar_stall` counter matches the monitor's.
- **T2** -- `stat_rst` (via port) clears all counters, including the
  generator's.
- **T3** -- `led` reflects the `o_data[2]` register bit.
- **T4** -- monitor disabled via register (`o_data[0]=0`) while the
  generator keeps running:  the monitor stays inert (no AR/xaction/
  beat/error counts) and `pipeline_busy` stays low.
- **T5** -- partial write (`wstrb`) to the `cfg_arlen` register:
  writing byte 0 only (strobe `x"1"`) updates just that byte, so the
  generator emits 16-beat bursts as expected.

## AR generator (`axi_ar_gen`)

The AR traffic source used by the monitor TBs is now its own IP:
[`axi_traffic_gen`](../axi_traffic_gen/README.md).  It is a lightweight
AXI4 read-address generator -- issues AR bursts at a configurable pace
(`pace=0` -> every cycle), linear or pseudo-random addressing within a
window, aligned to `C_DATA_BYTES`.  It has no scoreboard output; the
monitor builds its own scoreboard from the tapped AR bus.

Standalone testbenches (`axi_ar_gen_tb`, `axi_ar_gen_simple_tb`) and
run scripts live in the `axi_traffic_gen` IP.

## Instantiation

Ready-to-copy templates for instantiating `axi_monitor` in a design. Signal
names match the ports; widths are set via constants (names prefixed `C_`).
All AR/R signals are inputs -- the monitor is a passive observer.

### Synthesis wrappers

Ready-made synthesis tops are provided in both languages:

- [rtl/axi_monitor_top.vhd](rtl/axi_monitor_top.vhd) - VHDL wrapper.
- [rtl/axi_monitor_top.sv](rtl/axi_monitor_top.sv) - SystemVerilog wrapper
  (binds the VHDL core via mixed language).

### VHDL

```vhdl
architecture rtl of <your_design> is

  constant C_DATA_BYTES    : positive := 64;
  constant C_ADDR_WIDTH    : positive := 49;
  constant C_ID_WIDTH      : positive := 6;
  constant C_TIME_WIDTH    : positive := 48;
  constant C_STAT_WIDTH    : positive := 48;
  constant C_SB_FIFO_DEPTH : positive := 256;

  -- Clock, reset, and timebase
  signal aclk        : std_logic;                          -- clock
  signal aresetn     : std_logic;                          -- active-low synchronous reset
  signal global_time : unsigned(C_TIME_WIDTH-1 downto 0);  -- free-running timebase

  -- Control
  signal enable        : std_logic;  -- monitor enable
  signal stat_rst      : std_logic;  -- clear all statistics
  signal err_rst       : std_logic;  -- clear error statistics
  signal data_check_en : std_logic;  -- enable data validation

  -- AR channel tap
  signal ar_valid : std_logic;                                  -- AR valid
  signal ar_ready : std_logic;                                  -- AR ready
  signal ar_id    : std_logic_vector(C_ID_WIDTH-1 downto 0);    -- AR ID
  signal ar_addr  : std_logic_vector(C_ADDR_WIDTH-1 downto 0);  -- AR address
  signal ar_len   : std_logic_vector(7 downto 0);               -- beats minus one

  -- R channel tap
  signal r_valid : std_logic;                                    -- R valid
  signal r_ready : std_logic;                                    -- R ready
  signal r_id    : std_logic_vector(C_ID_WIDTH-1 downto 0);      -- R ID
  signal r_data  : std_logic_vector(8*C_DATA_BYTES-1 downto 0);  -- R data
  signal r_resp  : std_logic_vector(1 downto 0);                 -- R response
  signal r_last  : std_logic;                                    -- last beat

  -- Statistics and status
  signal stat_ar_seen             : std_logic_vector(31 downto 0);
  signal stat_ar_stall            : std_logic_vector(31 downto 0);
  signal stat_sb_backpressure     : std_logic_vector(31 downto 0);
  signal stat_xactions            : std_logic_vector(31 downto 0);
  signal stat_beats               : std_logic_vector(31 downto 0);
  signal stat_latency_sum         : std_logic_vector(C_STAT_WIDTH-1 downto 0);
  signal stat_latency_min         : std_logic_vector(31 downto 0);
  signal stat_latency_max         : std_logic_vector(31 downto 0);
  signal stat_first_latency_sum   : std_logic_vector(C_STAT_WIDTH-1 downto 0);
  signal stat_first_latency_min   : std_logic_vector(31 downto 0);
  signal stat_first_latency_max   : std_logic_vector(31 downto 0);
  signal stat_interbeat_gap_sum   : std_logic_vector(C_STAT_WIDTH-1 downto 0);
  signal stat_interbeat_gap_min   : std_logic_vector(31 downto 0);
  signal stat_interbeat_gap_max   : std_logic_vector(31 downto 0);
  signal stat_burst_len_sum       : std_logic_vector(C_STAT_WIDTH-1 downto 0);
  signal stat_burst_len_min       : std_logic_vector(31 downto 0);
  signal stat_burst_len_max       : std_logic_vector(31 downto 0);
  signal stat_elapsed_cycles      : std_logic_vector(31 downto 0);
  signal stat_r_stall             : std_logic_vector(31 downto 0);
  signal pipeline_busy            : std_logic;
  signal stat_max_outstanding     : std_logic_vector(31 downto 0);
  signal stat_data_errors         : std_logic_vector(31 downto 0);
  signal stat_id_errors           : std_logic_vector(31 downto 0);
  signal stat_rlast_errors        : std_logic_vector(31 downto 0);
  signal stat_resp_errors         : std_logic_vector(31 downto 0);
  signal stat_sb_underflow_errors : std_logic_vector(31 downto 0);

begin

  u_axi_monitor : entity work.axi_monitor
    generic map (
      GC_DATA_BYTES    => C_DATA_BYTES,
      GC_ADDR_WIDTH    => C_ADDR_WIDTH,
      GC_ID_WIDTH      => C_ID_WIDTH,
      GC_TIME_WIDTH    => C_TIME_WIDTH,
      GC_STAT_WIDTH    => C_STAT_WIDTH,
      GC_SB_FIFO_DEPTH => C_SB_FIFO_DEPTH
    )
    port map (
      -- Clock, reset, and timebase
      aclk        => aclk,
      aresetn     => aresetn,
      global_time => global_time,

      -- Control
      enable        => enable,
      stat_rst      => stat_rst,
      err_rst       => err_rst,
      data_check_en => data_check_en,

      -- AR channel tap
      ar_valid => ar_valid,
      ar_ready => ar_ready,
      ar_id    => ar_id,
      ar_addr  => ar_addr,
      ar_len   => ar_len,

      -- R channel tap
      r_valid => r_valid,
      r_ready => r_ready,
      r_id    => r_id,
      r_data  => r_data,
      r_resp  => r_resp,
      r_last  => r_last,

      -- Statistics and status
      stat_ar_seen             => stat_ar_seen,
      stat_ar_stall            => stat_ar_stall,
      stat_sb_backpressure     => stat_sb_backpressure,
      stat_xactions            => stat_xactions,
      stat_beats               => stat_beats,
      stat_latency_sum         => stat_latency_sum,
      stat_latency_min         => stat_latency_min,
      stat_latency_max         => stat_latency_max,
      stat_first_latency_sum   => stat_first_latency_sum,
      stat_first_latency_min   => stat_first_latency_min,
      stat_first_latency_max   => stat_first_latency_max,
      stat_interbeat_gap_sum   => stat_interbeat_gap_sum,
      stat_interbeat_gap_min   => stat_interbeat_gap_min,
      stat_interbeat_gap_max   => stat_interbeat_gap_max,
      stat_burst_len_sum       => stat_burst_len_sum,
      stat_burst_len_min       => stat_burst_len_min,
      stat_burst_len_max       => stat_burst_len_max,
      stat_elapsed_cycles      => stat_elapsed_cycles,
      stat_r_stall             => stat_r_stall,
      pipeline_busy            => pipeline_busy,
      stat_max_outstanding     => stat_max_outstanding,
      stat_data_errors         => stat_data_errors,
      stat_id_errors           => stat_id_errors,
      stat_rlast_errors        => stat_rlast_errors,
      stat_resp_errors         => stat_resp_errors,
      stat_sb_underflow_errors => stat_sb_underflow_errors
    );

end architecture;
```

### Verilog/SystemVerilog

```systemverilog
module <your_module>;

  localparam int unsigned C_DATA_BYTES    = 64;
  localparam int unsigned C_ADDR_WIDTH    = 49;
  localparam int unsigned C_ID_WIDTH      = 6;
  localparam int unsigned C_TIME_WIDTH    = 48;
  localparam int unsigned C_STAT_WIDTH    = 48;
  localparam int unsigned C_SB_FIFO_DEPTH = 256;

  // Clock, reset, and timebase
  logic                    aclk;         // clock
  logic                    aresetn;      // active-low synchronous reset
  logic [C_TIME_WIDTH-1:0] global_time;  // free-running timebase

  // Control
  logic enable;        // monitor enable
  logic stat_rst;      // clear all statistics
  logic err_rst;       // clear error statistics
  logic data_check_en; // enable data validation

  // AR channel tap
  logic                    ar_valid;  // AR valid
  logic                    ar_ready;  // AR ready
  logic [C_ID_WIDTH-1:0]   ar_id;     // AR ID
  logic [C_ADDR_WIDTH-1:0] ar_addr;   // AR address
  logic [7:0]              ar_len;    // beats minus one

  // R channel tap
  logic                      r_valid;  // R valid
  logic                      r_ready;  // R ready
  logic [C_ID_WIDTH-1:0]     r_id;     // R ID
  logic [8*C_DATA_BYTES-1:0] r_data;   // R data
  logic [1:0]                r_resp;   // R response
  logic                      r_last;   // last beat

  // Statistics and status
  logic [31:0]             stat_ar_seen;              // AR transactions seen
  logic [31:0]             stat_ar_stall;             // AR ready-low cycles
  logic [31:0]             stat_sb_backpressure;      // scoreboard full cycles
  logic [31:0]             stat_xactions;             // completed transactions
  logic [31:0]             stat_beats;                // total beats
  logic [C_STAT_WIDTH-1:0] stat_latency_sum;          // latency accumulator
  logic [31:0]             stat_latency_min;          // minimum latency
  logic [31:0]             stat_latency_max;          // maximum latency
  logic [C_STAT_WIDTH-1:0] stat_first_latency_sum;    // first-beat latency accumulator
  logic [31:0]             stat_first_latency_min;    // minimum first-beat latency
  logic [31:0]             stat_first_latency_max;    // maximum first-beat latency
  logic [C_STAT_WIDTH-1:0] stat_interbeat_gap_sum;    // interbeat gap accumulator
  logic [31:0]             stat_interbeat_gap_min;    // minimum interbeat gap
  logic [31:0]             stat_interbeat_gap_max;    // maximum interbeat gap
  logic [C_STAT_WIDTH-1:0] stat_burst_len_sum;        // burst-length accumulator
  logic [31:0]             stat_burst_len_min;        // minimum burst length
  logic [31:0]             stat_burst_len_max;        // maximum burst length
  logic [31:0]             stat_elapsed_cycles;       // measured window length
  logic [31:0]             stat_r_stall;              // R ready-low cycles
  logic                    pipeline_busy;             // monitor actively tracking
  logic [31:0]             stat_max_outstanding;      // peak outstanding reads
  logic [31:0]             stat_data_errors;          // data mismatch count
  logic [31:0]             stat_id_errors;            // ID mismatch count
  logic [31:0]             stat_rlast_errors;         // rlast alignment errors
  logic [31:0]             stat_resp_errors;          // unexpected rresp count
  logic [31:0]             stat_sb_underflow_errors;  // scoreboard underflow count

  axi_monitor #(
    .GC_DATA_BYTES    (C_DATA_BYTES),
    .GC_ADDR_WIDTH    (C_ADDR_WIDTH),
    .GC_ID_WIDTH      (C_ID_WIDTH),
    .GC_TIME_WIDTH    (C_TIME_WIDTH),
    .GC_STAT_WIDTH    (C_STAT_WIDTH),
    .GC_SB_FIFO_DEPTH (C_SB_FIFO_DEPTH)
  ) u_axi_monitor (
    // Clock, reset, and timebase
    .aclk        (aclk),
    .aresetn     (aresetn),
    .global_time (global_time),

    // Control
    .enable        (enable),
    .stat_rst      (stat_rst),
    .err_rst       (err_rst),
    .data_check_en (data_check_en),

    // AR channel tap
    .ar_valid (ar_valid),
    .ar_ready (ar_ready),
    .ar_id    (ar_id),
    .ar_addr  (ar_addr),
    .ar_len   (ar_len),

    // R channel tap
    .r_valid (r_valid),
    .r_ready (r_ready),
    .r_id    (r_id),
    .r_data  (r_data),
    .r_resp  (r_resp),
    .r_last  (r_last),

    // Statistics and status
    .stat_ar_seen             (stat_ar_seen),
    .stat_ar_stall            (stat_ar_stall),
    .stat_sb_backpressure     (stat_sb_backpressure),
    .stat_xactions            (stat_xactions),
    .stat_beats               (stat_beats),
    .stat_latency_sum         (stat_latency_sum),
    .stat_latency_min         (stat_latency_min),
    .stat_latency_max         (stat_latency_max),
    .stat_first_latency_sum   (stat_first_latency_sum),
    .stat_first_latency_min   (stat_first_latency_min),
    .stat_first_latency_max   (stat_first_latency_max),
    .stat_interbeat_gap_sum   (stat_interbeat_gap_sum),
    .stat_interbeat_gap_min   (stat_interbeat_gap_min),
    .stat_interbeat_gap_max   (stat_interbeat_gap_max),
    .stat_burst_len_sum       (stat_burst_len_sum),
    .stat_burst_len_min       (stat_burst_len_min),
    .stat_burst_len_max       (stat_burst_len_max),
    .stat_elapsed_cycles      (stat_elapsed_cycles),
    .stat_r_stall             (stat_r_stall),
    .pipeline_busy            (pipeline_busy),
    .stat_max_outstanding     (stat_max_outstanding),
    .stat_data_errors         (stat_data_errors),
    .stat_id_errors           (stat_id_errors),
    .stat_rlast_errors        (stat_rlast_errors),
    .stat_resp_errors         (stat_resp_errors),
    .stat_sb_underflow_errors (stat_sb_underflow_errors)
  );

endmodule
```
