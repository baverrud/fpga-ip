# axi_monitor

Passive client read-transaction monitor for the `req_*` / `rsp_*`
interfaces (no ID field).  Non-intrusively taps a client request/response
pair of `axi_read_bridge` (all req/rsp signals are inputs -- it never
drives them), captures every request into a scoreboard FIFO, and validates
every response beat against it while accumulating transaction, latency,
burst-length, and protocol-error statistics.

Because it is fully passive, it cannot stall or alter real traffic: there
is no backpressure and no state machine that could drop an event.  Every
accepted beat (`rsp_valid & rsp_ready`) and every request handshake
(`req_valid & req_ready`) is captured on the cycle it occurs.

This IP is a passive client read-transaction monitor for the `req_*` /
`rsp_*` interfaces.  The client interface has no ID, so there is no ID
check and no ID-related statistics; the scoreboard pairs each request
descriptor with its response.

## Files

```
rtl/axi_monitor_req.vhd    # passive req tap -> pushes scoreboard descriptor
rtl/axi_monitor_rsp.vhd    # passive rsp tap -> validates beats, accumulates stats
rtl/axi_monitor.vhd        # core: req -> axis_fifo -> rsp (+ max-outstanding)
rtl/axi_monitor_top.vhd    # synthesis wrapper (VHDL)
rtl/axi_monitor_top.sv     # synthesis wrapper (SystemVerilog, mixed-language)
tb/axi_monitor_tb.vhd      # integration testbench (axi_read_bridge + axi_mem_model)
tb/axi_monitor_simple_tb.vhd # hand-editable skeleton TB (hand-driven req/rsp)
scripts/vhdl.f             # file list (sim / synth)
```

> An AXI4-Lite register wrapper (`axi_monitor_reg`) is planned but not yet
> built.

## Data flow

```
req tap --(sb_tf)--> axis_fifo --(sb_ff)--> rsp tap
  |                                           |
  +---- req_valid/req_addr/req_len ---------> client req
  +---- rsp_valid/rsp_data/rsp_last <-------- client rsp
```

The scoreboard FIFO decouples request capture from response completion
(one descriptor per burst, FWFT).  The req tap pushes when it sees
`req_valid & req_ready`; the rsp tap pops when the first rsp beat arrives.

A client req/rsp pair is inherently in-order (there is no ID and no
reordering), so a single FIFO scoreboard per monitored client is
sufficient.  To monitor all clients of a multi-client bridge, instantiate
one `axi_monitor` per client interface.

## Statistics

- req side: `stat_req_seen`, `stat_req_stall`, `stat_sb_backpressure`
- Transactions/beats: `stat_xactions`, `stat_beats`
- Latency: `stat_latency_*`, `stat_first_latency_*`
- Beat spacing: `stat_interbeat_gap_*`
- Burst length: `stat_burst_len_sum/min/max`
- Bus health: `stat_rsp_stall`, `stat_elapsed_cycles`, `pipeline_busy`,
  `stat_max_outstanding`
- Errors: `stat_data_errors` (gated by `data_check_en`),
  `stat_rlast_errors`, `stat_resp_errors`, `stat_sb_underflow_errors`

All values are integer counts or clock-cycle counts, captured while
`enable` is high.  Sums are `GC_STAT_WIDTH` bits (default 48); counters
and min/max are 32 bits.  Latency/gap values are measured against the
free-running `global_time` counter (`GC_TIME_WIDTH` bits, default 48).

