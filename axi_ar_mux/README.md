# axi_ar_mux

Credit-based AXI4 Read-Address (AR) multiplexer: merges `GC_NUM_CLIENTS`
request interfaces into a single AXI4 AR channel, with fair round-robin
arbitration and per-client beat credits. It is the AR-side counterpart of
`axi_r_demux` - together they form a credit-mux: clients issue read
commands through this IP, the R responses return through `axi_r_demux`,
and that IP's `r_pop` outputs feed this IP's `r_pop` inputs to return
credits.

The default configuration is **4 clients, 32-bit address, 4-bit ID,
depth-32 credits** and the design forwards **one AR transaction per clock**
at its verified clock of **143 MHz** (7.0 ns period, post place & route)
with very low logic usage.

## Overview

Each client presents a read command (`req_addr`, `req_len`,
`req_valid`/`req_ready`). A per-client credit counter (the
R-side FIFO depth) limits how many beats that client may have in flight:
a request of `arlen + 1` beats is only arbitrated when its credits fit.
Round-robin arbitration picks a fair winner among eligible clients, the
transaction is forwarded on the shared AR channel with `ar_id` generated
from the client index, and `r_pop` pulses return a credit per R beat
popped from that client's FIFO.

### When to use this

- You must share one AXI master (e.g. a memory controller) between many
  requestors, each with its own R response path and elasticity.
- Pair it with `axi_r_demux`: `r_pop` credits from the demux return here.

### When NOT to use this

- You need one AR transaction per cycle *per* client (this IP shares one
  channel; arbitration is round-robin).
- You need to preserve arbitrary client-supplied AR IDs: the IP generates
  `ar_id` from the client index (the R demux routes by that ID).

## Generics

| Generic           | Range | Default | Description |
|-------------------|-------|---------|-------------|
| `GC_NUM_CLIENTS`  | `positive` | 4   | Number of request interfaces. |
| `GC_ADDR_WIDTH`   | `positive` | 32  | Address width in bits. |
| `GC_ID_WIDTH`     | `positive` | 4   | AR ID width; must satisfy `GC_ID_WIDTH >= ceil(log2(GC_NUM_CLIENTS))`. |
| `GC_FIFO_DEPTH`   | `positive >= 2` | 32 | Per-client beat credit limit (R-side FIFO depth, in client beats). |
| `GC_R_BEATS_PER_POP` | `positive` | 1 | Client beats returned per `r_pop`. Set to the R-side upsizer ratio when the R channel is wider than the client beat width. |

## Ports

| Port        | Dir | Description |
|-------------|-----|-------------|
| `aclk`      | in  | Clock. |
| `aresetn`   | in  | Synchronous reset, active low. |
| `req_addr`  | in  | Per-client ARADDR, `GC_ADDR_WIDTH` bits each. |
| `req_len`   | in  | Per-client ARLEN (beats - 1), 8 bits each. |
| `req_valid` | in  | Per-client request valid. |
| `req_ready` | out | Per-client request accepted (combinational, independent of `ar_ready`; one pending request can be buffered). |
| `r_pop`     | in  | Per-client credit return pulses (one per R beat popped). |
| `ar_id`     | out | AR ID (client index), `GC_ID_WIDTH` bits. |
| `ar_addr`   | out | ARADDR of the forwarded transaction. |
| `ar_len`    | out | ARLEN of the forwarded transaction. |
| `ar_valid`  | out | Forwarded transaction valid (registered, holds until handshake). |
| `ar_ready`  | in  | Downstream accepts the forwarded transaction. |

The `req_*` / `r_pop` ports are arrays indexed by client (`0 .. GC_NUM_CLIENTS-1`).

## How It Works

RTL follows the canonical **two-process method** from the fpga-rules
(`hdl_coding_rules.md`): a single state record (`rec_t`), a combinational
next-state/output process (`p_logic`), and a register process (`p_reg`).
The micro-architecture is:

1. **Registered AR outputs with one-entry prefetch.** `ar_valid`/`ar_id`/
  `ar_addr`/`ar_len` are registered from an active
  transaction record, so `ar_valid` holds until the handshake. One pending
  request can be accepted while AR is stalled. `req_ready` is combinational
  from the current exact arbitration and pending-slot availability, and is
  independent of `ar_ready`.

