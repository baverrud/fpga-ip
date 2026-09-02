# axis_downsizer

AXI4-Stream width converter (downsizer): unpacks one wide beat of
`GC_M_TDATA_WIDTH * GC_RATIO` bits into `GC_RATIO` narrow beats of
`GC_M_TDATA_WIDTH` bits, **LSB-first** per AMBA AXI4-Stream (the first
narrow word comes from the low bits of the wide word).

The default configuration is **512 -> 128 bits (4:1)** and the design is
built to sustain **250 MHz** output line rate (one narrow beat per clock)
with very low logic usage.

## Overview

This is a high-Fmax width downsize: a wide **holding register** feeding a
**registered narrow output stage**. The wide bus is pure storage (no
combinational logic on it); a narrow slice-select mux feeds the output
stage, which runs at **full line rate** - one narrow beat per clock while
the input delivers one wide beat every `GC_RATIO` output cycles.

### When to use this

- You must narrow a stream (e.g. 512 -> 128) at high clock rate with
  minimal LUT usage.
- The input delivers whole wide beats (each wide beat becomes a complete
  group of narrow beats).

### When NOT to use this

- You need to preserve per-beat `tkeep`/`tstrb` byte enables through the
  conversion. This version packs by whole words and has no TKEEP/TSTRB.

## Generics

| Generic            | Range     | Default | Description |
|--------------------|-----------|---------|-------------|
| `GC_M_TDATA_WIDTH` | `positive` | 128     | Narrow (output) beat width in bits. |
| `GC_RATIO`         | `positive` | 4       | Downsize ratio; input width = `GC_M_TDATA_WIDTH * GC_RATIO`. |
| `GC_ID_WIDTH`      | `positive` | 4       | AXI R ID width (unused by the data path; passed through). |

## Ports

| Port           | Dir | Description |
|----------------|-----|-------------|
| `aclk`         | in  | Clock. |
| `aresetn`      | in  | Synchronous reset, active low. |
| `s_axis_tdata` | in  | Wide input beat (AXI R `rdata`), `GC_M_TDATA_WIDTH * GC_RATIO` bits. |
| `s_axis_tlast` | in  | Packet end on this wide beat; forwarded on its last narrow beat (AXI R `rlast`). |
| `s_axis_rresp` | in  | AXI R response per input beat; uniform across the group (2 bits). |
| `s_axis_rid`   | in  | AXI R ID, `GC_ID_WIDTH` bits; constant per burst. |
| `s_axis_tvalid`| in  | Upstream has a valid wide beat. |
| `s_axis_tready`| out | This converter accepts a wide beat (registered). |
| `m_axis_tdata` | out | Narrow output beat (registered). |
| `m_axis_tlast` | out | Packet end, asserted on the last slice of a tlast group. |
| `m_axis_rresp` | out | AXI R response, forwarded on every narrow beat of the group. |
| `m_axis_rid`   | out | AXI R ID, forwarded on every narrow beat of the group. |
| `m_axis_tvalid`| out | Valid narrow beat on `m_axis_tdata`. |
| `m_axis_tready`| in  | Downstream accepts the narrow beat. |

## How It Works

RTL follows the canonical **two-process method** from the fpga-rules
(`hdl_coding_rules.md`): a single state record (`rec_t`), a combinational
next-state/output process (`p_comb`), and a register process (`p_reg`). The
micro-architecture is:

1. **Input stage (`in_data` + `in_valid`).** One accepted wide beat is held
   in a `GC_M_TDATA_WIDTH * GC_RATIO`-bit register. Its `GC_RATIO` narrow
   slices are emitted LSB-first (slice 0 = low bits). The wide register is
   pure storage - no combinational logic on the wide bus.

2. **Output stage (`out_data`, `out_valid` + `slic`).** A small
   slice-select mux (`RATIO:1` on `GC_M_TDATA_WIDTH` bits) feeds the
   registered narrow output. Because the output stage always holds one
   complete narrow beat and is reloaded every drain cycle, the output runs
   at **full line rate** (one narrow beat per clock, back-to-back).

