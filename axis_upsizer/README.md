# axis_upsizer

AXI4-Stream width converter (upsizer): packs `GC_RATIO` narrow beats of
`GC_S_TDATA_WIDTH` bits into one wide beat of
`GC_S_TDATA_WIDTH * GC_RATIO` bits, **LSB-first** per AMBA AXI4-Stream
(the first narrow word occupies the low bits of the wide word).

The default configuration is **128 -> 512 bits (4:1)** and the design is
built to sustain **250 MHz** with very low logic usage.

## Overview

This is a high-Fmax width upsize: a pure **shift-register accumulator**
feeding a **registered output stage**, with one narrow-beat skid register
for ready-path isolation. A narrow beat is accepted every cycle while the
output is flowing; after `GC_RATIO` beats the wide word is presented on the
master interface. There is **no RAM and no combinational logic on the wide
data path** - the accumulator is built entirely from register concatenation.

### When to use this

- You must widen a stream (e.g. 128 -> 512) at high clock rate with
  minimal LUT usage.
- Packet lengths are a multiple of the ratio (no partial output words).

### When NOT to use this

- Packets can end mid-group (not ratio-aligned). This version assumes
  alignment and does not implement TKEEP/TSTRB to mask partial words; a
  TKEEP-capable converter would be needed for that case.

## Generics

| Generic            | Range     | Default | Description |
|--------------------|-----------|---------|-------------|
| `GC_S_TDATA_WIDTH` | `positive` | 128     | Narrow (input) beat width in bits. |
| `GC_RATIO`         | `positive` | 4       | Upsize ratio; output width = `GC_S_TDATA_WIDTH * GC_RATIO`. |
| `GC_ID_WIDTH`      | `positive` | 4       | AXI R ID width (unused by the data path; passed through). |

## Ports

| Port           | Dir | Description |
|----------------|-----|-------------|
| `aclk`         | in  | Clock. |
| `aresetn`      | in  | Synchronous reset, active low. |
| `s_axis_tdata` | in  | Narrow input beat (AXI R `rdata`). |
| `s_axis_tlast` | in  | Packet end (must be ratio-aligned; AXI R `rlast`). |
| `s_axis_rresp` | in  | AXI R response per input beat; responses must be uniform within each packed group. |
| `s_axis_rid`   | in  | AXI R ID, `GC_ID_WIDTH` bits; constant per burst. |
| `s_axis_tvalid`| in  | Upstream has a valid narrow beat. |
| `s_axis_tready`| out | This converter accepts a narrow beat. |
| `m_axis_tdata` | out | Wide output beat (registered). |
| `m_axis_tlast` | out | Packet end, forwarded from the group (AXI R `rlast`). |
| `m_axis_rresp` | out | AXI R response, forwarded with the matching output beat. |
| `m_axis_rid`   | out | AXI R ID, forwarded with every output beat. |
| `m_axis_tvalid`| out | Valid wide beat on `m_axis_tdata`. |
| `m_axis_tready`| in  | Downstream accepts the wide beat. |

## How It Works

RTL follows the canonical **two-process method** from the fpga-rules
(`hdl_coding_rules.md`): a single state record (`rec_t`), a combinational
next-state/output process (`p_comb`), and a register process (`p_reg`). The
micro-architecture is a two-stage accumulator:

1. **Accumulator (`acc` + `cnt`).** Each accepted narrow beat enters
   at the MSB of a `GC_S_TDATA_WIDTH * GC_RATIO`-bit register and shifts
   the existing content down:
   ```
   acc <= new_beat & acc(M-1 downto GC_S_TDATA_WIDTH)
   ```
   After `GC_RATIO` beats, `acc = [beat R-1 | ... | beat 1 | beat 0]`
   with the **first** beat in the low bits (LSB-first packing). This
   shift is pure wiring - no muxes, no logic on the data path.

2. **Output stage (`out_data`, `out_valid`).** When the accumulator is
   full and the output stage is free, the wide word is copied into the
   registered output (`m_axis_tdata`, `m_axis_tvalid`). The output is
   always registered, so the wide path meets high clock rates easily.

3. **One-beat skid (`skid_*`, `skid_valid`).** If the accumulator and
  output stage are full when downstream backpressure arrives, one accepted
  narrow beat is held in the skid register. This permits `s_axis_tready`
  to be fully registered and removes the `m_axis_tready -> s_axis_tready`
  combinational path without inserting bubbles while the output flows.

