# axi_r_demux

AXI4 Read Data Channel demultiplexer: routes each incoming R beat to one
of `GC_NUM_CLIENTS` response interfaces selected by `r_id`. Each client
gets an elastic per-ID FIFO (the existing `axis_fifo`) plus a registered
read-data handshake, so a slow or stalled client never blocks another
client's response traffic.

The default configuration is **4 clients, 32-bit data, 4-bit ID, depth-32
FIFOs** and the design is built to sustain **250 MHz**.

## Overview

A single AXI R channel (interconnect -> this IP) fans out to many client
response interfaces. Beats are buffered in a per-client `axis_fifo`, so
traffic to one client is decoupled from the others: a client that stops
asserting `rsp_ready` absorbs beats in its FIFO without back-pressuring
the shared R channel until its FIFO (plus the one-beat skid) is full.

### When to use this

- You must demux a shared R channel into multiple per-client response
  interfaces (for example after a read-command `axi_ar_demux` / credit
  mux in front of independent slaves).
- Clients may be slow or bursty, and you want per-client elasticity so
  one slow client does not stall the others.

### When NOT to use this

- You only have a handful of in-flight transactions and want zero extra
  storage: a simple registered ID decode with backpressure would do.
- You need out-of-order response delivery: this IP preserves per-client
  FIFO order (the AXI R channel itself is in-order per ID).

## Generics

| Generic           | Range | Default | Description |
|-------------------|-------|---------|-------------|
| `GC_NUM_CLIENTS`  | `positive` | 4   | Number of demuxed client response interfaces. |
| `GC_DATA_BYTES`   | `positive` | 4   | Data width in bytes (4 = 32-bit R data). |
| `GC_ID_WIDTH`     | `positive` | 4   | R ID width; must satisfy `GC_ID_WIDTH >= ceil(log2(GC_NUM_CLIENTS))`. |
| `GC_FIFO_DEPTH`   | `positive >= 2` | 32 | Per-client FIFO depth (beats). |

## Ports

| Port        | Dir | Description |
|-------------|-----|-------------|
| `aclk`      | in  | Clock. |
| `aresetn`   | in  | Synchronous reset, active low. |
| `r_id`      | in  | AXI R ID selecting the target client, `GC_ID_WIDTH` bits. |
| `r_data`    | in  | AXI R data, `8*GC_DATA_BYTES` bits. |
| `r_resp`    | in  | AXI R response (2 bits), stored and forwarded per beat. |
| `r_last`    | in  | AXI R last, stored and forwarded per beat. |
| `r_valid`   | in  | Upstream has a valid R beat. |
| `r_ready`   | out | This demux accepts an R beat (registered). |
| `rsp_data`  | out | Per-client R data, array of `8*GC_DATA_BYTES`-bit vectors. |
| `rsp_resp`  | out | Per-client R response (2 bits each). |
| `rsp_last`  | out | Per-client R last. |
| `rsp_valid` | out | Per-client valid (beat available in that client's FIFO). |
| `rsp_ready` | in  | Per-client ready (that client pops its beat). |
| `r_pop`     | out | Per-client credit return pulses (registered, 1 cycle per popped beat). |

The `rsp_*` / `r_pop` ports are arrays indexed by client (`0 .. GC_NUM_CLIENTS-1`).

## How It Works

RTL follows the canonical **two-process method** from the fpga-rules
(`hdl_coding_rules.md`): a single state record (`rec_t`), a combinational
next-state/output process (`p_logic`), and a register process (`p_reg`).
The micro-architecture is:

1. **Registered `r_ready` + one-beat skid.** The input ready is a
   registered signal that depends only on the skid occupancy and the
   per-client FIFOs' registered `tf_ready` - never on `r_id`/`r_valid`.
   This removes the combinational input-to-output path. A beat is either
   written straight into its target FIFO (FIFO ready, skid idle or
   draining to a different client) or parked in the one-beat skid when its
  target FIFO is full. The one-hot `skid_dest` vector is also the skid
  occupancy flag (all zeroes means empty), avoiding a separate valid
  register and reducing both logic and timing cost. Because `r_ready` is
  only asserted when the skid will be empty next cycle, **no beat is ever
  lost or over-committed**.

2. **Per-client elastic buffers.** Each client instantiates the existing
   `axis_fifo` (see `sub/fpga-ip/axis_fifo`). The payload stored is
   `[ r_resp(2) | r_last(1) | r_data ]` - the data path is wide enough for
   the full `8*GC_DATA_BYTES` bits plus the 3 sideband bits.

3. **Unpacking + pop.** The FIFO master side unpacks the payload into
   `rsp_data`, `rsp_last`, and `rsp_resp`, which are combinational from
   the FIFO's registered output (stable while `rsp_valid` is asserted and
   `rsp_ready` is low).