3. **Registered `s_axis_tready`.** The input accepts a new wide beat when
   the input stage is empty. `in_valid` is cleared as soon as the group's
   last slice is committed to the output stage, so the next wide beat is
   accepted exactly one output cycle before the previous group finishes
   draining - no output bubble, and no input-to-output combinational ready
   path.

If the downstream stalls, the output stage simply holds its current narrow
beat; the input backs up losslessly. A wide beat accepted at a group
boundary while the last slice is stalled is held in the input stage until
the output drains - no data is lost and nothing is over-committed.

`tlast` on the input wide beat is forwarded on the last narrow slice of
that group. Because every input beat is a whole group, packet ends are
inherently aligned.

## AXI R Channel

The core is AXI read-data channel compatible (see `tmp/new-ip/axi_r_demux.vhd`
for the surrounding R-channel convention): `tdata` maps to `rdata` and
`tlast` maps to `rlast`. Two side-band signals are carried through:

- **`rresp` (2 bits)** - one wide input beat represents a whole group of
  `GC_RATIO` narrow beats, so the input `rresp` is uniform across the group
  by construction. The RTL captures it with the wide beat and forwards it
  registered on **every** narrow output beat of the group.
- **`rid` (constant per burst)** - captured with the wide beat and
  forwarded on every narrow output beat of the group.

Both signals are **registered**, so the narrow output path stays clean at
250 MHz.

## Synthesis Results (measured, 512 -> 128 @ 250 MHz)

Standalone `run axis_downsizer vhdl vivado batch` on **Artix-7
xc7a35tftg256-1**, Vivado 2023.2, default 512 -> 128-bit (4:1) config:

| Resource | Usage |
|----------|-------|
| Slice LUTs | **411** (all logic, zero LUT-memory) |
| Slice Registers | **659** (512 wide hold + 128 output + 19 control/side-band) |
| F7 / F8 Muxes | 0 |
| Block RAM / DSP | 0 |
| WNS @ 250 MHz | **+0.539 ns** (4 ns period) |

**Register breakdown** (why 659):

| Block | Bits | Purpose |
|-------|------|---------|
| `in_data` | 512 | wide input holding register (pure storage) |
| `out_data` | 128 | registered narrow output stage |
| `slic` | 2 | output slice index (0..GC_RATIO-1) |
| `in_valid` / `s_ready` | 2 | input stage occupancy + registered ready |
| `in_tlast` / `out_tlast` | 2 | group/beat tlast |
| `in_rresp` / `out_rresp` | 4 | AXI R response capture + forward |
| `in_rid` / `out_rid` | 8 | AXI R ID capture + forward |
| `out_valid` | 1 | output stage valid |

The wide payload costs one full-width holding register; the output is one
narrow register. The LUT cost is the RATIO:1 slice-select mux on the narrow
output width (the unavoidable cost of selecting which slice to emit). The
critical path is `slic -> out_data` (3 logic levels, ~3.3 ns), which is why
the output sustains 250 MHz on the smallest Artix-7 part with ~0.5 ns of
margin. Scaling to a larger part (for example a ZCU104-class device) or a
faster speed grade increases the margin.

The 250 MHz figure is verified by the standalone Vivado flow, which
applies the configured clock
(`create_clock -period 4.000` on `aclk`) and reports
`report_timing` / `report_utilization` into `.runs/vivado/timing.rpt` and
`.runs/vivado/utilization.rpt`. Re-run with `run clean axis_downsizer`
first to force a fresh build.

## Reset

Synchronous active-low reset (`aresetn`) clears all state, including the
input holding register, the output stage, and the registered input ready.
Payload registers are reset to zero for clean simulation.

## Instantiation