2. **Line-rate forwarding.** When the downstream keeps `ar_ready` high and
  an eligible client stream is ready, a new transaction is captured in the
  same cycle the previous one handshakes. The pending slot also allows a
  client to present its next request before that handshake, so the AR
  channel forwards **one transaction per clock** after the initial fill.

3. **Holding / lock.** While `ar_ready` is low, the active transaction is
  held (registered) with `ar_valid` high. One additional request may be
  accepted into the pending slot, but it is not presented on AR until the
  active transaction handshakes. This preserves the AXI requirement that
  `ar_valid` and its payload remain stable until the handshake.

### Request-to-AR latency

For a request that is accepted and immediately selected by the arbiter, with
`ar_ready='1'`, the minimum request-to-AR handshake latency is **2 `aclk`
cycles**:

```text
Edge N   : req_valid & req_ready handshake; request enters the client buffer
Edge N+1 : registered grant enters the active AR slot; ar_valid becomes high
Edge N+2 : ar_valid & ar_ready handshake
```

The `ar_valid` transition is visible after edge N+1, but the AR transfer is
sampled at edge N+2. This latency comes from the registered grant and active
AR slot. A request may take longer if another client is selected first, if
the request waits for credit, or if `ar_ready='0'`. The fixed two-cycle
pipeline latency does not create a steady-state throughput bubble: after the
pipeline is filled, eligible requests can produce one AR handshake per clock.
The first-request self-priming behavior keeps `req_ready` asserted on the
initial request; it does not bypass the registered AR pipeline.

4. **Credit tracking.** Each client starts with `GC_FIFO_DEPTH` credits. A
  request is captured into a per-client input buffer on `req_valid &
  req_ready`, and `arlen + 1` credits are debited when that transaction is
  granted and forwarded onto the shared AR channel (per client, the active
  and one pending transaction can be in flight). Each `r_pop` pulse
  returns `GC_R_BEATS_PER_POP` credits, saturated at `GC_FIFO_DEPTH`. A
  request is only arbitrated when its beat count fits the remaining
  credits, so a client can never over-issue beyond its R-side buffer.

5. **Round-robin arbitration.** After every grant the pointer moves past the
   served client; the next grant scans from there, giving fair access with
   wrap-around. Ineligible (no credit) clients are skipped.

## Request Size Contract

A single request must fit the per-client credit budget: its beat count
(`req_len + 1`) must be at most `GC_FIFO_DEPTH`. Credits are capped at
`GC_FIFO_DEPTH` and only return via `r_pop`, and `r_pop` cannot pulse
before the request is granted, so a request with `req_len + 1 >
GC_FIFO_DEPTH` can **never** be granted - presenting one deadlocks the
client's channel. The RTL flags such a request at presentation time
(assert, severity `failure`):

```text
axi_ar_mux: request beats N exceeds GC_FIFO_DEPTH M; request can never be granted
```

Clients must split transfers larger than `GC_FIFO_DEPTH` beats into
multiple requests (e.g. one per `GC_FIFO_DEPTH`-beat window), or raise
`GC_FIFO_DEPTH` to cover the largest single request.

## AXI Read-Address Channel

The mux forwards the variable AR fields `ar_id` (client index), `ar_addr`,
`ar_len`, `ar_valid`/`ar_ready`. `ar_id` is generated from the client index
so the R responses can be routed back by `axi_r_demux` (its `r_id` decode uses
the same index). ARSIZE, ARBURST, and other AXI AR sidebands are fixed by the
integration wrapper or downstream interface.

### Wider R side (axis_upsizer)

Credits are counted in **client beats** (`arlen + 1` is debited per
request). If the R channel is wider than the client beat width - for
example an `axis_upsizer` packs `GC_RATIO` client beats into one wide R
beat - then each R beat returned to the client's buffer covers
`GC_RATIO` client beats, so set `GC_R_BEATS_PER_POP = GC_RATIO`. One
`r_pop` (one wide beat popped from the demux FIFO) then returns
`GC_RATIO` credits, and `GC_FIFO_DEPTH` should be set to the R-side FIFO
depth times `GC_RATIO` to keep the same number of in-flight R beats.