4. **`r_pop` credit pulses.** A registered pulse per client is generated
   on every pop (`rsp_valid & rsp_ready`), returning the beat credit to
   the AR-side credit mux. Pulses are one cycle wide, including back to
   back.

If a client FIFO fills, the shared R channel is back-pressured through the
skid: at most one extra beat is accepted beyond `GC_FIFO_DEPTH`, and the
skid drains into the FIFO as soon as a slot frees, so the maximum in-flight
buffering per client is `GC_FIFO_DEPTH + 1` beats.

## AXI R Channel

The port naming follows the AXI read-data channel (`r_*`, matching
`rdata`/`rid`/`rresp`/`rlast` in `axi_protocol_reference.md`). `r_resp`
and `r_last` are stored with the beat and forwarded unchanged. An
out-of-range `r_id` is flagged with a `severity failure` in simulation
(and the beat is dropped in hardware so the R channel cannot deadlock).

## Synthesis Results (measured, 4 clients @ 250 MHz)

Standalone `run axi_r_demux vhdl vivado batch` on **Artix-7
xc7a35tftg256-1**, Vivado 2023.2, default 4 x 32-bit x depth-32 config:

| Resource | Usage |
|----------|-------|
| Slice LUTs | **431** (291 logic + 140 shift-register for the 4 FIFOs) |
| Slice Registers | **77** (skid + registered ready/pop control state) |
| F7 / F8 Muxes | 0 |
| Block RAM / DSP | 0 |
| WNS @ 250 MHz | **+0.122 ns** (4 ns period) |

The FIFO storage is SRL-based (`axis_fifo`), so the per-client elasticity
costs no block RAM and almost no flip-flops; the only FFs are the shared
skid, the registered input ready, and the `r_pop` credit registers. The
critical path is the registered skid-payload load control (3 logic levels).
The skid target is stored as a **registered one-hot vector**, so the FIFO
write path has no binary-to-one-hot decoder. The 250 MHz figure is verified by the
standalone Vivado flow, which applies the clock from
the configured clock and
reports `report_timing` / `report_utilization` into `.runs/vivado/timing.rpt`
and `.runs/vivado/utilization.rpt`. Re-run with `run clean axi_r_demux`
first to force a fresh build.

## Reset

Synchronous active-low reset (`aresetn`) clears the skid, the registered
`r_ready`, the `r_pop` pulses, and every per-client FIFO. All outputs are
low/zero after reset.

## Instantiation

The examples below use the default **4-client, 32-bit, 4-bit ID, depth-32**
configuration. The array ports (`rsp_*`, `r_pop`) use the shared package
types `slv_array_t` / `slv2_array_t` from `work.util_pkg`, so the
instantiating design must include `use work.util_pkg.all;` in VHDL.

### VHDL