The examples below use the default **512 -> 128-bit (4:1)** configuration
with a 4-bit AXI R ID. Widths follow directly from the generics:
`GC_M_TDATA_WIDTH * GC_RATIO` for the input, `GC_M_TDATA_WIDTH` for the
output, and `GC_ID_WIDTH` for the ID sidebands.

### VHDL

```vhdl
-- ---------------------------------------------------------------------
-- Signals (grouped by interface)
-- ---------------------------------------------------------------------

-- Clock / reset
signal aclk    : std_logic;
signal aresetn : std_logic;  -- synchronous, active low

-- Slave interface: wide input, AXI R channel (rdata/rlast/rresp/rid)
signal s_axis_tdata  : std_logic_vector(511 downto 0);  -- rdata (wide)
signal s_axis_tlast  : std_logic;                       -- rlast (packet end)
signal s_axis_rresp  : std_logic_vector(1 downto 0);    -- rresp (per group)
signal s_axis_rid    : std_logic_vector(3 downto 0);    -- rid (per burst)
signal s_axis_tvalid : std_logic;                       -- input valid
signal s_axis_tready : std_logic;                       -- input ready

-- Master interface: narrow output, AXI R channel
signal m_axis_tdata  : std_logic_vector(127 downto 0);  -- rdata (narrow)
signal m_axis_tlast  : std_logic;                       -- rlast (packet end)
signal m_axis_rresp  : std_logic_vector(1 downto 0);    -- rresp (per beat)
signal m_axis_rid    : std_logic_vector(3 downto 0);    -- rid (per burst)
signal m_axis_tvalid : std_logic;                       -- output valid
signal m_axis_tready : std_logic;                       -- output ready

-- ---------------------------------------------------------------------
-- Instantiation (grouped port map)
-- ---------------------------------------------------------------------
u_downsize : entity work.axis_downsizer
  generic map (
    GC_M_TDATA_WIDTH => 128,  -- narrow output width (bits)
    GC_RATIO         => 4,    -- downsize ratio (input = 128 * 4)
    GC_ID_WIDTH      => 4     -- AXI R ID width (bits)
  )
  port map (
    -- Clock / reset
    aclk    => aclk,
    aresetn => aresetn,

    -- Slave interface (wide input)
    s_axis_tdata  => s_axis_tdata,   -- rdata
    s_axis_tlast  => s_axis_tlast,   -- rlast
    s_axis_rresp  => s_axis_rresp,   -- rresp (uniform per group)
    s_axis_rid    => s_axis_rid,     -- rid
    s_axis_tvalid => s_axis_tvalid,
    s_axis_tready => s_axis_tready,

    -- Master interface (narrow output)
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

// Slave interface: wide input, AXI R channel (rdata/rlast/rresp/rid)
logic [511:0] s_axis_tdata;   // rdata (wide)
logic         s_axis_tlast;   // rlast (packet end)
logic [1:0]   s_axis_rresp;   // rresp (per group)
logic [3:0]   s_axis_rid;     // rid (per burst)
logic         s_axis_tvalid;  // input valid
logic         s_axis_tready;  // input ready

// Master interface: narrow output, AXI R channel
logic [127:0] m_axis_tdata;   // rdata (narrow)
logic         m_axis_tlast;   // rlast (packet end)
logic [1:0]   m_axis_rresp;   // rresp (per beat)
logic [3:0]   m_axis_rid;     // rid (per burst)
logic         m_axis_tvalid;  // output valid
logic         m_axis_tready;  // output ready

// ---------------------------------------------------------------------
// Instantiation (grouped port map)
// ---------------------------------------------------------------------
axis_downsizer #(
    .GC_M_TDATA_WIDTH (128),  // narrow output width (bits)
    .GC_RATIO         (4),    // downsize ratio (input = 128 * 4)
    .GC_ID_WIDTH      (4)     // AXI R ID width (bits)
) u_downsize (
    // Clock / reset
    .aclk    (aclk),
    .aresetn (aresetn),

    // Slave interface (wide input)
    .s_axis_tdata  (s_axis_tdata),   // rdata
    .s_axis_tlast  (s_axis_tlast),   // rlast
    .s_axis_rresp  (s_axis_rresp),   // rresp (uniform per group)
    .s_axis_rid    (s_axis_rid),     // rid
    .s_axis_tvalid (s_axis_tvalid),
    .s_axis_tready (s_axis_tready),

    // Master interface (narrow output)
    .m_axis_tdata  (m_axis_tdata),   // rdata
    .m_axis_tlast  (m_axis_tlast),   // rlast
    .m_axis_rresp  (m_axis_rresp),   // rresp
    .m_axis_rid    (m_axis_rid),     // rid
    .m_axis_tvalid (m_axis_tvalid),
    .m_axis_tready (m_axis_tready)
);
```

