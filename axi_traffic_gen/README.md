# axi_traffic_gen

Collection of lightweight client read-request (`req_*`) traffic
generators.  Each generator is a self-contained entity; today the IP
provides the client request generator (`axi_req_gen`) with room for
additional specialized generators in the same IP.

Licensed under Zero-Clause BSD (0BSD).

## Req generator (`axi_req_gen`)

A lightweight client read-request generator for the `req_*` interfaces
used by e.g. `axi_read_bridge`.  It issues req bursts at a configurable
`cfg_pace`, decoupled from response completion:

- `cfg_pace=0` -> a new req can be issued every clock cycle (back-to-back)
- `cfg_pace=1` -> every second cycle, `cfg_pace=2` -> every third, ...

It supports linear sweep and pseudo-random (XOR-shift) addressing within
a configured window.  Every presented start address is aligned to
`C_DATA_BYTES` and clamped to `[base, base+range-bsize]` (the full burst
always fits inside the window).  The client interface has no ID, so
there is no `ar_id`/`ar_size`/`ar_burst` sideband; `req_len` carries the
burst length (beats-1) and is sized by `GC_MAX_BURST`
(`log2ceil(GC_MAX_BURST)` bits), so the largest expressible burst is
`GC_MAX_BURST` beats.

The full req payload (`req_addr`, `req_len`) is latched when a burst is
presented and held stable until the handshake, so configuration changes
during backpressure cannot alter an in-flight transfer.

Optional random burst lengths are controlled by `cfg_len_mode`:

- `cfg_len_mode='0'` (default): every burst uses the fixed
  `cfg_req_len`.
- `cfg_len_mode='1'`: every presented burst draws its length from an
  independent `xorshift32` PRNG (separate seed from the address PRNG),
  stepped once per presented burst and clamped to `cfg_max_len`
  (beats-1), so burst lengths vary between 1 and `cfg_max_len+1` beats.
  Values above `cfg_max_len` clump at the maximum (mask-and-clamp, no
  divider) - acceptable for traffic generation.

In random-length mode each burst is fitted to its own drawn length, so
the full burst always fits inside `[base, base+range-bsize]` even though
`bsize` varies per burst.  `cfg_req_len`, `cfg_max_len`, and `req_len`
are all `log2ceil(GC_MAX_BURST)` bits wide.

Dependencies: `util_pkg` and the `xorshift128` / `xorshift32` entities
from `parallel_prng` (address and length PRNGs).

### Ports

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `aclk` / `aresetn` | in | 1 | Clock / synchronous active-low reset |
| `enable` | in | 1 | Per-instance enable (gates generation) |
| `aperture` | in | 1 | Measurement window (gates generation) |
| `stat_rst` | in | 1 | Clears statistic counters (not the FSM); takes priority over a coincident handshake |
| `cfg_req_len` | in | `log2ceil(GC_MAX_BURST)` | Fixed request length (beats-1); 0 = 1 beat |
| `cfg_len_mode` | in | 1 | `'0'` = fixed `cfg_req_len`, `'1'` = random length |
| `cfg_max_len` | in | `log2ceil(GC_MAX_BURST)` | Random length upper bound (beats-1) |
| `cfg_pace` | in | 32 | Idle cycles between reqs (0 = every cycle) |
| `cfg_pace_init` | in | 32 | Initial delay before first burst (first req appears `cfg_pace_init+1` cycles after reset) |
| `cfg_base_addr` | in | `GC_ADDR_WIDTH` | Start of address window |
| `cfg_addr_range` | in | `GC_ADDR_WIDTH` | Size of address window |
| `cfg_addr_mode` | in | 1 | `'0'` = linear sweep, `'1'` = pseudo-random |
| `req_valid` / `req_ready` | out/in | 1 | Client request handshake |
| `req_addr` | out | `GC_ADDR_WIDTH` | Request address |
| `req_len` | out | `log2ceil(GC_MAX_BURST)` | Request length (beats-1) |
| `stat_req_stall` | out | 32 | Req stall events (valid, not ready) |
| `stat_req_issued` | out | 32 | Reqs successfully issued |
| `stat_cfg_errors` | out | 32 | Configuration error count |

> Note: random mode (`cfg_addr_mode='1'`) requires `cfg_addr_range` to be a
> power of two (the offset is a bit-mask).  Linear mode accepts any
> range.