```vhdl
use work.util_pkg.all;  -- slv_array_t, slv2_array_t

-- ---------------------------------------------------------------------
-- Signals (grouped by interface)
-- ---------------------------------------------------------------------
constant C_NUM_CLIENTS : positive := 4;   -- must match GC_NUM_CLIENTS
constant C_DATA_BITS   : positive := 32;  -- 8 * GC_DATA_BYTES

-- Clock / reset
signal aclk    : std_logic;
signal aresetn : std_logic;  -- synchronous, active low

-- AXI R channel (interconnect -> demux)
signal r_id    : std_logic_vector(3 downto 0);   -- target client ID
signal r_data  : std_logic_vector(31 downto 0);  -- rdata
signal r_resp  : std_logic_vector(1 downto 0);   -- rresp
signal r_last  : std_logic;                      -- rlast
signal r_valid : std_logic;
signal r_ready : std_logic;

-- Demuxed client response interfaces (array indexed 0..C_NUM_CLIENTS-1)
signal rsp_data  : slv_array_t(0 to C_NUM_CLIENTS-1)(C_DATA_BITS-1 downto 0);
signal rsp_resp  : slv2_array_t(0 to C_NUM_CLIENTS-1);
signal rsp_last  : std_logic_vector(0 to C_NUM_CLIENTS-1);
signal rsp_valid : std_logic_vector(0 to C_NUM_CLIENTS-1);
signal rsp_ready : std_logic_vector(0 to C_NUM_CLIENTS-1);
signal r_pop     : std_logic_vector(0 to C_NUM_CLIENTS-1);

-- ---------------------------------------------------------------------
-- Instantiation (grouped port map)
-- ---------------------------------------------------------------------
u_rdemux : entity work.axi_r_demux
  generic map (
    GC_NUM_CLIENTS => 4,  -- number of clients
    GC_DATA_BYTES  => 4,  -- data width in bytes
    GC_ID_WIDTH    => 4,  -- R ID width
    GC_FIFO_DEPTH  => 32  -- per-client FIFO depth (beats)
  )
  port map (
    -- Clock / reset
    aclk    => aclk,
    aresetn => aresetn,

    -- AXI R channel
    r_id    => r_id,
    r_data  => r_data,
    r_resp  => r_resp,
    r_last  => r_last,
    r_valid => r_valid,
    r_ready => r_ready,

    -- Demuxed client response interfaces
    rsp_data  => rsp_data,
    rsp_resp  => rsp_resp,
    rsp_last  => rsp_last,
    rsp_valid => rsp_valid,
    rsp_ready => rsp_ready,

    -- Credit return pulses
    r_pop => r_pop
  );
```

### SystemVerilog

```systemverilog
// ---------------------------------------------------------------------
// Signals (grouped by interface)
// ---------------------------------------------------------------------
localparam int unsigned C_NUM_CLIENTS = 4;   // must match GC_NUM_CLIENTS
localparam int unsigned C_DATA_BITS   = 32;  // 8 * GC_DATA_BYTES

// Clock / reset
logic aclk;
logic aresetn;  // synchronous, active low

// AXI R channel (interconnect -> demux)
logic [3:0]  r_id;     // target client ID
logic [31:0] r_data;   // rdata
logic [1:0]  r_resp;   // rresp
logic        r_last;   // rlast
logic        r_valid;
logic        r_ready;

// Demuxed client response interfaces (packed arrays, client index outer)
logic [C_NUM_CLIENTS-1:0][C_DATA_BITS-1:0] rsp_data;
logic [C_NUM_CLIENTS-1:0][1:0]             rsp_resp;
logic [C_NUM_CLIENTS-1:0]                  rsp_last;
logic [C_NUM_CLIENTS-1:0]                  rsp_valid;
logic [C_NUM_CLIENTS-1:0]                  rsp_ready;
logic [C_NUM_CLIENTS-1:0]                  r_pop;

// ---------------------------------------------------------------------
// Instantiation (grouped port map)
// ---------------------------------------------------------------------
axi_r_demux #(
    .GC_NUM_CLIENTS (4),  // number of clients
    .GC_DATA_BYTES  (4),  // data width in bytes
    .GC_ID_WIDTH    (4),  // R ID width
    .GC_FIFO_DEPTH  (32)  // per-client FIFO depth (beats)
) u_rdemux (
    // Clock / reset
    .aclk    (aclk),
    .aresetn (aresetn),

    // AXI R channel
    .r_id    (r_id),
    .r_data  (r_data),
    .r_resp  (r_resp),
    .r_last  (r_last),
    .r_valid (r_valid),
    .r_ready (r_ready),

    // Demuxed client response interfaces
    .rsp_data  (rsp_data),
    .rsp_resp  (rsp_resp),
    .rsp_last  (rsp_last),
    .rsp_valid (rsp_valid),
    .rsp_ready (rsp_ready),

    // Credit return pulses
    .r_pop (r_pop)
);
```

