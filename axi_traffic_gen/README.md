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
during backpressure cannot alter an in-flight transfer. Every generated burst
also stays within one 4 KiB AXI address page, including random-address mode.

### Critical AXI 4 KiB boundary rule

An AXI burst must never cross a 4 KiB address boundary. This applies to every
request length, not only the maximum burst. The complete burst must satisfy:

```text
(req_addr AND 0xFFF) + ((req_len + 1) * GC_DATA_BYTES) <= 4096
```

`req_len` is encoded as beats minus one. For the default 64-byte client beat:

| `req_len` | Beats | Burst size | Latest legal 4 KiB-page offset |
|---:|---:|---:|---:|
| 0 | 1 | 64 bytes | `0xFC0` |
| 1 | 2 | 128 bytes | `0xF80` |
| 3 | 4 | 256 bytes | `0xF00` |
| 31 | 32 | 2048 bytes | `0x800` |

For example, a two-beat request starting at page offset `0xFC0` accesses
`0xFC0..0x103F` and crosses into the next 4 KiB page. Such a burst violates
the AXI address-channel rule. An interconnect or memory port may split it,
return unexpected data, or otherwise behave in a way that causes downstream
data checking to fail rather than returning a clean error response.

This failure is especially easy to trigger in pseudo-random address mode. With
64-byte alignment and a two-beat burst, one of every 64 aligned page offsets
is invalid, so approximately 1/64 of requests can fail. Longer bursts have a
larger invalid tail region. Linear traffic can hide the problem when its step
larger invalid tail region.

Linear traffic can hide the problem because it does not visit every aligned
offset independently. For example, with a page-aligned base address, 64-byte
beats, and two-beat requests, the generator advances by 128 bytes:

```text
0x0000, 0x0080, 0x0100, ..., 0x0F80, 0x0000, ...
```

Every one of those starts is safe for a 128-byte burst; the final start is
`0x0F80`, whose burst ends exactly at `0x1000`. The invalid offset `0x0FC0`
is never generated. A pseudo-random generator, by contrast, can select
`0x0FC0`, so the same design appears correct in a linear test while failing
intermittently in a random-address test.

`axi_req_gen` therefore clamps every presented address against both the
configured address window and the 4 KiB page limit, in linear and random
address modes and with fixed or random burst lengths. Do not remove this
containment when changing the address generator. If `GC_DATA_BYTES` or the
maximum burst is changed, retain the same rule and ensure the maximum burst
fits within one 4 KiB page.

The integration testbench asserts the 4 KiB condition for every accepted
request, including the combined random-address/random-length phase. A passing
testbench is required before using the generator with an AXI memory port.

Optional random burst lengths are controlled by `cfg_len_mode`:

- `cfg_len_mode='0'` (default): every burst uses the fixed
  `cfg_req_len`.
- `cfg_len_mode='1'`: every presented burst draws its length from an
  independent `xorshift32` PRNG (separate seed from the address PRNG),
  uniformly distributed over 1 .. `cfg_max_len+1` beats.

The random-length draw is divider-free:

- The draw is the top `log2ceil(GC_MAX_BURST)` bits of the PRNG (the
  best-mixed bits of xorshift32), masked down to the power of two that
  covers `0 .. cfg_max_len`.  The mask keeps the draw range as small as
  possible, which is what keeps the acceptance rate high.
- A draw above `cfg_max_len` is rejected: the generator presents no burst
  that cycle and takes a fresh draw on the next one.  The length PRNG
  free-runs while `cfg_len_mode='1'`, so a fresh draw is always one cycle
  away, and the counter that would need a modulo is simply not there.
  Rejecting (instead of clamping) is what leaves the surviving lengths
  uniform - a mask-and-clamp draw would clump at `cfg_max_len`.