> When driving a consumer whose `req_len` port is wider than
> `log2ceil(GC_MAX_BURST)` (e.g. `axi_read_bridge`, 6 bits), zero-extend
> `req_len` at the instantiation site.  When it is narrower, keep
> `GC_MAX_BURST` small enough that generated lengths fit.

## Synthesis wrapper (`axi_req_gen_top`)

`rtl/axi_req_gen_top.vhd` is the synthesis top wrapper; it instantiates
`axi_req_gen` directly (all generics passed through) and is the `[top]`
in `scripts/vhdl.f` for the vivado/xsim flows.  A SystemVerilog
mixed-language wrapper (`rtl/axi_req_gen_top.sv`) is also provided.

```vhdl
u_req_gen : entity work.axi_req_gen
  generic map (
    GC_DATA_BYTES => 64,
    GC_ADDR_WIDTH => 32,
    GC_MAX_BURST  => 32
  )
  port map (
    aclk           => aclk,
    aresetn        => aresetn,
    enable         => enable,
    aperture       => aperture,
    stat_rst       => stat_rst,
    cfg_req_len    => cfg_req_len,
    cfg_len_mode   => cfg_len_mode,
    cfg_max_len    => cfg_max_len,
    cfg_pace       => cfg_pace,
    cfg_pace_init  => cfg_pace_init,
    cfg_base_addr  => cfg_base_addr,
    cfg_addr_range => cfg_addr_range,
    cfg_addr_mode  => cfg_addr_mode,
    req_valid      => req_valid,
    req_ready      => req_ready,
    req_addr       => req_addr,
    req_len        => req_len,
    stat_req_stall => stat_req_stall,
    stat_req_issued => stat_req_issued,
    stat_cfg_errors => stat_cfg_errors
  );
```

## Testbenches

### `axi_req_gen_tb` (integration)

Integration testbench for `axi_req_gen`.  Instantiates
`axi_req_gen -> axi_read_bridge -> axi_mem_model`, with `axi_monitor`
tapping the bridge client req/rsp to validate end-to-end tracking with
zero false errors.  The generator drives the bridge's single client
(the 5-bit `req_len` is zero-extended to the bridge's 6-bit port).

Every phase also runs a full stat audit: generator/monitor `req_stall`
cross-check, `elapsed`-vs-reference, `burst_len_sum == beats`, min<=max
and sum>=max consistency for the latency / first-latency / gap /
burst-length accumulator groups, `gap_min >= 1`, `max_outstanding > 0`,
and (at line rate) both `req_stall` counters counting.

Coverage (phases 1-7):

- **P1** -- fixed 4-beat bursts, line rate, linear addressing:
  monitor `req_seen` == generator `req_issued`, `xactions` ==
  `req_seen`, `beats` == `xactions*4`, burst-length 4/4, no errors.
- **P2** -- paced generation (`cfg_pace=2`), same accounting.
- **P3** -- random addressing (`cfg_addr_mode=1`), same accounting.
- **P4** -- random request length (`cfg_len_mode=1`, `cfg_max_len=15`):
  burst lengths vary within [1,16], all requests complete, no errors.
- **P4B** -- combined random modes (`cfg_addr_mode=1` + `cfg_len_mode=1`):
  both PRNGs step together, variable-length bursts fitted to random
  addresses (alignment + window verified per request), addresses and
  lengths both vary, no errors.
- **P5** -- response backpressure: generator `req_stall` and monitor
  `req_stall`/`rsp_stall` all count; accounting stays exact.
- **P6** -- maximum (32-beat, credit-limited) burst, `beats` ==
  `xactions*32`.
- **P7** -- `stat_rst` mid-traffic clears generator and monitor
  counters without corrupting in-flight tracking; clean window is
  exact.

```bash
run axi_traffic_gen vhdl modelsim            # default tb: axi_req_gen_tb
```

### `axi_req_gen_simple_tb` (hand-editable skeleton)

A minimal, hand-editable testbench for `axi_req_gen` with the same
integration chain as `axi_req_gen_tb`:
`axi_req_gen -> axi_read_bridge -> axi_mem_model`, with `axi_monitor`
tapping the bridge client req/rsp (all statistics and the address
alignment/window checker are wired).  Uses plain signal initialization
(defaults in the declarations) so tests can be added by editing the
sequencer process.  The sequencer is left as a skeleton for you to
populate.

```bash
run axi_traffic_gen vhdl modelsim --tb reqsimple
```