`rtl/axi_r_demux_top.vhd` / `rtl/axi_r_demux_top.sv` expose the same ports
with the 4-client, 32-bit, 4-bit-ID, depth-32 defaults, for use as a
standalone synthesis top. The SV wrapper binds the VHDL array ports as
packed arrays (client index in the outer dimension), matching the
`axilite_io` precedent.

## Running the Testbench

```text
run axi_r_demux vhdl modelsim   # ModelSim batch (default target)
run axi_r_demux vhdl vivado     # Vivado synthesis + 250 MHz timing check
run axi_r_demux vhdl xsim       # XSim simulation
```

The Vivado flow synthesizes `rtl/axi_r_demux_top.vhd` and applies
the configured clock (250 MHz), reporting WNS in
`.runs/vivado/timing.rpt` as a performance self-check. That constraint is
for the standalone flow only - integration designs supply their own clocks
and should not include the file.

The testbench (`tb/axi_r_demux_tb.vhd`, 250 MHz clock, generic
clients/width/ID/FIFO depth) verifies:

- **Reset:** all `rsp_valid` low, `r_ready` high, no `r_pop`.
- **Single-beat routing + unpacking:** data, `r_last`, and `r_resp` arrive
  intact at the target client, and `r_pop` pulses one cycle after the pop.
- **Interleaved multi-client routing:** beats to different clients are
  delivered to the correct client with per-client FIFO order preserved.
- **FIFO-full backpressure through the skid (the critical no-loss test):**
  a client FIFO is filled to depth and one beat beyond (into the skid);
  `r_ready` is verified to deassert; an extra upstream beat is verified NOT
  to be accepted; then the client is drained beat-by-beat and **all beats,
  including the one parked in the skid, arrive in order** - no loss.
- **Sideband stability:** the output (data/last/resp) stays stable while
  `rsp_valid` is high and `rsp_ready` is low.
- **Back-to-back full-rate streaming:** alternating clients at line rate
  with a back-to-back `r_pop` credit-pulse train.
- **Input line rate (hard guard):** with every client draining, the input
  streams 64 beats round-robin at one beat per clock and **`r_ready` is
  asserted to never drop** - the R channel must accept data on every beat
  at 250 MHz. A per-client `r_pop` counter then proves every accepted beat
  was popped exactly once (no loss).
- **Mid-stream reset:** `aresetn` pulses low while a beat is in flight;
  verifies clean recovery.
- A watchdog so a deadlock fails instead of hanging.

The testbench ends with the banner:

```text
** Note: ALL R-DEMUX CHECKS PASSED
```

Configurations are provided via `[tb:<name>]` manifest sections. The
`w*` configs sweep **2^N data widths** (8/16/32/64/128-bit); `small`
exercises the shallow-FIFO path, `c1`/`c2`/`c3` cover small client counts,
and `wide` stresses 8 clients:

| Config | Generics | Purpose |
|--------|----------|---------|
| `default` | 4 clients, 32-bit, depth 8 | Primary configuration. |
| `c1` | 1 client, 32-bit, ID width 1, depth 4 | Minimum client count (`axi_r_demux_small_tb`). |
| `c2` | 2 clients, 32-bit, ID width 1, depth 4 | Two-client routing (`axi_r_demux_small_tb`). |
| `c3` | 3 clients, 32-bit, ID width 2, depth 4 | Non-power-of-two client count (`axi_r_demux_small_tb`). |
| `w8`  | 4 clients, 8-bit,  depth 8 | 2^N width genericity. |
| `w16` | 4 clients, 16-bit, depth 8 | 2^N width genericity. |
| `w64` | 4 clients, 64-bit, depth 8 | 2^N width genericity. |
| `w128`| 4 clients, 128-bit, depth 8 | 2^N width genericity. |
| `small`| 4 clients, 32-bit, depth 4 | Shallow FIFO + skid corner. |
| `wide` | 8 clients, 64-bit, depth 8 | Many clients, wide data. |
