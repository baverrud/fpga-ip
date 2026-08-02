# axi_read_tester — AXI Read Bandwidth / Latency Tester

Issues AXI4 read bursts from a configurable address window (linear sweep
or pseudo-random) and verifies every returned data beat against an
internal scoreboard.  Collects latency, throughput, and error statistics
for bandwidth characterisation.

The primary use case is driving `axi_mem_model` (or real AXI HP buses
on Xilinx MPSoC / Zynq) under controlled conditions — no DMA driver
stack needed.

## Architecture

### Module Hierarchy (instantiation tree)

```
axi_read_tester_tb                      -- testbench
  |
  +-- axi_read_tester                   -- production IP
  |     |
  |     +-- axi_read_tester_ar_gen    -- AR burst generator
  |     +-- axis_fifo                 -- scoreboard FIFO
  |     +-- axi_read_tester_r_mon     -- R-channel monitor
  |
  +-- axi_mem_model                   -- simulated memory
```

### Data Flow

```
                                               Scoreboard path
  Control signals                         tf_ +-------------+ ff_
  enable, aperture,          +-----------+    |             |    +-----------+
  arid, burst_length, ------>|           |--->|  axis_fifo  |--->|           |
  pace, base_addr,           | AR Gen    |    | (scoreboard)|    | R Monitor |---> stats
  addr_range, mode           | (4-state) |    +-------------+    | (verify)  |---> errors
                             +-----+-----+                       +-----+-----+
  AR channel (to DUT)              |       AR bus                     ^
  ar_valid, ar_addr, ar_len ------ | ---------------------+          |
  ar_ready <---------------------- | -------------------+ |          |
                                   v                    | |  R bus   |
                             +-----------+              | | r_valid, |
                             | Memory    |              | | r_data,  |
                             | Model     |--------------|-| r_id,    |
                             | (or DUT)  |              | | r_last,  |
                             +-----------+              | | r_resp   |
                                                        | |          |
  mem_latency, mem_gap --------------------------------+ |          |
  (harness only)                                          |          |
  r_ready <-----------------------------------------------+----------+
```

### Block Descriptions

| Block | Role |
|-------|------|
| **AR Generator** | Issues AXI read-address bursts at a configurable pace.  Linear sweep with wrap, or XOR-shift pseudo-random within a window.  Pushes one scoreboard descriptor per burst: `{araddr, arid, timestamp, arlen}`. |
| **Scoreboard FIFO** | FWFT `axis_fifo` decoupling AR issue from R completion.  Descriptors flow through with 1-cycle registered-output latency.  `tf_` = to-FIFO (slave side), `ff_` = from-FIFO (master side). |
| **R Monitor** | Pops scoreboard entry on each new burst's first R beat.  Verifies data (address-derived pattern), RID, RLAST, and RRESP.  Accumulates latency / gap / error statistics gated by `aperture`.  Backpressures R channel when waiting for a scoreboard entry. |
| **Memory Model** | Responds to AR beats with address-derived data after configurable latency.  AR-side and R-side each have independent latency generators.  Instantiated in the testbench alongside the tester. |
| **Testbench** | `axi_read_tester_tb.vhd` instantiates `axi_read_tester` and `axi_mem_model` directly. It exercises latency, address-window, random, reset, backpressure, configuration-clamp, and statistics-reset cases. |

## File Structure

```
axi_read_tester/
├── rtl/
│   ├── axi_read_tester.vhd            # Top-level: AR gen + SB FIFO + R mon
│   ├── axi_read_tester_ar_gen.vhd     # AR burst generator (4-state FSM)
│   └── axi_read_tester_r_mon.vhd      # R-channel data monitor + statistics
├── tb/
│   ├── axi_read_tester_tb.vhd         # Core 13-phase corner-case testbench
│   ├── axi_read_tester_simple_tb.vhd  # Minimal smoke-test skeleton
│   ├── axi4_read_tester_shim_tb.vhd   # VHDL-2019 shim testbench
│   └── axi4_read_tester_multi_tb.vhd  # VHDL-2019 multi-instance testbench
├── scripts/
│   └── vhdl.f                         # File list for sim / synth
└── README.md
```

## Module Hierarchy

```
axi_read_tester_tb (testbench)
  ├── axi_read_tester (production IP)
  │     ├── axi_read_tester_ar_gen
  │     ├── axis_fifo (scoreboard)
  │     └── axi_read_tester_r_mon
  └── axi_mem_model (simulated memory)
```

- **`axi_read_tester`** — The reusable IP block.  Exposes AR and R buses
  externally so a real design connects them to an AXI interconnect / DUT.
- **`axi_read_tester_tb`** — Core corner-case testbench. Instantiates
  `axi_mem_model` directly on the AR/R buses for self-contained testing.
- **`axi_read_tester_simple_tb`** — Minimal smoke-test skeleton for custom
  stimulus development.
- **`axi4_read_tester_shim_tb` / `axi4_read_tester_multi_tb`** — VHDL-2019
  integration testbenches for the AXI4-Lite shim and multi-instance wrapper.

