# axi_traffic_gen

Collection of lightweight AXI4 traffic generators.  Each generator is a
self-contained entity; today the IP provides the read-address generator
(`axi_ar_gen`) with room for additional specialized generators (e.g. a
write-address generator) in the same IP.

Licensed under Zero-Clause BSD (0BSD).

## AR generator (`axi_ar_gen`)

A lightweight AXI4 read-address generator.  It issues AR bursts at a
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

Standalone synthesis uses the `[top]` metadata line (`top = axi_ar_gen`)
-- the generator is its own top; no wrapper file is needed:

```bash
run axi_traffic_gen vhdl vivado
```
