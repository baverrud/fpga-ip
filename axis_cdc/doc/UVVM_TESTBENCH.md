# UVVM VVC Testbench for axis_cdc

This document describes the UVVM VVC-based testbench for the `axis_cdc`
clock-domain converter. It complements the direct testbench
(`tb/axis_cdc_tb.vhd`, documented in `README.md`) with an independent,
protocol-level verification built on the UVVM AXI-Stream VVCs.

## Why a second, VVC-based testbench

The direct testbench drives the AXI-Stream signals with hand-written
procedures. The UVVM testbench instead drives and checks the stream through
the UVVM AXI-Stream Verification IP (VIP). The two testbenches are
independent implementations of the same interface, so an error in either
implementation cannot silently hide an error in the other.

The UVVM testbench also gives:

- Queued, asynchronous TX/RX command execution through VVCs, which models
  how real protocol agents behave in a larger verification environment.
- Built-in AXI-Stream protocol checks (TLAST handling, backpressure, byte
  lanes) from the VIP.
- Randomized valid/ready gap generation through the VIP's BFM configuration,
  in addition to the deterministic patterns of the direct testbench.
- UVVM alert handling and a single `report_alert_counters(FINAL)` summary.

## Files

| File | Role |
|------|------|
| `tb/axis_cdc_uvvm_th.vhd` | Structural harness: clocks, DUT, master/slave VVCs, debug taps, forced-stall mux. |
| `tb/axis_cdc_uvvm_tb.vhd` | Sequencer: configures the VVCs, runs the phases, checks coverage signals, reports alerts. |
| `scripts/uvvm.f` | Manifest with the eight committed UVVM configurations. |

Both testbench files require the precompiled UVVM libraries
(`uvvm_util`, `uvvm_vvc_framework`, `bitvis_vip_axistream`) and the UVVM
VVC framework engine. See `README.md` for the library locations.

## Test harness (`axis_cdc_uvvm_th.vhd`)

The harness is structural and instantiates:

- `clock_generator` for the source clock (`s_clk`, period
  `GC_S_CLK_PERIOD`) and the destination clock (`m_clk`, period
  `GC_M_CLK_PERIOD`). The two clocks are independent.
- The DUT (`entity work.axis_cdc`) with `GC_TDATA_WIDTH`, `GC_CDC_DEPTH`
  and `GC_SYNC_STAGES` passed through.
- A master (source) AXI-Stream VVC, `tx_vvc`, instance index 0, clocked by
  `s_clk`. It drives `s_axis_tdata` / `s_axis_tvalid` and samples
  `s_axis_tready`.
- A slave (destination) AXI-Stream VVC, `rx_vvc`, instance index 1, clocked
  by `m_clk`. It samples `m_axis_tdata` / `m_axis_tvalid` and drives
  `m_axis_tready`.

The AXI-Stream interface records (`tx_if` / `rx_if`) are constrained from
the payload width: `tdata` is `GC_TDATA_WIDTH` bits and `tkeep`/`tstrb` are
`C_NUM_BYTES = (GC_TDATA_WIDTH+7)/8` bits. The harness requires a
**byte-aligned** payload width (asserted with `severity failure`), because
the AXI-Stream VIP works in bytes.

The slave side is protected by a **forced-stall mux**:

```vhdl
m_axis_tready <= '0' when force_m_stall = '1' else rx_if.tready;
```

`force_m_stall` lets the sequencer stall the destination for a known number
of cycles without relying on the VIP's ready configuration. This is needed
because the AXI-Stream VIP's `ready_default_value` only controls TREADY
between commands; it does not guarantee that TREADY stays low throughout a
specific window.

Debug taps (`dbg_*`) expose the DUT-side signals to the sequencer so it can
make structural checks (e.g. that TREADY really deasserted, that TDATA
stayed stable during a stall) independently of the VIP.

## Sequencer (`axis_cdc_uvvm_tb.vhd`)

The sequencer is a single process that:

1. Configures the two VVCs' BFM behavior.
2. Runs the four test phases.
3. Checks the coverage signals.
4. Calls `report_alert_counters(FINAL)` and logs
   `AXIS_CDC UVVM VVC TEST PASSED`.

### VVC configuration

`configure_vvcs` sets, for the TX VVC, the `valid_low_*` random-gap
parameters and, for the RX VVC, the `ready_low_*` random-gap parameters.
The BFM configuration (`f_bfm_config`) sets:

- `clock_period` to the VVC's clock period.
- `max_wait_cycles = 10000`, `max_wait_cycles_severity = ERROR`.
- `valid_low_at_word_num = 0` and `ready_low_at_word_num = 0` so gaps are
  applied at any word (random placement).
- `protocol_error_severity = ERROR`.
- `unwanted_activity_severity = NO_ALERT` for both VVCs.

### Data pattern