## Compliance and assumptions

The client request interface uses standard valid/ready semantics. A client
must hold `req_addr` and `req_len` stable while `req_valid='1'` and
`req_ready='0'`, and may present a new request after a
handshake without deasserting `req_valid`. The mux captures the payload and
beat count from the same handshake.

`r_pop` must represent a real pop from the corresponding R-side FIFO. Extra
credit returns are saturated at `GC_FIFO_DEPTH` as a defensive measure, but
`GC_R_BEATS_PER_POP` must still match the actual R-side packing ratio.

## Synthesis Results (measured, 4 clients @ 143 MHz)

Standalone `run axi_ar_mux vhdl vivado batch` on **Artix-7
xc7a35tftg256-1**, Vivado 2023.2, default 4-client config:

| Resource | Usage |
|----------|-------|
| Slice LUTs | **270** |
| Slice Registers | **333** |
| F7 / F8 Muxes | 0 |
| Block RAM / DSP | 0 |
| WNS @ 143 MHz | **+0.109 ns** (post place & route, all endpoints met) |

The clock is applied from `constraints/axi_ar_mux.xdc`
(`create_clock -period 7.000` on `aclk`).

**Frequency note:** the critical path is the exact-credit arbitration loop
(credit check, round-robin scan and grant selection in one cycle). It does
not close at the original 200 MHz / 5.0 ns target (post-route WNS
-1.37 ns); the verified ceiling is **143 MHz (7.0 ns)**. Resource counts
and WNS are from a full **place & route** implementation (`opt_design` +
`place_design` + `route_design` + `phys_opt_design` +
`report_timing_summary`). That implementation runs on a larger package
(**xc7a200tfbg676-1**) because the 4-client/32-bit wrapper has ~245 I/O
ports, more than the 170 pins available on `xc7a35tftg256-1`; the logic is
identical, so the internal timing is representative. See
`fpga-rules/vivado_synthesis_guide.md` (Timing Closure & WNS Measurement).

### Possible timing improvement: delayed credit returns (measured, not adopted)

The exact-credit reservation is the critical path (`credit_cnt` register
-> beat subtract -> same-edge eligibility/`req_ready` -> buffer capture).
The `r_pop` credit-return add sits on that chain because returns are
applied before the eligibility computation. A candidate optimization
applies returns **only to the register update** (visible one edge later)
so the saturating add leaves the ready/eligibility path:

- Measured (Vivado 2023.2, `xc7a200tfbg676-1`, default 4-client config,
  same place & route flow): synthesis-only WNS at 143 MHz improves
  **-1.337 ns -> -0.561 ns**; post-route WNS improves **-0.195 ns
  -> +0.054 ns** (the design goes from a small violation to meeting
  timing).
- Trade-off: a credit return becomes visible to `req_ready` / arbitration
  **one cycle later**. This is conservative - the stored credit stays
  exact and a client can never over-issue. A request presented in the
  same cycle as a pop waits one cycle (one bubble, only at the exact
  credit boundary); steady-state line rate is unaffected.
- **Not adopted**: the one-cycle return latency changes the documented
  `r_pop` behavior (a same-edge pop no longer enables an immediate
  capture). The RTL keeps the eager same-edge return; the note in
  `rtl/axi_ar_mux.vhd` marks where this change would go.

## Reset

Synchronous active-low reset (`aresetn`) clears the active and pending
transactions, the round-robin pointer, and restores all credits to
`GC_FIFO_DEPTH`. `req_ready` is suppressed while reset is asserted; all
registered AR outputs are cleared after the reset edge.

## Instantiation

The examples below use the default **4-client, 32-bit-address, 4-bit-ID,
depth-32** configuration. The array ports use the shared package types
`slv_array_t` / `slv8_array_t` from `work.util_pkg`, so the instantiating
design must include `use work.util_pkg.all;` in VHDL.

### VHDL