- Acceptance is `N/2**k` with `N = cfg_max_len+1 > 2**(k-1)`, so a draw is
  accepted at least every second cycle, and exactly one idle cycle is
  added per rejected draw (`cfg_pace=0`).  When `cfg_max_len+1` is itself
  a power of two - e.g. `cfg_max_len=15` for 16-beat bursts - nothing is
  ever rejected and random-length mode runs at exactly `cfg_pace`.

`cfg_max_len` above `GC_MAX_BURST-1` is clamped to the credit limit and
counted in `stat_cfg_errors`.

The integration testbench checks the distribution, not just the bounds:
phase P4 and P4B (`cfg_max_len=15`, nothing rejected) and phase P4C
(`cfg_max_len=11`, so 4 of every 16 draws are rejected) assert that both
length extremes occur and that the mean burst length sits at the midpoint
of `1 .. cfg_max_len+1`.  A regression back to clamping would show up as a
mean that is far too high, or as bursts longer than `cfg_max_len+1`.

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

> Note: random mode (`cfg_addr_mode='1'`) **requires** `cfg_addr_range` to be
> a power of two: the random offset is `prng AND (cfg_addr_range-1)`.  A
> non-power-of-two range does not simply stop working - it silently skips
> part of the window (the mask clears bits of the offset, so a whole block of
> offsets between `base` and `base+range` can never be generated), which
> would leave memory untested without reporting an error.  Linear mode
> (`cfg_addr_mode='0'`) accepts any range.

> When driving a consumer whose `req_len` port is wider than
> `log2ceil(GC_MAX_BURST)` (e.g. `axi_read_bridge`, 6 bits), zero-extend
> `req_len` at the instantiation site.  When it is narrower, keep
> `GC_MAX_BURST` small enough that generated lengths fit.

## Synthesis wrapper (`axi_req_gen_top`)

`top/axi_req_gen_top.vhd` is the synthesis top wrapper; it instantiates
`axi_req_gen` directly (all generics passed through) and is the `[top]`
in `scripts/vhdl.f` for the vivado/xsim flows.  A SystemVerilog
mixed-language wrapper (`top/axi_req_gen_top.sv`) is also provided.

The integration testbenches include `axi_read_bridge`, which contains
`axis_cdc` instances. When implementing that integration in Vivado, apply and
adapt the constraints in `axis_cdc/constr/` for the actual clocks and
synthesized hierarchy.

## Instantiation

The examples below use the default **64-byte, 32-bit-address,
32-beat-max-burst** configuration.  `req_len` is beats minus one and is
`log2ceil(GC_MAX_BURST)` bits wide (5 bits with the default).  When the
consumer's `req_len` port is wider, zero-extend `req_len` at the
instantiation site.

### VHDL

```vhdl
-- ---------------------------------------------------------------------
-- Signals (grouped by interface)
-- ---------------------------------------------------------------------
constant C_LEN_WIDTH : positive := 5;  -- log2ceil(GC_MAX_BURST)

-- Clock / reset
signal aclk    : std_logic;
signal aresetn : std_logic;  -- synchronous, active low

-- Control
signal enable   : std_logic;  -- per-instance enable
signal aperture : std_logic;  -- measurement window
signal stat_rst : std_logic;  -- clears statistic counters

-- Runtime configuration
signal cfg_req_len    : std_logic_vector(C_LEN_WIDTH-1 downto 0);
signal cfg_len_mode   : std_logic;
signal cfg_max_len    : std_logic_vector(C_LEN_WIDTH-1 downto 0);
signal cfg_pace       : std_logic_vector(31 downto 0);
signal cfg_pace_init  : std_logic_vector(31 downto 0);
signal cfg_base_addr  : std_logic_vector(31 downto 0);
signal cfg_addr_range : std_logic_vector(31 downto 0);
signal cfg_addr_mode  : std_logic;

-- Client request channel (generator -> consumer)
signal req_valid : std_logic;
signal req_ready : std_logic;
signal req_addr  : std_logic_vector(31 downto 0);
signal req_len   : std_logic_vector(C_LEN_WIDTH-1 downto 0);

-- Statistics
signal stat_req_stall  : std_logic_vector(31 downto 0);
signal stat_req_issued : std_logic_vector(31 downto 0);
signal stat_cfg_errors : std_logic_vector(31 downto 0);

-- ---------------------------------------------------------------------
-- Instantiation (grouped port map)
-- ---------------------------------------------------------------------
u_req_gen : entity work.axi_req_gen
  generic map (
    GC_DATA_BYTES => 64,  -- beat width (bytes)
    GC_ADDR_WIDTH => 32,  -- address width (bits)
    GC_MAX_BURST  => 32   -- max beats per burst
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

### SystemVerilog

```systemverilog
// ---------------------------------------------------------------------
// Signals (grouped by interface)
// ---------------------------------------------------------------------
localparam int unsigned C_LEN_WIDTH = 5;  // $clog2(GC_MAX_BURST)