Performance remains a first-class constraint: the accumulator, output
stage, and skid register sustain one accepted narrow beat per clock while
the destination is flowing. The ready output itself is registered to
follow the project AXI rule that interface outputs must not depend
combinationally on input ports.

The transfer and the next input beat can occur in the **same cycle**, so
the input runs at **full line rate** (one narrow beat per clock) while the
output produces one wide beat every `GC_RATIO` clocks. If the master
stalls, `s_axis_tready` deasserts only once the accumulator is full -
backpressure is clean and lossless.

`tlast` is OR'd across the group and forwarded on the matching output
beat. The RTL asserts if an accepted `tlast` is not ratio-aligned.

## AXI R Channel

The core is AXI read-data channel compatible (see `tmp/new-ip/axi_r_demux.vhd`
for the surrounding R-channel convention): `tdata` maps to `rdata` and
`tlast` maps to `rlast`. Two side-band signals are carried through:

- **`rresp` (2 bits)** - AXI carries a response on every R-channel beat.
  A single wide output beat represents `GC_RATIO` narrow beats, so this
  core requires the input response to be uniform across each packed group.
  The RTL captures the first response, checks every later response in the
  group, and forwards the response on every output beat. A mismatch is a
  simulation assertion failure because one output beat cannot preserve
  multiple independent responses.
- **`rid` (constant per burst)** - the ID is identical for every beat of a
  burst, so the core samples `s_axis_rid` on every accepted beat and
  forwards the captured value with every output beat.

Both signals are **registered** so the wide output path stays clean at
250 MHz. `rid` must also remain constant within each packed group and is
checked by the RTL.

Because packet ends must be ratio-aligned, a read burst must be a whole
number of output words (`GC_RATIO` beats); a burst that ends mid-group is
not supported (no partial-word TKEEP masking).

## Synthesis Results (measured, 128 -> 512 @ 250 MHz)

Standalone `run axis_upsizer vhdl vivado batch` on **Artix-7
xc7a35tftg256-1**, Vivado 2023.2, default 128 -> 512-bit (4:1) config:

| Resource | Usage |
|----------|-------|
| Slice LUTs | **148** (all logic, zero LUT-memory) |
| Slice Registers | **1179** (1024 payload + 155 control/side-band/skid) |
| F7 / F8 Muxes | 0 |
| Block RAM / DSP | 0 |
| WNS @ 250 MHz | **+0.703 ns** (4 ns period) |

**Register breakdown** (why 1179):

| Block | Bits | Purpose |
|-------|------|---------|
| `acc` | 512 | group under assembly (shift register) |
| `out_data` | 512 | registered output stage (holds one wide beat) |
| `cnt` | 3 | accumulator fill count (0..GC_RATIO) |
| `tlast_acc` / `out_tlast` | 2 | group/beat tlast |
| `rresp_acc` / `out_rresp` | 4 | AXI R response capture + forward |
| `rid_acc` / `out_rid` | 8 | AXI R ID capture + forward |
| `out_valid` | 1 | output stage valid |
| `skid_data` | 128 | one-beat ready-path isolation buffer |
| `skid_tlast` / `skid_rresp` / `skid_rid` / `skid_valid` | 8 | skid sidebands and valid |
| `s_ready` | 1 | registered input ready |

The wide payload costs only flip-flops (two full-width registers, one for
the accumulator and one for the output stage). The additional skid buffer
costs one narrow input-width register plus sideband bits and isolates the
ready path. The critical path remains the `cnt -> acc` accumulator enable
(2 logic levels, ~2.9 ns), so the core sustains 250 MHz on the smallest
Artix-7 part with ~0.7 ns of margin. Scaling to a larger part (for example
a ZCU104-class device) or a faster speed grade increases the margin.

The 250 MHz figure is verified by the standalone Vivado flow, which
applies the configured clock
(`create_clock -period 4.000` on `aclk`) and reports
`report_timing` / `report_utilization` into `.runs/vivado/timing.rpt` and
`.runs/vivado/utilization.rpt`. Re-run with `run clean axis_upsizer` first
to force a fresh build.

## Reset

Synchronous active-low reset (`aresetn`) clears all state, including the
skid register and registered input ready. Payload registers are reset to
zero for clean simulation; because the data is gated by `tvalid`/`cnt`,
this reset cost is negligible at these widths.