```vhdl
use work.util_pkg.all;  -- slv_array_t, slv8_array_t

-- ---------------------------------------------------------------------
-- Signals (grouped by interface)
-- ---------------------------------------------------------------------
constant C_NUM_CLIENTS : positive := 4;   -- must match GC_NUM_CLIENTS

-- Clock / reset
signal aclk    : std_logic;
signal aresetn : std_logic;  -- synchronous, active low

-- Client request interfaces (array indexed 0..C_NUM_CLIENTS-1)
signal req_addr  : slv_array_t(0 to C_NUM_CLIENTS-1)(31 downto 0);  -- araddr
signal req_len   : slv8_array_t(0 to C_NUM_CLIENTS-1);              -- arlen (beats-1)
signal req_valid : std_logic_vector(0 to C_NUM_CLIENTS-1);
signal req_ready : std_logic_vector(0 to C_NUM_CLIENTS-1);
signal r_pop     : std_logic_vector(0 to C_NUM_CLIENTS-1);          -- credits from axi_r_demux

-- AXI AR channel (mux -> downstream)
signal ar_id    : std_logic_vector(3 downto 0);   -- client index
signal ar_addr  : std_logic_vector(31 downto 0);  -- araddr
signal ar_len   : std_logic_vector(7 downto 0);   -- arlen
signal ar_valid : std_logic;
signal ar_ready : std_logic;

-- ---------------------------------------------------------------------
-- Instantiation (grouped port map)
-- ---------------------------------------------------------------------
u_armux : entity work.axi_ar_mux
  generic map (
    GC_NUM_CLIENTS => 4,  -- number of clients
    GC_ADDR_WIDTH  => 32, -- address width (bits)
    GC_ID_WIDTH    => 4,  -- AR ID width (bits)
    GC_FIFO_DEPTH  => 32  -- per-client beat credits
  )
  port map (
    -- Clock / reset
    aclk    => aclk,
    aresetn => aresetn,

    -- Client request interfaces
    req_addr  => req_addr,
    req_len   => req_len,
    req_valid => req_valid,
    req_ready => req_ready,

    -- Credit returns (from axi_r_demux r_pop)
    r_pop => r_pop,

    -- AXI AR channel
    ar_id    => ar_id,
    ar_addr  => ar_addr,
    ar_len   => ar_len,
    ar_valid => ar_valid,
    ar_ready => ar_ready
  );
```

### SystemVerilog

```systemverilog
// ---------------------------------------------------------------------
// Signals (grouped by interface)
// ---------------------------------------------------------------------
localparam int unsigned C_NUM_CLIENTS = 4;  // must match GC_NUM_CLIENTS

// Clock / reset
logic aclk;
logic aresetn;  // synchronous, active low

// Client request interfaces (packed arrays, client index outer)
logic [C_NUM_CLIENTS-1:0][31:0] req_addr;
logic [C_NUM_CLIENTS-1:0][7:0]  req_len;
logic [C_NUM_CLIENTS-1:0]       req_valid;
logic [C_NUM_CLIENTS-1:0]       req_ready;
logic [C_NUM_CLIENTS-1:0]       r_pop;  // credits from axi_r_demux

// AXI AR channel (mux -> downstream)
logic [3:0]   ar_id;     // client index
logic [31:0]  ar_addr;   // araddr
logic [7:0]   ar_len;    // arlen
logic         ar_valid;
logic         ar_ready;

// ---------------------------------------------------------------------
// Instantiation (grouped port map)
// ---------------------------------------------------------------------
axi_ar_mux #(
    .GC_NUM_CLIENTS (4),  // number of clients
    .GC_ADDR_WIDTH  (32), // address width (bits)
    .GC_ID_WIDTH    (4),  // AR ID width (bits)
    .GC_FIFO_DEPTH  (32)  // per-client beat credits
) u_armux (
    // Clock / reset
    .aclk    (aclk),
    .aresetn (aresetn),

    // Client request interfaces
    .req_addr  (req_addr),
    .req_len   (req_len),
    .req_valid (req_valid),
    .req_ready (req_ready),

    // Credit returns (from axi_r_demux r_pop)
    .r_pop (r_pop),

    // AXI AR channel
    .ar_id    (ar_id),
    .ar_addr  (ar_addr),
    .ar_len   (ar_len),
    .ar_valid (ar_valid),
    .ar_ready (ar_ready)
);
```