// Clock / reset
logic aclk;
logic aresetn;  // synchronous, active low

// Control
logic enable;    // per-instance enable
logic aperture;  // measurement window
logic stat_rst;  // clears statistic counters

// Runtime configuration
logic [C_LEN_WIDTH-1:0] cfg_req_len;
logic                   cfg_len_mode;
logic [C_LEN_WIDTH-1:0] cfg_max_len;
logic [31:0]            cfg_pace;
logic [31:0]            cfg_pace_init;
logic [31:0]            cfg_base_addr;
logic [31:0]            cfg_addr_range;
logic                   cfg_addr_mode;

// Client request channel (generator -> consumer)
logic                   req_valid;
logic                   req_ready;
logic [31:0]            req_addr;
logic [C_LEN_WIDTH-1:0] req_len;

// Statistics
logic [31:0] stat_req_stall;
logic [31:0] stat_req_issued;
logic [31:0] stat_cfg_errors;

// ---------------------------------------------------------------------
// Instantiation (grouped port map)
// ---------------------------------------------------------------------
axi_req_gen #(
    .GC_DATA_BYTES (64),  // beat width (bytes)
    .GC_ADDR_WIDTH (32),  // address width (bits)
    .GC_MAX_BURST  (32)   // max beats per burst
) u_req_gen (
    .aclk           (aclk),
    .aresetn        (aresetn),
    .enable         (enable),
    .aperture       (aperture),
    .stat_rst       (stat_rst),
    .cfg_req_len    (cfg_req_len),
    .cfg_len_mode   (cfg_len_mode),
    .cfg_max_len    (cfg_max_len),
    .cfg_pace       (cfg_pace),
    .cfg_pace_init  (cfg_pace_init),
    .cfg_base_addr  (cfg_base_addr),
    .cfg_addr_range (cfg_addr_range),
    .cfg_addr_mode  (cfg_addr_mode),
    .req_valid      (req_valid),
    .req_ready      (req_ready),
    .req_addr       (req_addr),
    .req_len        (req_len),
    .stat_req_stall (stat_req_stall),
    .stat_req_issued(stat_req_issued),
    .stat_cfg_errors(stat_cfg_errors)
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
  burst lengths vary within [1,16], and the measured distribution is
  checked (both extremes, mean at the midpoint of the range), not just
  the bounds; all requests complete, no errors.
- **P4B** -- combined random modes (`cfg_addr_mode=1` + `cfg_len_mode=1`):
  both PRNGs step together, variable-length bursts fitted to random
  addresses (alignment + window + 4 KiB boundary verified per request),
  addresses and lengths both vary, no errors.
- **P4C** -- random length with a bound that is not a power of two minus
  one (`cfg_max_len=11`): 4 of every 16 draws are rejected, so this phase
  exercises the rejection path - lengths must stay within [1,12] and the
  distribution must still be uniform, which fails if the draw is clamped
  or unmasked; also proves rejection cannot starve the generator.
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