## Instantiation

### VHDL

The example uses the default **128 -> 512-bit (4:1)** configuration with a
4-bit AXI R ID. Output width follows from the generics
(`GC_S_TDATA_WIDTH * GC_RATIO`).

```vhdl
-- ---------------------------------------------------------------------
-- Signals (grouped by interface)
-- ---------------------------------------------------------------------

-- Clock / reset
signal aclk    : std_logic;
signal aresetn : std_logic;  -- synchronous, active low

-- Slave interface: narrow input, AXI R channel (rdata/rlast/rresp/rid)
signal s_axis_tdata  : std_logic_vector(127 downto 0);  -- rdata (narrow)
signal s_axis_tlast  : std_logic;                       -- rlast (packet end)
signal s_axis_rresp  : std_logic_vector(1 downto 0);    -- rresp (per beat)
signal s_axis_rid    : std_logic_vector(3 downto 0);    -- rid (per burst)
signal s_axis_tvalid : std_logic;                       -- input valid
signal s_axis_tready : std_logic;                       -- input ready

-- Master interface: wide output, AXI R channel
signal m_axis_tdata  : std_logic_vector(511 downto 0);  -- rdata (wide)
signal m_axis_tlast  : std_logic;                       -- rlast (packet end)
signal m_axis_rresp  : std_logic_vector(1 downto 0);    -- rresp (per beat)
signal m_axis_rid    : std_logic_vector(3 downto 0);    -- rid (per burst)
signal m_axis_tvalid : std_logic;                       -- output valid
signal m_axis_tready : std_logic;                       -- output ready

-- ---------------------------------------------------------------------
-- Instantiation (grouped port map)
-- ---------------------------------------------------------------------
u_upsize : entity work.axis_upsizer
  generic map (
    GC_S_TDATA_WIDTH => 128,  -- narrow input width (bits)
    GC_RATIO         => 4,    -- upsize ratio (output = 128 * 4)
    GC_ID_WIDTH      => 4     -- AXI R ID width (bits)
  )
  port map (
    -- Clock / reset
    aclk    => aclk,
    aresetn => aresetn,

    -- Slave interface (narrow input)
    s_axis_tdata  => s_axis_tdata,   -- rdata
    s_axis_tlast  => s_axis_tlast,   -- rlast
    s_axis_rresp  => s_axis_rresp,   -- rresp (uniform per group)
    s_axis_rid    => s_axis_rid,     -- rid
    s_axis_tvalid => s_axis_tvalid,
    s_axis_tready => s_axis_tready,

    -- Master interface (wide output)
    m_axis_tdata  => m_axis_tdata,   -- rdata
    m_axis_tlast  => m_axis_tlast,   -- rlast
    m_axis_rresp  => m_axis_rresp,   -- rresp
    m_axis_rid    => m_axis_rid,     -- rid
    m_axis_tvalid => m_axis_tvalid,
    m_axis_tready => m_axis_tready
  );
```

### SystemVerilog

```systemverilog
// ---------------------------------------------------------------------
// Signals (grouped by interface)
// ---------------------------------------------------------------------

// Clock / reset
logic aclk;
logic aresetn;  // synchronous, active low

// Slave interface: narrow input, AXI R channel (rdata/rlast/rresp/rid)
logic [127:0] s_axis_tdata;   // rdata (narrow)
logic         s_axis_tlast;   // rlast (packet end)
logic [1:0]   s_axis_rresp;   // rresp (per beat)
logic [3:0]   s_axis_rid;     // rid (per burst)
logic         s_axis_tvalid;  // input valid
logic         s_axis_tready;  // input ready

// Master interface: wide output, AXI R channel
logic [511:0] m_axis_tdata;   // rdata (wide)
logic         m_axis_tlast;   // rlast (packet end)
logic [1:0]   m_axis_rresp;   // rresp (per beat)
logic [3:0]   m_axis_rid;     // rid (per burst)
logic         m_axis_tvalid;  // output valid
logic         m_axis_tready;  // output ready

// ---------------------------------------------------------------------
// Instantiation (grouped port map)
// ---------------------------------------------------------------------
axis_upsizer #(
    .GC_S_TDATA_WIDTH (128),  // narrow input width (bits)
    .GC_RATIO         (4),    // upsize ratio (output = 128 * 4)
    .GC_ID_WIDTH      (4)     // AXI R ID width (bits)
) u_upsize (
    // Clock / reset
    .aclk    (aclk),
    .aresetn (aresetn),

    // Slave interface (narrow input)
    .s_axis_tdata  (s_axis_tdata),   // rdata
    .s_axis_tlast  (s_axis_tlast),   // rlast
    .s_axis_rresp  (s_axis_rresp),   // rresp (uniform per group)
    .s_axis_rid    (s_axis_rid),     // rid
    .s_axis_tvalid (s_axis_tvalid),
    .s_axis_tready (s_axis_tready),

    // Master interface (wide output)
    .m_axis_tdata  (m_axis_tdata),   // rdata
    .m_axis_tlast  (m_axis_tlast),   // rlast
    .m_axis_rresp  (m_axis_rresp),   // rresp
    .m_axis_rid    (m_axis_rid),     // rid
    .m_axis_tvalid (m_axis_tvalid),
    .m_axis_tready (m_axis_tready)
);
```