`rtl/axis_downsizer_top.vhd` / `rtl/axis_downsizer_top.sv` expose the same
ports with the 512 -> 128 defaults, for use as a standalone synthesis top.
Both wrappers are updated in lockstep with the core (including the
`GC_ID_WIDTH` generic and the `rresp`/`rid` ports).

## Running the Testbench

```text
run axis_downsizer vhdl modelsim   # ModelSim batch (default target)
run axis_downsizer vhdl vivado     # Vivado synthesis + 250 MHz timing check
run axis_downsizer vhdl xsim       # XSim simulation
```

The Vivado flow synthesizes `rtl/axis_downsizer_top.vhd` and applies
the configured clock (250 MHz), reporting WNS in
`.runs/vivado/timing.rpt` as a performance self-check. That constraint is
for the standalone flow only - integration designs supply their own clocks
and should not include the file.

The testbench (`tb/axis_downsizer_tb.vhd`, 250 MHz clock, generic
width/ratio) verifies:

- **Phase A (output line rate):** continuous wide beats in, back-to-back
  narrow beats out; every narrow beat checked against the LSB-first
  unpacking. A **hard assertion** fails the run on any output bubble (a
  bandwidth regression guard on the fast output side).
- **Phase B:** destination backpressure (ready 3 of 4) - order and
  integrity preserved.
- **Phase C:** source `tvalid` gaps (1 cycle in 4) - no loss.
- **Phase D (combined stress):** source gaps AND destination burst
  backpressure simultaneously. The destination drops ready for 10 cycles
  after every even output group, holding output beats through a multi-cycle
  stall and backing up the whole pipeline.
- **Phase E (mid-stream reset):** `aresetn` pulses low while data is in
  flight; verifies clean recovery and a correct post-reset stream.
- `tlast` alignment on every 2-group packet (exercised on both tlast=0
  and tlast=1 output beats).
- **AXI R channel:** `rid` and `rresp` (uniform per group) verified on
  every narrow output beat.
- Output and input payload/sidebands are checked for stability during
  backpressure.
- A watchdog so a deadlock fails instead of hanging.

Seven configurations are provided via `[tb:<name>]` manifest sections:

| Config | Generics | Purpose |
|--------|----------|---------|
| `default` | 512 -> 128, ratio 4 | Primary configuration. |
| `narrow` | 32 -> 8, ratio 4 | Narrow data genericity. |
| `x2` | 256 -> 128, ratio 2 | Smaller ratio genericity. |
| `pass` | 128 -> 128, ratio 1 | Pass-through ratio and 1-bit ID. |
| `x3` | 384 -> 128, ratio 3 | Non-power-of-two ratio. |
| `x8` | 1024 -> 128, ratio 8 | Larger ratio and 6-bit ID. |
| `small` | 8 -> 4, ratio 2 | Data width below one byte. |

Run a specific one with `--tb <name>` (e.g. `run axis_downsizer vhdl modelsim --tb narrow`).

On success the transcript ends with:

```text
ALL DOWNSIZER CHECKS PASSED
```