| Signal | Width | Reset | Definition |
|---|---|---|---|
| `stat_req_seen` | 32 | 0 | Number of req handshakes (`req_valid & req_ready`) captured. One per issued read request. |
| `stat_req_stall` | 32 | 0 | Cycles where a request was presented but not accepted (`req_valid=1`, `req_ready=0`). |
| `stat_sb_backpressure` | 32 | 0 | Req handshakes that occurred while the scoreboard FIFO was full (`sb_tready=0`). The descriptor was dropped; its rsp beats are counted but flagged as `stat_sb_underflow_errors` downstream. |
| `stat_xactions` | 32 | 0 | Completed read transactions (bursts), incremented on the last accepted beat of each burst. Only counts bursts with a matching scoreboard entry. |
| `stat_beats` | 32 | 0 | Total accepted rsp beats (`rsp_valid & rsp_ready`, `enable` high), counted unconditionally (including underflow beats). |
| `stat_latency_*` | 48/32 | 0 / all-ones | Per-transaction latency = `global_time - ts_req` taken on the last beat. `min` resets to all-ones ("unset"). |
| `stat_first_latency_*` | 48/32 | 0 / all-ones | Latency from the req handshake to the first rsp beat of the transaction. |
| `stat_interbeat_gap_*` | 48/32 | 0 / all-ones | Elapsed cycles between consecutive accepted beats within a burst (>= 1). |
| `stat_burst_len_*` | 48/32 | 0 / all-ones | Observed burst lengths in beats. |
| `stat_elapsed_cycles` | 32 | 0 | Free-running cycle counter while `enable` is high. |
| `stat_rsp_stall` | 32 | 0 | Cycles where the consumer backpressured the rsp channel (`rsp_valid=1`, `rsp_ready=0`). |
| `stat_max_outstanding` | 32 | 0 | Peak scoreboard FIFO occupancy (in-flight bursts). |
| `stat_data_errors` | 32 | 0 | Accepted beats whose `rsp_data` did not match the expected address-derived pattern (only when `data_check_en=1`). |
| `stat_rlast_errors` | 32 | 0 | RSPLAST protocol violations: asserted early, missing at burst end, or spurious with no active burst/scoreboard entry. |
| `stat_resp_errors` | 32 | 0 | Accepted beats whose `rsp_resp` was not OKAY (0b00). |
| `stat_sb_underflow_errors` | 32 | 0 | Accepted rsp beats with no scoreboard entry available when the burst began. |

> Related status output: `pipeline_busy` (1 bit) is high while the
> scoreboard has entries or a burst is in flight.

Notes:

- `stat_rst` clears all counters (req-side, rsp-side, and
  `stat_max_outstanding`) without disrupting in-flight burst tracking.
- `err_rst` clears only the error counters.
- The `min` stats reset to all-ones ("unset"); the `max`/sum/counter stats
  reset to 0.
- `stat_xactions` requires a scoreboard entry; `stat_beats` counts
  everything -- so in a clean run `beats == xactions * mean_burst_len`,
  but after underflows the two diverge.

## Data check

With `data_check_en=1`, each rsp beat is compared against the
address-derived pattern: beat `n` of a burst at base address `A` must
contain `A + n*GC_DATA_BYTES` filled with consecutive 32-bit words
(`A + n*64`, `A + n*64 + 4`, ...).  This matches the data returned by
`axi_mem_model` through `axi_read_bridge`, so the integration testbench
expects `stat_data_errors = 0` on clean traffic.

## Testbenches

- `axi_monitor_tb` (default): integration TB.  Instantiates
  `axi_read_bridge` + `axi_mem_model`, taps client 0 with one monitor
  instance and drives a second monitor instance with a hand-written
  req/rsp sequencer.  Coverage (phases A-M):
  - A/B: clean single-beat and multi-beat traffic through the bridge
    (accounting, burst length, no false errors).
  - C: `stat_rst` / `err_rst` basic clearing.
  - D: error injection on the hand-driven monitor (data, resp/rsp_last,
    scoreboard underflow).
  - E: rsp backpressure - `stat_rsp_stall` counts and the inter-beat gap
    stretches.
  - F: req backpressure - `stat_req_stall` counts on the hand-driven
    monitor (the bridge's axi_ar_mux live-refills a held req_valid at
    every grant edge, so bus-side req stalls are a re-presentation).
  - G: scoreboard backpressure - a second small-FIFO monitor instance
    (depth 4) is flooded and `stat_sb_backpressure` counts.
  - H: per-instance disable / re-enable - disabled monitor is inert,
    re-enable resumes with exact accounting.
  - I: `stat_rst` mid-traffic - in-flight burst tracking survives.
  - J: `err_rst` coincident with error detection - the reset wins.
  - K: maximum (32-beat) burst and mixed burst lengths in one window.
  - L: stat-accumulator consistency - elapsed-vs-reference,
    min/max/sum, `pipeline_busy` seen high then idle, `max_outstanding`.
  - M: sustained varied traffic (distinct addresses, mixed lengths,
    idle gaps).
- `axi_monitor_simple_tb`: hand-editable skeleton with a hand-driven
  req/rsp sequencer (no bridge).

Run with:

```text
run axi_monitor vhdl modelsim            # default tb: axi_monitor_tb
run axi_monitor vhdl modelsim --tb simple
run axi_monitor vhdl vivado              # synthesis (rtl + top)
```
