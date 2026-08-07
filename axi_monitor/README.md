# axi_monitor

Passive AXI4 read-transaction monitor.  Non-intrusively taps the AR and
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
rtl/axi_monitor_top.vhd   # synthesis wrapper
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

`data_check_en` selects whether R data is verified against the
address-derived pattern (suited for `axi_mem_model` / known-pattern
slaves).  When low, beats are still counted and all protocol checks
(ID/RLAST/RRESP) still run, but data is not compared -- for monitoring
real traffic where the slave's data pattern is unknown.

`aperture` defines the measurement window:  statistics accumulate only
while it is high, and `pipeline_busy` extends gating until in-flight
bursts drain.

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
- **T12** -- independent AR `aperture` gating while R-side completion
  continues
- **T13** -- scoreboard underflow:  spurious R beats with no AR
  descriptor are counted as beats and flagged as underflow errors,
  without spurious data errors
- **T14** -- scoreboard backpressure:  a second monitor instance with a
  tiny (depth-4) scoreboard FIFO reports `stat_sb_backpressure` when R
  is held back under load, while the deep instance drains error-free
  with correct beat accounting

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
