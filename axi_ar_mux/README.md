# axi_ar_mux

Credit-based AXI4 Read-Address (AR) multiplexer: merges `GC_NUM_CLIENTS`
request interfaces into a single AXI4 AR channel, with fair round-robin
arbitration and per-client beat credits. It is the AR-side counterpart of
`axi_r_demux` - together they form a credit-mux: clients issue read
commands through this IP, the R responses return through `axi_r_demux`,
and that IP's `r_pop` outputs feed this IP's `r_pop` inputs to return
credits.

The default configuration is **4 clients, 32-bit address, 4-bit ID,
depth-32 credits** and the design forwards **one AR transaction per clock**.
It passes twelve generic configurations on both ModelSim and XSim, and
closes timing at **200 MHz** post place & route; see "Timing" below.

## Documentation

| Document | Contents |
|----------|----------|
| `README.md` | This file: integration guide, behaviour, results. |
| `AR_MUX_ARCHITECTURE.md` | Internal structure, invariants and timing, in detail. |
| `AR_MUX_REVIEW.md` | Review of revision 1.01. Its debug checklist for a quiet AR channel still applies. |

## Changes from revision 1.01

Revision 2.00 charges credit when a request is **accepted**, instead of when
it is granted. The ports and generics are unchanged. Two behaviours differ:

| | 1.01 | 2.00 |
|---|---|---|
| `r_pop` -> credit visible to `req_ready` | same edge | **two edges later** (`r_pop` is registered on input) |
| Request that does not fit | could be taken in, then waited inside the mux | refused: waits at `req_ready='0'` |
| Timing | -1.566 ns at 143 MHz | **+0.436 ns at 200 MHz** |

A client that waits for returned credit must keep its request presented,
which AXI valid/ready already requires.

## Overview

Each client presents a read command (`req_addr`, `req_len`,
`req_valid`/`req_ready`). A per-client credit counter (the
R-side FIFO depth) limits how many beats that client may have in flight:
a request of `arlen + 1` beats is only accepted when its credits fit.
Round-robin arbitration picks a fair winner among the accepted requests, the
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
| `req_ready` | out | Per-client request accepted. Combinational from registered state and the presented `req_len`; independent of `ar_ready`. |
| `r_pop`     | in  | Per-client credit return pulses (one per R beat popped). Registered on input. |
| `ar_id`     | out | AR ID (client index), `GC_ID_WIDTH` bits. |
| `ar_addr`   | out | ARADDR of the forwarded transaction. |
| `ar_len`    | out | ARLEN of the forwarded transaction. |
| `ar_valid`  | out | Forwarded transaction valid (registered, holds until handshake). |
| `ar_ready`  | in  | Downstream accepts the forwarded transaction. |

The `req_*` / `r_pop` ports are arrays indexed by client (`0 .. GC_NUM_CLIENTS-1`).

## How It Works

This section is a summary. `AR_MUX_ARCHITECTURE.md` describes the internal
structure in detail.

RTL follows the canonical **two-process method** from the fpga-rules
(`hdl_coding_rules.md`): a single state record (`rec_t`), one combinational
process (`p_comb`) and one register process (`p_reg`). `p_comb` is split
into three sections that each own part of the state:

| Section | Owns | Decides |
|---------|------|---------|
| AR side | `ar_active`, `ar_pending` | Retire an accepted transaction, promote the pending one. |
| Arbitration | `last_granted` | Grant one held request per clock while `ar_pending` is empty. |
| Admission and credits | `held_request`, `credits`, `r_pop_delayed` | Per client: accept a request if its holding register is free and its credits cover it. |

The key design decision is **credit is charged when a request is accepted,
not when it is granted**. Every held request is therefore already paid for,
so arbitration never looks at credits, and each client's credit counter is a
small independent loop. That split is what makes the design close at
200 MHz.

1. **Registered AR outputs with one pending slot.** `ar_valid`/`ar_id`/
  `ar_addr`/`ar_len` come from `ar_active`, so `ar_valid` holds until the
  handshake. One further grant can wait in `ar_pending` while AR is
  stalled. Arbitration only checks whether `ar_pending` is empty, never
  `ar_ready`, so `req_ready` is independent of `ar_ready`.

2. **Line-rate forwarding.** A client's holding register accepts a new
  request in the same cycle its previous one is granted, so with
  `ar_ready` high the AR channel forwards **one transaction per clock**,
  from a single client or shared round-robin between several.

3. **Holding / lock.** While `ar_ready` is low, the active transaction is
  held with `ar_valid` high. One further grant moves to `ar_pending`, and
  after that requests wait in their holding registers. This preserves the
  AXI requirement that `ar_valid` and its payload remain stable until the
  handshake.

4. **Credit tracking.** Each client starts with `GC_FIFO_DEPTH` credits.
  `arlen + 1` credits are charged on the `req_valid & req_ready` handshake,
  and a request is only accepted when they fit, so a client can never
  over-issue beyond its R-side buffer. Each `r_pop` pulse returns
  `GC_R_BEATS_PER_POP` credits, saturated at `GC_FIFO_DEPTH`. `r_pop` is
  registered on input, so a request waiting on returned credits is
  accepted **two edges** after the `r_pop` pulse.