`rtl/axi_ar_mux_top.vhd` / `rtl/axi_ar_mux_top.sv` expose the same ports
with the 4-client, 32-bit-address, 4-bit-ID, depth-32 defaults, for use as
a standalone synthesis top. The SV wrapper binds the VHDL array ports as
packed arrays (client index in the outer dimension) and explicitly reverses
the packed outer dimension so SV client index 0 maps to VHDL client index 0.

## Running the Testbench

```text
run axi_ar_mux vhdl modelsim   # ModelSim batch (default target)
run axi_ar_mux vhdl vivado     # Vivado synthesis + 143 MHz timing check
run axi_ar_mux vhdl xsim       # XSim simulation
```

The Vivado flow synthesizes `rtl/axi_ar_mux_top.vhd` and applies
`constraints/axi_ar_mux.xdc` (143 MHz clock), reporting WNS in
`.runs/vivado/timing.rpt` as a performance self-check. That constraint is
for the standalone flow only - integration designs supply their own clocks
and should not include the file.

The testbench (`tb/axi_ar_mux_tb.vhd`, 143 MHz clock, generic
clients/address/ID/credit) verifies:

- **Reset:** all `req_ready` low, `ar_valid` low.
- **Single transaction:** `req_ready` pulses (pipelined grant accept), the
  AR channel presents the correct `ar_id`/`ar_addr`/`ar_len`, and the credit
  drops by `arlen + 1` after the handshake. Fixed AXI AR attributes are
  supplied by the wrapper or integration boundary.
- **AR lock:** with `ar_ready` low, `ar_valid` holds the transaction, no
  other client is granted, and the handshake completes on release.
- **Credit limits + pop returns:** an over-credit request is blocked;
  `r_pop` pulses restore credits and unblock it; re-block at zero credit is
  verified.
- **Concurrent credit return:** an `r_pop` coincident with an AR handshake
  is accounted for on the same client.
- **Partial-credit arbitration:** an oversized request is skipped when
  another client has a request that fits.
- **Input line rate (hard guard):** with every client requesting and
  `ar_ready` high, the AR channel forwards **one transaction per clock** -
  `ar_valid` is asserted to never deassert - and round-robin order (with
  wrap-around) is checked on every transaction.
- **Single-client line rate:** unique payloads are accepted and forwarded on
  consecutive cycles, proving that a held-valid source can issue new
  requests without a bubble.
- **Exhausted budget:** after draining a client's full credit, its next
  request is not granted until a pop returns credit.
- **Mid-stream reset:** `aresetn` pulses low while a transaction is locked
  in flight; verifies clean recovery and a working post-reset transaction.
- A watchdog so a deadlock fails instead of hanging.

The testbench ends with the banner:

```text
** Note: ALL AR-MUX CHECKS PASSED
```

Configurations are provided via `[tb:<name>]` manifest sections:

| Config | Generics | Purpose |
|--------|----------|---------|
| `default` | 4 clients, 32-bit, ID 4, depth 32 | Primary configuration. |
| `depth32` | 4 clients, depth 32 | Explicit actual-default credit width. |
| `c1` | 1 client, ID width 1, depth 4 | Minimum client count. |
| `c2` | 2 clients, ID width 1, depth 4 | Two-client routing. |
| `c3` | 3 clients, ID width 2, depth 4 | Non-power-of-two client count. |
| `small` | 4 clients, depth 4 | Shallow credit corner. |
| `min2` | 4 clients, depth 2 | Minimum FIFO depth. |
| `nonpow5` | 4 clients, depth 5 | Non-power-of-two credit width. |
| `wide` | 8 clients, depth 8 | Many clients. |
| `ratio2` | 4 clients, `GC_R_BEATS_PER_POP=2` | Wider R-side (upsizer) credit returns. |
| `ratio3` | 4 clients, `GC_R_BEATS_PER_POP=3` | Non-power-of-two R-side ratio. |
| `maxlen` | 1 client, depth 256 | Maximum 256-beat ARLEN. |
