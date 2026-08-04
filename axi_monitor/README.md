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
rtl/axi_ar_gen.vhd        # traffic source: AR generator (pace=0 -> every cycle)
tb/axi_monitor_tb.vhd     # testbench (uses axi_ar_gen + axi_mem_model)
tb/axi_monitor_reg_tb.vhd # register testbench (axilite_bfm_pkg + axi_mem_model)
scripts/vhdl.f            # file list (sim / synth)
scripts/run_tb.tcl        # compile + run axi_monitor_tb (CDs into sim/, gitignored)
scripts/run_reg_tb.tcl    # compile + run axi_monitor_reg_tb (CDs into sim/, gitignored)
```

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

From `sub/fpga-ip/` with ModelSim on PATH (VHDL-2008, `m20`):

```bash
cmd.exe /c "m20 & vsim -c -do axi_monitor/scripts/run_tb.tcl"
```

The script CDs into `axi_monitor/sim/` (gitignored), compiles all RTL +
TB sources, and runs the full test suite:

- **T1** -- passive monitoring of 16-beat linear bursts, data check ON
  (ar_seen == ar_issued, xactions == ar_seen, beats == xactions*16,
  burst_len 16/16, no data/id/rlast/resp/underflow errors)
- **T2** -- `stat_rst` clears counters
- **T3** -- `data_check_en='0'`: beats still counted, no data errors
- **T4** -- random addressing (power-of-two range), full match + no errors
- **T5** -- paced generation (`pace=1`, 8-beat bursts) exercises the
  `S_PACE_WAIT` path; ar_seen/xactions/beats all match, no errors
- **T6** -- `pace=2`, non-zero `pace_init`, and one-beat bursts
- **T7** -- R-channel backpressure (`r_ready=0`), stall statistic and
  error-free recovery
- **T8** -- per-instance monitor disable while traffic continues; monitor
  remains inert without false underflow errors
- **T9** -- injected data, ID, RRESP, and RLAST errors, followed by
  independent `err_rst` verification
- **T10** -- AR format, configured-window, and actual 4 KiB boundary checks
- **T11** -- `ar_length` maximum clamp and generator configuration-error
  reporting; includes a complete 256-beat burst
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

T10 found and fixed a real generator issue: the 4 KiB guard was bypassed
in `pace=0` back-to-back mode because the FSM stayed in `S_AR_ISSUE`.
The effective issue address is now checked on every AR issue.

T11 found and fixed a monitor issue: the R monitor's 8-bit beat index
wrapped at the end of a 256-beat burst, corrupting burst-length statistics.
The index is now 9 bits wide.

### Register testbench (`axi_monitor_reg_tb`)

The register wrapper is verified end-to-end via AXI4-Lite:

```bash
cmd.exe /c "m20 & vsim -c -do axi_monitor/scripts/run_reg_tb.tcl"
```

It instantiates `axi_monitor_reg` (which contains `axi_monitor` +
`axi_ar_gen` + `axilite_io`), connects `axi_mem_model` as the responding
slave, and drives the flat AXI4-Lite port with `axilite_bfm_pkg`
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
- **T5** -- partial write (`wstrb`) to the `ar_length` register:
  writing byte 0 only (strobe `x"1"`) updates just that byte, so the
  generator emits 16-beat bursts as expected.

## AR generator (`axi_ar_gen`)

A lightweight traffic source used by the TB (simulation only).  It
issues AR bursts at a configurable pace, decoupled from R completion:

- `pace=0` -> a new AR can be issued every clock cycle (back-to-back,
  the FSM stays in `S_AR_ISSUE`)
- `pace=1` -> every second cycle, `pace=2` -> every third, ...

It supports linear sweep and pseudo-random (XOR-shift) addressing with a
4KB boundary guard and config-error detection.  Unlike
`axi_read_tester_ar_gen` it has no scoreboard output -- the monitor
builds its own scoreboard from the tapped AR bus.

Manual compile (equivalent to what the script does):

```bash
m20 & cd axi_monitor && mkdir -p sim && cd sim
vlib work
vcom -2008 -work work ../../common/rtl/util_pkg.vhd
vcom -2008 -work work ../../axis_fifo/rtl/axis_fifo.vhd
vcom -2008 -work work ../rtl/axi_monitor_ar.vhd
vcom -2008 -work work ../rtl/axi_monitor_r.vhd
vcom -2008 -work work ../rtl/axi_monitor.vhd
vcom -2008 -work work ../../parallel_prng/rtl/xorshift32.vhd
vcom -2008 -work work ../../parallel_prng/rtl/xorshift128.vhd
vcom -2008 -work work ../../jitter_gen/rtl/jitter_gen.vhd
vcom -2008 -work work ../../axis_latency_gen/rtl/axis_latency_gen.vhd
vcom -2008 -work work ../../axi_mem_model/rtl/axi_mem_model_core.vhd
vcom -2008 -work work ../../axi_mem_model/rtl/axi_mem_model.vhd
vcom -2008 -work work ../rtl/axi_ar_gen.vhd
vcom -2008 -work work ../tb/axi_monitor_tb.vhd
vsim -c work.axi_monitor_tb
```

Or use the repository launcher:

```bash
run axi_monitor vhdl modelsim
```