5. **Round-robin arbitration.** Each grant goes to the first held request
  after `last_granted`, wrapping, giving fair access. Only accepted
  requests take part, so a client without credit cannot block the others.

### `req_ready` semantics

`req_ready(i)` is high when client *i*'s holding register is free (empty,
or its request is granted this clock) **and** either no request is
presented or the presented request fits the client's credits. So:

- An idle client sees `req_ready` high, so its first request is accepted on
  the first clock.
- While a request is presented, `req_ready` depends combinationally on
  `req_valid` and `req_len`. AXI allows this. The client must not make
  `req_valid` depend on `req_ready`, and the integrating design must time
  the `req_len` -> `req_ready` path.
- `req_ready` does not depend on `ar_ready`.

Per client, at most three requests are inside the mux at once: one in its
holding register, plus up to two in `ar_active` and `ar_pending`.

### Timelines

One client, `ar_ready` high, one-beat requests A, B, C back to back. Each
row shows what happens at that clock edge:

```text
edge          :  1    2    3    4    5
req accepted  :  A    B    C
held_request  :       A    B    C
AR transfer   :            A    B    C
```

`ar_ready` low while A is on the AR port; clients 1 and 2 then send X and Y:

```text
ar_active  : A    A    A    A  | X    Y          <- ar_ready goes high at |
ar_pending :      X    X    X  | -    -
held(2)    :           Y    Y  | Y    -
```

Waiting for credit (the request needs more than the client has left):

```text
edge       :  E        E+1          E+2
r_pop      :  1        0            0
req_ready  :  0        0            1      <- accepted at edge E+2
```

### Request-to-AR latency

For a request that is accepted and immediately granted, with
`ar_ready='1'`, the minimum request-to-AR handshake latency is **2 `aclk`
cycles**:

```text
Edge N   : req_valid & req_ready handshake; request enters held_request
Edge N+1 : held request is granted into ar_active; ar_valid becomes high
Edge N+2 : ar_valid & ar_ready handshake
```

A request may take longer if another client is granted first or if
`ar_ready='0'`. The fixed latency does not create a throughput bubble.

## Request Size Contract

A single request must fit the per-client credit budget: its beat count
(`req_len + 1`) must be at most `GC_FIFO_DEPTH`. Credits are capped at
`GC_FIFO_DEPTH` and only return via `r_pop`, so a request with
`req_len + 1 > GC_FIFO_DEPTH` can **never** be accepted - presenting one
deadlocks the client's channel. The RTL flags such a request at
presentation time (assert, severity `failure`):

```text
axi_ar_mux: request beats exceed GC_FIFO_DEPTH; it can never be accepted
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

### Pairing with axi_r_demux

```text
clients --req_*--> axi_ar_mux --ar_*--> memory --r_*--> axi_r_demux --rsp_*--> clients
                       ^                                     |
                       +---------------- r_pop --------------+