`f_word(index)` builds a `GC_TDATA_WIDTH`-bit word that is a function of
`index` and touches every payload bit (the pattern is width-agnostic and
works from 1 bit up to the VIP limit). `queue_word` issues a matching
`axistream_transmit` on the TX VVC and `axistream_expect` on the RX VVC,
so every expected word is queued before the transfer starts - the VVCs
queue the commands and the framework executes them.

### Phases

| Phase | What it proves |
|-------|----------------|
| 1. Ordered multi-wrap | Queue `C_WRAP_WORDS = 4*GC_CDC_DEPTH + 17` TX/RX word pairs. The source and destination pointers wrap several times. Checks ordering and every payload bit. |
| 2. Full backpressure and stalled-output stability | Force the destination stall, queue `GC_CDC_DEPTH + 1` TX words (one more than the FIFO can hold), and verify `s_axis_tready` deasserts when the FIFO fills, `m_axis_tvalid` asserts, and TDATA/TVALID stay stable during the stall. Then release the stall and drain. |
| 3. Randomized valid/ready gaps | `valid_low_probability = 0.35`, `ready_low_probability = 0.40`, up to 5 low cycles, `C_RANDOM_WORDS = 4*GC_CDC_DEPTH + 64` word pairs. No word may be lost or reordered. |
| 4. Queued-data reset flush and recovery | Fill the FIFO with a distinct pre-reset marker word (`C_RESET_MARKER = 255`) while the destination is stalled, then assert reset with data visible at the output. Check TREADY/TVALID clear asynchronously, no pre-reset data transfers, and after release a distinct post-reset word (`C_POST_RESET_WORD = 0`) arrives - proving old data was flushed, not leaked. |

The queued-data reset check uses no fixed ps/ns settle delay. It records the
reset assertion time, waits for TREADY/TVALID to clear with a clock-derived
timeout, and verifies that simulation time did not advance. Delta-cycle
propagation is therefore allowed while the asynchronous-clear property is
still proved.

The four phases are run under the same generics; `C_TIMEOUT = 200 us`
guards every `await_completion` so a deadlock fails instead of hanging the
batch run.

### Coverage signals

The sequencer checks that the exercised behaviors were actually seen:

- `cov_source_backpressure`: the source saw `tvalid=1, tready=0` at least
  once (full boundary reached).
- `cov_output_stall`: the destination output was stalled with valid data.
- `cov_source_handshakes` / `cov_dest_handshakes`: at least one
  handshake on each side (the stream actually moved).

## Manifest and configurations

`scripts/uvvm.f` runs the testbench under the configurations below. All
require the UVVM libraries (`requires = uvvm`) and use `time_res = fs`
because the source and destination clocks are not always representable in
coarser time resolutions.

| Test | TDATA width | Depth | Sync stages | Source / destination period |
|---|---:|---:|---:|---|
| `default` | 32 | 8 | 2 | 10 ns / 13.2 ns |
| `rev` | 32 | 8 | 2 | 13.2 ns / 10 ns |
| `depth2` | 32 | 2 | 2 | 10 ns / 13.2 ns |
| `sync4` | 32 | 8 | 4 | 10 ns / 13.2 ns |
| `equal` | 32 | 8 | 2 | 10 ns / 10 ns |
| `fast_source` | 32 | 8 | 2 | 2 ns / 20 ns |
| `fast_destination` | 32 | 8 | 2 | 20 ns / 2 ns |
| `stress` | 256 | 8 | 4 | 2 ns / 20 ns |

## Running the UVVM testbench

```text
run axis_cdc uvvm modelsim             # ModelSim batch (default configuration)
run axis_cdc uvvm modelsim --tb rev    # one configuration
run axis_cdc uvvm modelsim --tb all    # every configuration, one run each
run axis_cdc uvvm questa --tb all      # same with Questa
```

On success each run ends with the UVVM final alert summary showing zero
`ERROR` / `TB_ERROR` / `FAILURE` and the log line:

```text
AXIS_CDC UVVM VVC TEST PASSED
```

## Known limits of the UVVM approach

The UVVM AXI-Stream VIP, as precompiled in this repository, has a fixed
sideband width limit. `uvvm_util/src/adaptations_pkg.vhd` defines:

```vhdl
constant C_AXISTREAM_BFM_MAX_TSTRB_BITS : positive := 32;
```

`TSTRB` has one bit per data byte, so the VIP can only drive payloads up
to **32 bytes = 256 bits**. A wider payload (e.g. the 512-bit `wide` and
`stress` configurations of the direct testbench) causes a fatal slice
overflow inside the BFM (`vsim-3471`). This is why the UVVM `stress`
configuration uses 256-bit data while the direct testbench still covers
512-bit. For widths above 256 bits, use the direct testbench
(`tb/axis_cdc_tb.vhd`).

The UVVM testbench, like the direct testbench, cannot prove analog
metastability tolerance, physical synchronizer placement, Gray-bus routing
skew, or implementation timing. Those are covered by the `ASYNC_REG`
attributes in the RTL and the XDC constraints documented in
`constr/AXIS_CDC_CONSTRAINTS.md`.