## Generics (`axi_read_tester`)

| Generic | Default | Description |
|---------|---------|-------------|
| `GC_DATA_BYTES` | 64 | Data bus width in bytes (e.g. 64 → 512-bit) |
| `GC_ADDR_WIDTH` | 49 | AXI address width |
| `GC_ID_WIDTH` | 6 | AXI ID width |
| `GC_TIME_WIDTH` | 48 | Global timestamp width (for latency) |
| `GC_SB_FIFO_DEPTH` | 256 | Scoreboard FIFO depth |

## Control Interface (`axi_read_tester`)

| Port | Direction | Description |
|------|-----------|-------------|
| `enable_local` | in | Per-instance enable — gates AR issue when low |
| `aperture` | in | Statistics gating window — stats only counted when high (in-flight bursts complete normally) |
| `stat_rst` | in | Clear statistics counters |
| `err_rst` | in | Clear error counters |
| `pipeline_busy` | out | '1' when scoreboard has entries or burst is in-flight |

## Configuration (`axi_read_tester`)

| Port | Width | Description |
|------|-------|-------------|
| `arid` | `GC_ID_WIDTH` | AXI read ID to use on all ARs |
| `burst_length` | 32 | Burst length in beats (1–256, clamped if out of range) |
| `pace` | 32 | Inter-burst gap in clock cycles |
| `pace_init` | 32 | Gap before the first burst (used once after enable) |
| `base_addr` | `GC_ADDR_WIDTH` | Start of the address window |
| `addr_range` | `GC_ADDR_WIDTH` | Size of the address window |
| `addr_mode` | 1 | 0 = linear sweep with wrap, 1 = PRNG random within window |

## AXI Buses (`axi_read_tester`)

| Channel | Signals | Direction (from tester) |
|---------|---------|------------------------|
| AR | `ar_valid`, `ar_ready`, `ar_id`, `ar_addr`, `ar_len` | Master → DUT |
| R | `r_valid`, `r_ready`, `r_id`, `r_data`, `r_resp`, `r_last` | DUT → Slave |

All bursts are INCR type.  `ar_size` and `ar_burst` are internal to the
AR generator.  `ar_len` = `burst_length - 1` (AXI convention).

## Statistics Outputs (`axi_read_tester`)

| Port | Width | Description |
|------|-------|-------------|
| `stat_xactions` | 32 | Completed transactions (bursts) |
| `stat_beats` | 32 | Total R beats received |
| `stat_latency_sum` | `GC_STAT_WIDTH` | Sum of all latencies (AR issue → last R beat) |
| `stat_latency_min` | 32 | Minimum latency observed |
| `stat_latency_max` | 32 | Maximum latency observed |
| `stat_first_latency_sum` | `GC_STAT_WIDTH` | Sum of first-beat latencies |
| `stat_first_latency_min` | 32 | Minimum first-beat latency |
| `stat_first_latency_max` | 32 | Maximum first-beat latency |
| `stat_interbeat_gap_sum` | `GC_STAT_WIDTH` | Sum of inter-beat gaps |
| `stat_interbeat_gap_min` | 32 | Minimum inter-beat gap observed |
| `stat_interbeat_gap_max` | 32 | Maximum inter-beat gap observed |
| `stat_ar_backpressure` | 32 | AR channel backpressure events |
| `stat_sb_backpressure` | 32 | Scoreboard backpressure events |
| `stat_ar_issued` | 32 | ARs successfully issued |
| `stat_cfg_errors` | 32 | Configuration errors (burst_length > 256, 4 KB boundary) |
| `stat_elapsed_cycles` | 32 | Elapsed clock cycles (gated by busy) |
| `stat_max_outstanding` | 32 | Peak outstanding AR count observed |

## Error Outputs (`axi_read_tester`)

| Port | Width | Description |
|------|-------|-------------|
| `stat_data_errors` | 32 | R data mismatches vs address-derived pattern |
| `stat_id_errors` | 32 | RID mismatches vs scoreboard |
| `stat_rlast_errors` | 32 | RLAST protocol errors (early or missing) |
| `stat_resp_errors` | 32 | RRESP ≠ OKAY errors |
| `stat_sb_underflow_errors` | 32 | R beat arrived with no scoreboard entry |

The VHDL-2019 AXI4 shim exposes these statistics through its AXI4-Lite
`i_data` register space at `0x8000 + index * 4`. The 48-bit sum values use
two words; the 32-bit values occupy one word. The shim register indices are:

| Index | Statistic |
|------:|-----------|
| 0 | `stat_xactions` |
| 1 | `stat_beats` |
| 2-3 | `stat_latency_sum` |
| 4 | `stat_latency_min` |
| 5 | Upper word of `stat_latency_min` (zero) |
| 6 | `stat_latency_max` |
| 7 | Upper word of `stat_latency_max` (zero) |
| 8-9 | `stat_first_latency_sum` |
| 10 | `stat_first_latency_min` |
| 11 | Upper word of `stat_first_latency_min` (zero) |
| 12 | `stat_first_latency_max` |
| 13 | Upper word of `stat_first_latency_max` (zero) |
| 14-15 | `stat_interbeat_gap_sum` |
| 16 | `stat_ar_backpressure` |
| 17 | `stat_sb_backpressure` |
| 18 | `stat_ar_issued` |
| 19 | `stat_cfg_errors` |
| 20 | `stat_elapsed_cycles` |
| 21 | `stat_data_errors` |
| 22 | `stat_id_errors` |
| 23 | `stat_rlast_errors` |
| 24 | `stat_resp_errors` |
| 25 | `stat_sb_underflow_errors` |
| 26 | `pipeline_busy` |
| 27 | `stat_max_outstanding` |
| 28 | `stat_interbeat_gap_min` |
| 29 | `stat_interbeat_gap_max` |

## Harness Ports (`axi_read_tester_harness`)

Same as `axi_read_tester` plus:

| Port | Width | Description |
|------|-------|-------------|
| `mem_enable` | 1 | Enable for the internal memory model |
| `mem_base_latency` | 16 | Base latency in clock cycles before R beats |
| `mem_base_beat_gap` | 16 | Base gap in clock cycles between R beats |
| `stat_max_outstanding` | 32 | Placeholder (tied to 0) |

AR and R buses are **internal** in the harness — not exposed as entity ports.

## Core Testbench

`axi_read_tester_tb.vhd` runs the following phases with reset between the
independent configuration phases:

| Phase | Description | Key Parameters |
|-------|-------------|----------------|
| P1 | Standard 16-beat bursts | `blen=16`, `lat=5/3` |
| P2 | Single-beat bursts | `blen=1` (arlen=0) |
| P3 | Maximum 256-beat bursts | `blen=256` |
| P4 | 4 KB boundary crossing | `base=0xFE0`, `blen=2` |
| P5 | Random addressing | `addr_mode='1'` |
| P6 | Zero latency | `lat=0`, `gap=0` |
| P7 | High latency stress | `lat=30`, `gap=10` |
| P8 | Aperture gating | aperture low → high |
| P9 | stat_rst / err_rst | reset during operation |
| P11 | Zero burst length | `burst_length=0` clamps to one beat |
| P12 | Burst length clamp | `burst_length=257` clamps to 256 and reports config error |
| P13 | In-flight reset | `aresetn` while bursts are active |

All phases are zero-error by design.  The `check_phase` procedure verifies
that `data`, `id`, `rlast`, `resp`, and `sb_underflow` error counters are
zero after each phase. It also checks exact beat/xaction counts, verifies
that accepted bursts stay inside the configured address window, and drains
the pipeline with bounded waits.

The shim and multi-instance testbenches are VHDL-2019 integration benches.
They are compile-checked with Questa 2025.3; runtime simulation is a separate
follow-up because they depend on the local VHDL-2019 simulator license.

## Scoreboard Format

Each 1-cycle entry pushed by the AR gen and popped by the R mon:

| Field | Bits | Source |
|-------|------|--------|
| `blen` | `[7:0]` | AXI arlen = `burst_length - 1` |
| `timestamp` | `[7+GC_TIME_WIDTH:8]` | `global_time` at AR issue |
| `arid` | `[7+GC_TIME_WIDTH+GC_ID_WIDTH:8+GC_TIME_WIDTH]` | `arid` port |
| `araddr` | `[top:bottom]` | AR address at issue |

## Dependencies

| Dependency | Path |
|------------|------|
| `util_pkg` | `../common/rtl/util_pkg.vhd` |
| `axis_fifo` | `../axis_fifo/rtl/axis_fifo.vhd` |
| `xorshift128` | `../parallel_prng/rtl/xorshift128.vhd` |
| `xorshift32` | `../parallel_prng/rtl/xorshift32.vhd` |
| `jitter_gen` | `../jitter_gen/rtl/jitter_gen.vhd` |
| `axis_latency_gen` | `../axis_latency_gen/rtl/axis_latency_gen.vhd` |
| `axi_mem_model` | `../axi_mem_model/rtl/axi_mem_model.vhd` (harness only) |

## Simulation Quick Start

```bash
# From fpga-ip root, with ModelSim on PATH:
run axi_read_tester vhdl modelsim
```

All 10 phases should print `PASS`.  Errors print `FAIL` with the
specific counter values.

## Design Rules

- **Two-process register-transfer style**: `p_comb` (next-state computation)
  + `p_reg` (clock-edge update) for all stateful blocks.
- **AXI-Stream backpressure**: R monitor uses combinational `r_ready`
  backpressure instead of cycle counting — timing-robust regardless of
  FIFO latency or clock frequency.
- **Scoreboard FIFO**: Uses the shared `axis_fifo` (FWFT, 1-cycle
  registered-output latency).  No custom FIFO logic.
- **PRNG**: `xorshift128` (xoroshiro128+) for 64-bit random address
  generation.  PRNG stepped once per burst in random mode.