`top/axis_upsizer_top.vhd` / `top/axis_upsizer_top.sv` expose the same
ports with the 128 -> 512 defaults, for use as a standalone synthesis top.
Both wrappers are updated in lockstep with the core (including the
`GC_ID_WIDTH` generic and the `rresp`/`rid` ports).

## Running the Testbench

```text
run axis_upsizer vhdl modelsim     # ModelSim batch (default target)
run axis_upsizer vhdl vivado       # Vivado synthesis + 250 MHz timing check
run axis_upsizer vhdl xsim         # XSim simulation
```

The Vivado flow synthesizes `top/axis_upsizer_top.vhd` and applies
the configured clock (250 MHz), reporting WNS in
`.runs/vivado/timing.rpt` as a performance self-check. That constraint is
for the standalone flow only - integration designs supply their own clocks
and should not include the file.

The testbench (`tb/axis_upsizer_tb.vhd`, 250 MHz clock, generic
width/ratio) verifies:

- **Phase A (line rate):** continuous narrow beats in, continuous wide
  beats out; every wide beat checked against the LSB-first packing. A
  **hard assertion** fails the run if the input is not sustained at full
  line rate (any bubble is a bandwidth regression).
- **Phase B:** destination backpressure (ready 3 of 4) - order and
  integrity preserved.
- **Phase C:** source `tvalid` gaps (1 cycle in 4) - no loss.
- **Phase D (combined stress):** source gaps AND destination burst
  backpressure simultaneously. The destination drops ready for 10 cycles
  after every even output group, which (a) holds each `tlast`/`rresp` beat
  through a multi-cycle stall (packet-boundary stall) and (b) backs up
  both pipeline stages so the release forces drain+transfer+accept in one
  cycle.
- **Phase E (mid-stream reset):** `aresetn` pulses low while data is in
  flight; verifies clean recovery and a correct post-reset stream.
- `tlast` alignment on every 2-group packet (exercised on both tlast=0
  and tlast=1 output beats).
- **AXI R channel:** `rid` and `rresp` are verified on every output beat;
  the TB drives and checks a uniform response across each packed group.
- Output and input payload/sidebands are checked for stability during
  backpressure.
- Reset is applied while the output stage, accumulator, and skid register
  are occupied and the destination is stalled.
- Ratio alignment is enforced by the RTL assertion and all TB phase counts
  are derived from `GC_RATIO`.
- A watchdog so a deadlock fails instead of hanging.

Seven configurations are provided via `[tb:<name>]` manifest sections:

| Config | Generics | Purpose |
|--------|----------|---------|
| `default` | 128 -> 512, ratio 4 | Primary configuration. |
| `narrow` | 8 -> 32, ratio 4 | Narrow data genericity. |
| `x2` | 128 -> 256, ratio 2 | Smaller ratio genericity. |
| `pass` | 128 -> 128, ratio 1 | Pass-through ratio and 1-bit ID. |
| `x3` | 128 -> 384, ratio 3 | Non-power-of-two ratio. |
| `x8` | 128 -> 1024, ratio 8 | Larger ratio and 6-bit ID. |
| `small` | 4 -> 8, ratio 2 | Data width below one byte. |

Run a specific one with `--tb <name>` (e.g. `run axis_upsizer vhdl modelsim --tb narrow`).

On success the transcript ends with:

```text
ALL UPSIZER CHECKS PASSED
```