```

- Use the same `GC_NUM_CLIENTS`, `GC_ID_WIDTH` and `GC_FIFO_DEPTH` on both.
- Connect `axi_r_demux.r_pop` to `axi_ar_mux.r_pop` index for index. The
  demux pulses `r_pop(i)` once for every beat client *i* pops from its FIFO,
  from a register, so the path into this IP is register to register.
- A credit therefore means one free beat in that client's R-side FIFO, and
  the mux never lets a client have more beats in flight than its FIFO holds.

### Wider R side (axis_upsizer)

Credits are counted in **client beats** (`arlen + 1` is charged per
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

## Synthesis Results (measured, 4 clients)

Post place & route on **Artix-7 xc7a200tfbg676-1**, Vivado 2023.2, default
4-client config:

| Resource | Usage |
|----------|-------|
| Slice LUTs | **182** |
| Slice Registers | **268** |
| F7 / F8 Muxes | 0 |
| Block RAM / DSP | 0 |

### Timing

| Clock | Post-route WNS | Result |
|-------|----------------|--------|
| 200 MHz (5.0 ns) | **+0.436 ns** | All user specified timing constraints are met. |

The worst path is now inside one client's credit counter (`credits` ->
`credits`, 6 logic levels, 3.98 ns). Both possible next credit values are
computed from registers, and the handshake only selects between them. The
arbitration loop no longer contains any credit arithmetic.

For comparison, revision 1.01 (credit charged at grant) measured
**-1.566 ns at 7.0 ns** in the same flow, and did not meet 143 MHz.

The harness constrains `aclk` at 5.0 ns and false-paths all input and output
ports, so it measures register-to-register timing only. The combinational
paths `req_valid`/`req_len` -> `req_ready` and `ar_ready` -> AR state belong
to the integrating design's constraints. Only the default 4-client
configuration has been implemented. The implementation runs on the
larger `xc7a200tfbg676-1` package because the 4-client/32-bit wrapper has
~245 I/O ports, more than the 170 pins of `xc7a35tftg256-1`. Flow:
`synth_design -flatten_hierarchy rebuilt`, `opt_design`, `place_design
-directive ExtraPostPlacementOpt`, `phys_opt_design -directive
AggressiveExplore`, `route_design -directive Explore`. See
`fpga-rules/vivado_synthesis_guide.md` (Timing Closure & WNS Measurement).

To reproduce, run from an empty build directory:

```text
cd axi_ar_mux/.runs/vivado/implementation
vivado -mode batch -source ../../../scripts/axi_ar_mux_implementation.tcl
```

The script uses `scripts/axi_ar_mux_timing.xdc`, writes `reports/`, prints
`AXI_AR_MUX_POST_ROUTE_WNS_NS=<value>`, and exits with 1 if the routed
slack is negative.

## Reset

Synchronous active-low reset (`aresetn`) clears the holding registers, the
active and pending transactions, the delayed `r_pop` and the round-robin
pointer, and restores all credits to `GC_FIFO_DEPTH`. `req_ready` is
suppressed while reset is asserted.

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

`top/axi_ar_mux_top.vhd` / `top/axi_ar_mux_top.sv` provide a standalone
synthesis wrapper with the 4-client, 32-bit-address, 4-bit-ID, depth-32
defaults. The SV wrapper binds the VHDL array ports as packed arrays (client
index in the outer dimension) and explicitly reverses the packed outer
dimension so SV client index 0 maps to VHDL client index 0.

### Wrapper generics

The wrapper lets clients work in wider beats than the memory port. It adds:

| Generic | Default | Meaning |
|---------|---------|---------|
| `GC_CLIENT_DATA_WIDTH` | 512 | Client beat width, bits. |
| `GC_NATIVE_DATA_WIDTH` | 128 | Memory-side beat width, bits. |
| `GC_CLIENT_ARLEN_WIDTH` | 6 | Width of the client `req_len`. |
| `GC_NATIVE_ARLEN_WIDTH` | 8 | Width of the output `ar_len`. |
| `GC_BURST_TYPE` | `"01"` | Value driven on `ar_burst` (INCR). |

The output burst is scaled by the width ratio:

```text
ratio  = GC_CLIENT_DATA_WIDTH / GC_NATIVE_DATA_WIDTH
ar_len = (req_len + 1) * ratio - 1
```

For example, one 512-bit client beat on a 128-bit port becomes a 4-beat
native burst. `ar_size` is derived from `GC_NATIVE_DATA_WIDTH`. Credits stay
in **client** beats, so set `GC_R_BEATS_PER_POP` to match what one `r_pop`
returns on the R side. Elaboration assertions check that both widths are
powers of two in bytes, that their ratio is a power of two, and that
`GC_NATIVE_ARLEN_WIDTH` can hold the scaled burst.

## Running the Testbench

```text
run axi_ar_mux vhdl modelsim   # ModelSim batch (default target)
run axi_ar_mux vhdl vivado     # Vivado synthesis
run axi_ar_mux vhdl xsim       # XSim simulation
```

The Vivado flow synthesizes `top/axi_ar_mux_top.vhd`. Integration designs
must supply the clock and timing constraints for their target device.

The testbench (`tb/axi_ar_mux_tb.vhd`, 200 MHz clock) is organised as small
helpers (present, send, withdraw, pulse `r_pop`, expect refused, wait for
AR, stream), one procedure per test, and a main sequence that lists the
tests. Every test starts from a fresh reset, and burst sizes are written in
beats. The tests:

| Test | Checks |
|------|--------|
| `test_reset_state` | All `req_ready` high and `ar_valid` low after reset. |
| `test_first_request_line_rate` | A client is accepted on every clock straight after reset; AR payloads arrive in order. |
| `test_single_transaction` | Correct `ar_id`/`ar_addr`/`ar_len`; the holding register is free again afterwards. |
| `test_ar_stall` | With `ar_ready` low the AR payload does not change; a second client's grant waits in `ar_pending`, a third client waits in its holding register; all three transfer in order after release. |
| `test_credit_limit` | A request that does not fit is refused; one `r_pop` makes it fit and it is accepted; zero credit refuses even a one-beat request. |
| `test_pop_during_handshake` | An `r_pop` on the same clock as the AR transfer is not lost. |
| `test_refused_does_not_block` | A client refused for credit does not delay another client (needs 2+ clients). |
| `test_single_client_stream` | One client spends its whole budget at one request per clock, in order. |
| `test_all_clients_line_rate` | All clients stream: one AR per clock, round-robin order, two full rounds. |
| `test_exhausted_client` | After spending the whole budget, the next request is refused. |
| `test_reset_while_stalled` | Reset with a transaction stalled on AR; clean recovery and working traffic. |
| `test_pop_returns_ratio` | From zero credit, one `r_pop` pays for exactly `GC_R_BEATS_PER_POP` beats. |

A watchdog fails the run instead of letting a deadlock hang it. The
testbench ends with the banner:

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
