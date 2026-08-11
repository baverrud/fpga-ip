# axis_cdc

AXI4-Stream clock-domain converter (CDC) using a Gray-pointer asynchronous
FIFO core.

Transfers an AXI4-Stream from the source clock domain (`s_axis_aclk`) to
the destination clock domain (`m_axis_aclk`) with **line-rate throughput**
(one word per clock on each side) regardless of the clock relationship
between the domains. The internal buffer is small and configurable.

## Overview

This is the industry-standard high-performance CDC: a dual-port RAM whose
write port runs on the source clock and whose read port runs on the
destination clock. Only the **Gray-coded pointers** cross the boundary,
each re-timed through a 2..4 flip-flop synchronizer chain. Because the
pointers are the only cross-domain signals and they are safe by
construction (Gray code changes one bit per increment), the data plane is
fully decoupled and runs at line rate in both domains.

The FIFO depth is a power-of-two generic (`GC_CDC_DEPTH`, default 8).
Pick the smallest depth that covers your throughput and burst needs. The
first-word fall-through (combinational) read requires a distributed-RAM
(LUTRAM) implementation at any depth, so a large depth is expensive in
LUTs; keep it small.

### When to use this

- You need to cross a data stream between unrelated clocks at high rate.
- The source or destination runs at line rate (valid/ready, no bubbles).
- The clocks may have any relationship: faster source, faster
  destination, equal, or fully asynchronous.

### When NOT to use this

- You need to cross only a rare control/status word and want to avoid
  even a few words of RAM: a FIFO-less handshake CDC would use less
  logic, at the cost of very low throughput.
- You cannot afford the fill/drain latency of a few sync cycles (rare).

## Block Diagram

```
              source domain (s_axis_aclk)          destination domain (m_axis_aclk)
              +------------------------------+     +-------------------------------+
s_axis_tdata->| write port          dual-port|     |          read port  FWFT      |-> m_axis_tdata
s_axis_tvalid->| write ptr (bin+gray)   RAM  |     |  read ptr (bin+gray)  (comb)  |-> m_axis_tvalid
s_axis_tready<-| tready = not full       |   |     |  tvalid = not empty            |
              |  rptr gray sync chain <--|---+     +---|--> wptr gray sync chain    |
              +------------------------------+         +-------------------------------+
```

Only the Gray pointers cross the boundary (read pointer into the write
domain, write pointer into the read domain), each through a synchronizer
chain. Data crosses through the dual-port RAM itself.

## Generics

| Generic          | Range          | Default | Description |
|------------------|----------------|---------|-------------|
| `GC_TDATA_WIDTH` | `positive`     | 32      | Width of the AXI-Stream payload word. |
| `GC_CDC_DEPTH`   | `2 to 1024`    | 8       | FIFO depth (must be a power of two). The FWFT combinational read always infers distributed RAM, so keep it small. |
| `GC_SYNC_STAGES` | `2 to 4`       | 2       | Flip-flops per pointer synchronizer chain. More stages raise MTBF at the cost of a few cycles of fill/drain latency. |

## Ports

### Source domain (clocked by `s_axis_aclk`)

| Port              | Dir | Description |
|-------------------|-----|-------------|
| `s_axis_aclk`     | in  | Source clock. |
| `aresetn`         | in  | Shared reset, asynchronous assertion and synchronous de-assertion in each clock domain, active low. |
| `s_axis_tdata`    | in  | Payload word to cross. |
| `s_axis_tvalid`   | in  | Upstream has a valid word. |
| `s_axis_tready`   | out | This CDC is ready to accept a word. |

### Destination domain (clocked by `m_axis_aclk`)

| Port              | Dir | Description |
|-------------------|-----|-------------|
| `m_axis_aclk`     | in  | Destination clock. |
| `m_axis_tdata`    | out | Crossed payload word (FWFT combinational read). |
| `m_axis_tvalid`   | out | Valid crossed word on `m_axis_tdata`. |
| `m_axis_tready`   | in  | Downstream consumer accepts the word. |

## How It Works (Gray-pointer asynchronous FIFO)

The module is a textbook asynchronous FIFO. Every word crosses via four
mechanisms:

1. **Storage.** A dual-port RAM. `p_mem_w` writes on `s_axis_aclk` at the
   write address; the read side reads combinationally on `m_axis_aclk` at
   the read address. Data is written in one domain and read in the other,
   so it is never "held" or sampled across the boundary.

2. **Pointers.** Each domain keeps a binary pointer plus a Gray-encoded
   copy. The pointers are one bit wider than the address: the extra (wrap)
   bit is what distinguishes a full FIFO from an empty one. Gray encoding
   guarantees only one bit changes per increment, so a pointer sampled in
   the other domain is always an old or adjacent value - never a corrupted
   combination.

3. **Synchronizers.** Each Gray pointer is re-timed into the other domain
   through `GC_SYNC_STAGES` flip-flops (`p_sync_rptr`, `p_sync_wptr`),
   marked `ASYNC_REG`. The synchronized pointers drive the flags.

4. **Flags (conservative by design).**
   - `s_axis_tready` uses the current full check against the synchronized
     read pointer. Because that pointer lags reality, backpressure can
     assert early after a remote read, but the source never writes beyond
     the FIFO capacity.
   - `m_axis_tvalid` is the **not-empty** check against the synchronized
     write pointer. Because that pointer lags, empty asserts late - the
     sink waits a few cycles while words are already in flight, so
     underflow is impossible.

### Why this is safe

- **No multi-bit bus is ever sampled while changing.** Data goes through
  the dual-port RAM; only the Gray pointers cross, and they change one
  bit at a time.
- **Only Gray-coded pointers cross the boundary.** A metastable capture
  of a Gray bit resolves to 0 or 1 and the pointer value remains a valid
  (possibly stale) Gray value.
- **Conservative flags** make overflow and underflow structurally
  impossible, at the cost of a few cycles of latency.
- **First-Word Fall-Through (FWFT).** The output is a combinational read,
  so the read side has minimum latency and full line rate.

## CDC Safety Analysis

### Metastability

The only metastability risk is in the first flip-flop of each pointer
synchronizer chain (`rptr_gray_sync_chain(0)` and
`wptr_gray_sync_chain(0)`), which sample asynchronous pointer bits. Each
chain gives that flip-flop `GC_SYNC_STAGES - 1` extra clock periods to
resolve. `ASYNC_REG` keeps the chain flip-flops adjacent (required for
the MTBF calculation).

### Timing constraints (XDC)

The Gray-pointer timing constraints are **required for correctness**, not
optional timing optimization. Gray coding guarantees that only one pointer
bit changes per source-clock transition, but placement and routing can give
different bits different flight times. Without a max-delay bound, the
receiving clock can observe bits from different transitions and the FIFO
safety proof is invalid.

For each pointer bus, constrain the path from the source pointer registers
to the first synchronizer-stage registers. Vivado applies the constraint to
the register `Q`-to-`D` data paths. Use the period of the **source clock**
for that bus:

- `wptr_gray`: generated by `s_axis_aclk`, received by `m_axis_aclk`, so use
  the `s_axis_aclk` period.
- `rptr_gray`: generated by `m_axis_aclk`, received by `s_axis_aclk`, so use
  the `m_axis_aclk` period.

Do not apply `set_clock_groups -asynchronous` or a broad `set_false_path`
over these same pointer paths. Those exceptions can take precedence over
`set_max_delay` and leave the Gray bus physically unconstrained. The
`-datapath_only` max-delay exception removes phase alignment requirements
between the unrelated clocks while still bounding the routed bus delay.

### Using the XDC in Vivado

`constraints/axis_cdc.xdc` is a per-instance integration template. It is
not included in the standalone `vhdl.f` synthesis manifest because that flow
does not know the real top-level clock objects or final hierarchy.

1. Add the CDC RTL and the XDC to the integrating Vivado project. In a
   project flow, add the XDC to the active `constrs_1` constraint set. In a
   non-project flow, read it from the top-level Tcl script after synthesis:

   ```tcl
   synth_design -top my_top -part <part>
   create_clock -name s_axis_aclk -period 10.000 [get_ports s_axis_aclk]
   create_clock -name m_axis_aclk -period 13.000 [get_ports m_axis_aclk]
   read_xdc path/to/axis_cdc/constraints/axis_cdc.xdc
   ```

   If the clocks already come from a clocking wizard, PS, or another top-level
   constraint file, do not create duplicate clocks. Ensure the existing
   clock objects are available before the CDC XDC is read.

2. Edit the clock names in the XDC if the actual clock objects are not named
   `s_axis_aclk` and `m_axis_aclk`.

3. Edit the `u_core` hierarchy prefix if the instance is not wrapped by
   `axis_cdc_top`, or if the instance has another label. The template expects
   synthesized paths equivalent to:

   ```text
  u_core/r_s_reg[wptr_gray][*]
  u_core/wptr_gray_sync_chain_reg[0][*]
  u_core/r_m_reg[rptr_gray][*]
  u_core/rptr_gray_sync_chain_reg[0][*]
   ```

   Record fields and generated register names can vary between tools and
   synthesis settings. Verify the actual paths with:

   ```tcl
  get_cells -hierarchical -regexp {.*u_core/r_s_reg\[wptr_gray\]\[[0-9]+\]$}
  get_cells -hierarchical -regexp {.*u_core/wptr_gray_sync_chain_reg\[0\]\[[0-9]+\]$}
  get_cells -hierarchical -regexp {.*u_core/r_m_reg\[rptr_gray\]\[[0-9]+\]$}
  get_cells -hierarchical -regexp {.*u_core/rptr_gray_sync_chain_reg\[0\]\[[0-9]+\]$}
   ```

4. After synthesis and again after implementation, verify that both
   constraints are active and cover all pointer bits:

   ```tcl
   report_exceptions -file cdc_exceptions.rpt
   report_timing -from [get_cells -hierarchical -regexp {.*r_s_reg\[wptr_gray\]\[[0-9]+\]$}] \
     -to [get_cells -hierarchical -regexp {.*wptr_gray_sync_chain_reg\[0\]\[[0-9]+\]$}] \
     -max_paths 8 -file cdc_wptr_timing.rpt
   report_timing -from [get_cells -hierarchical -regexp {.*r_m_reg\[rptr_gray\]\[[0-9]+\]$}] \
     -to [get_cells -hierarchical -regexp {.*rptr_gray_sync_chain_reg\[0\]\[[0-9]+\]$}] \
     -max_paths 8 -file cdc_rptr_timing.rpt
   ```

   There must be no empty object-list or ignored-constraint warning. The
   timing reports must show the source-period max-delay requirement on every
   Gray-pointer bit. Do not accept a clean synthesis log as proof that the
   constraints were applied; only the post-synthesis reports establish that.

For non-Vivado tools, express the same source-period `set_max_delay` intent
in SDC and verify that no asynchronous-clock exception overrides it.

**Note on the data path:** there is no cross-domain data path to
constrain - data crosses through the dual-port RAM (write port in one
domain, read port in the other), and the RAM ports are each timed within
their own domain.

## Reliability and MTBF

### What MTBF means here

Every flip-flop that samples an asynchronous input has a small, non-zero
probability of going metastable. A synchronizer chain gives that
flip-flop extra clock cycles to resolve. The industry metric is the
**Mean Time Between Failures** (MTBF) of the synchronizer, described by

```
MTBF = exp(t_res / tau) / (f_clk_dest * f_data * T0)
```

| Symbol      | Meaning |
|-------------|---------|
| `t_res`     | Resolution time available: destination clock period minus setup time, clock skew and routing margin. |
| `tau`       | Metastability resolution time constant (roughly 10..100 ps on modern FPGAs). |
| `T0`        | Metastability capture-window constant (roughly 1e-15..1e-16 s on modern FPGAs). |
| `f_clk_dest`| Destination clock frequency. |
| `f_data`    | Toggle rate of the asynchronous input. |

Because MTBF grows exponentially with `t_res`, each additional stage
multiplies MTBF by a huge factor (roughly `exp(T_clk / tau)` per stage).

### Expectations for this module (default `GC_SYNC_STAGES = 2`)

The synchronized inputs are the **Gray pointer bits**. Gray code changes
one bit per increment, so the fastest bit toggles at roughly half the
pointer rate: `f_data ~= f_clk / 2` (whichever side generates the pointer
is the relevant clock). This is the worst case for this module; other
bits toggle more slowly and contribute far higher MTBF.

Illustrative order-of-magnitude estimates (modern FPGA, `tau = 50 ps`,
`T0 = 1e-15 s`, 0.5 ns setup/skew margin):

| `f_clk` | `t_res` | MTBF, 2 stages |
|---------|---------|----------------|
| 100 MHz | 9.5 ns  | effectively infinite (~10^74 years) |
| 200 MHz | 4.5 ns  | ~10^30 years |
| 300 MHz | 2.8 ns  | ~10^15 years |
| 500 MHz | 1.5 ns  | ~3,000 years |
| 700 MHz | 0.9 ns  | ~days |
| 1 GHz   | 0.5 ns  | ~hours |

At typical FPGA clocking (up to ~300 MHz), 2 stages gives an MTBF far
beyond any product lifetime. Above ~400-500 MHz the estimate collapses -
for high-frequency or safety-critical links use `GC_SYNC_STAGES = 3` or
`4`, which multiplies MTBF by roughly `exp(T_clk / tau)` per added stage
(effectively unbounded).

These are order-of-magnitude estimates. The definitive number comes from
the tool:

- **Vivado:** after implementation, `report_synchronizer_mtbf` (or the
  "Synchronizer MTBF" entry in the timing summary) reports the value the
  placer computed from the actual `t_res` margin.
- If the reported MTBF is not comfortably above your product lifetime,
  raise `GC_SYNC_STAGES` and re-implement.

### Design rules for maximum reliability

1. **No logic between synchronizer stages.** Each stage is a bare
   flip-flop; only the chain output is used.
2. **Single fan-out of the asynchronous input.** Only stage 0 samples the
   Gray pointer bits from the other domain.
3. **`ASYNC_REG` is set in RTL** and the XDC false-paths keep the tool
   from re-timing or merging the chain.
4. **Release the shared reset.** With both domains out of reset the link is
  fully functional; the flags are conservative and cannot corrupt data.

### Protocol-level reliability (beyond metastability)

- **No corruption:** data never crosses the boundary as a bus; it moves
  through the dual-port RAM.
- **No overflow:** the write side accepts the final free slot, then
  deasserts ready while the synchronized read pointer catches up.
- **No underflow:** the read side only asserts valid when the pointers
  differ (empty asserts late against a lagging write pointer).
- **No deadlock under backpressure:** a stalled consumer back-pressures
  through `s_axis_tready`; nothing is dropped.
- **Recovery after reset:** the shared reset returns both pointers to a
  well-defined empty state and the link re-establishes. In-flight data is
  intentionally flushed.

## Latency and Throughput

- **Throughput:** one word per clock on each side (line rate), sustained,
  for any clock ratio. This is the defining feature of the async FIFO
  CDC.
- **Latency:** fill latency is roughly `GC_SYNC_STAGES + 2` destination
  clocks (empty flag release) plus the FWFT read. Steady-state throughput
  is unaffected as long as `GC_CDC_DEPTH` is at least a few entries
  (depth >= 4 recommended).

### Clock ratio, sustained rate and FIFO depth

The conservative flags guarantee **no overflow or underflow for any clock
ratio**; the practical limits are rate and depth:

- **Sustained throughput is capped by the slower side.** A 250 MHz source
  into a 100 MHz destination transfers at most 100 Mwords/s. The FIFO
  absorbs short bursts; once it fills, `s_axis_tready` deasserts and the
  source is back-pressured (nothing is dropped). Size `GC_CDC_DEPTH` for the
  longest burst you must absorb before the destination drains, not for the
  average rate.
- **Depth 8 (default)** absorbs about 8 words of instantaneous skew. For a
  250 -> 100 MHz link this is a burst of roughly 13 source cycles (~53 ns)
  before backpressure. Increase the depth (power of two) if the source must
  sustain longer bursts.
- **`GC_SYNC_STAGES` and frequency:** 2 stages gives an effectively
  unbounded MTBF up to roughly 300-400 MHz (see the MTBF table above), so
  the 250 MHz default is comfortably safe. Use 3-4 stages only above that
  range or for extreme safety margin.
- **Wide payloads:** the FWFT combinational read always infers distributed
  RAM, so width multiplies LUT cost (a 512-bit x 8 FIFO is ~344 LUTs of
  distributed RAM on a 7-series part) and widens the combinational read
  mux. Keep the depth small at wide widths.

## Reset Behavior

- Both domains use the one shared `aresetn` input. Assertion is asynchronous
  so both pointer domains are flushed immediately, even if one clock is
  stopped. De-assertion is synchronous to each local clock, so neither
  domain can leave reset between clock edges.
- The RAM itself needs no reset; its contents are only read when the pointers
  say data is valid.
- Reset always flushes in-flight data. The upstream source must hold
  `s_axis_tvalid` low until reset is released.

## Instantiation

### VHDL

```vhdl
u_cdc : entity work.axis_cdc
  generic map (
    GC_TDATA_WIDTH => 32,
    GC_CDC_DEPTH   => 8,
    GC_SYNC_STAGES => 2
  )
  port map (
    -- Source domain
    s_axis_aclk   => s_axis_aclk,
    aresetn       => aresetn,
    s_axis_tdata  => s_axis_tdata,
    s_axis_tvalid => s_axis_tvalid,
    s_axis_tready => s_axis_tready,

    -- Destination domain
    m_axis_aclk   => m_axis_aclk,
    m_axis_tdata  => m_axis_tdata,
    m_axis_tvalid => m_axis_tvalid,
    m_axis_tready => m_axis_tready
  );
```

### SystemVerilog

```systemverilog
axis_cdc #(
    .GC_TDATA_WIDTH (32),
    .GC_CDC_DEPTH   (8),
    .GC_SYNC_STAGES (2)
) u_cdc (
    // Source domain
    .s_axis_aclk   (s_axis_aclk),
    .aresetn       (aresetn),
    .s_axis_tdata  (s_axis_tdata),
    .s_axis_tvalid (s_axis_tvalid),
    .s_axis_tready (s_axis_tready),

    // Destination domain
    .m_axis_aclk   (m_axis_aclk),
    .m_axis_tdata  (m_axis_tdata),
    .m_axis_tvalid (m_axis_tvalid),
    .m_axis_tready (m_axis_tready)
);
```

### Synthesis wrappers

`rtl/axis_cdc_top.vhd` and `rtl/axis_cdc_top.sv`
expose the same ports and pass the generics through, for use as a
standalone netlist top in mixed-language flows.

## Running the Testbench

```text
run axis_cdc vhdl modelsim             # ModelSim batch (default: source faster)
run axis_cdc vhdl modelsim --tb rev    # reverse direction (destination faster)
run axis_cdc vhdl modelsim --tb wide   # wide payload (512 bits)
run axis_cdc vhdl modelsim --tb all    # every configured testbench, one run each
run axis_cdc vhdl vivado               # Vivado synthesis
run axis_cdc vhdl xsim                 # XSim simulation (default TB)
```

The single testbench file (`tb/axis_cdc_tb.vhd`) is parameterized by generics
for the DUT (`GC_TDATA_WIDTH`, `GC_CDC_DEPTH`, `GC_SYNC_STAGES`) and the
clock periods (`GC_TS`, `GC_TM`). The manifest runs several configurations of
the same file:

- `[tb:default]` (16-bit, source faster) proves **destination line rate**.
- `[tb:rev]` (destination faster) proves **source line rate** - the source
  must accept one word per source clock with no backpressure. The `[tb:rev]`
  section overrides the clock periods via the manifest `generics` metadata,
  which `run.py` passes to `vsim` as `-gGC_TS=13ns -gGC_TM=10ns` (and to
  XSim's `xelab` as `-generic_top`).
- `[tb:wide]` runs the same regression with a 512-bit payload
  (`-gGC_TDATA_WIDTH=512`); all four phases are verified at the wide width.

The testbench (all phases, all configurations):

- Uses two coprime clocks so edges drift continuously, exercising a real
  asynchronous clock relationship.
- **Phase A proves line rate** on the bottleneck side: the destination when
  the source is faster, the source when the destination is faster.
- **Phase B** verifies order and integrity of a longer sequence under
  destination backpressure (ready 3 of 4 cycles).
- **Phase C** pulses the shared reset and verifies the flushed link
  re-establishes cleanly.
- **Phase D** injects source-side `tvalid` gaps (1 cycle in 4) and verifies
  no word is lost or reordered.
- Has a watchdog so a deadlock fails instead of hanging the batch run.

Other depths and `GC_SYNC_STAGES` 3..4 are verified functionally but are not
part of the committed regression.

On success the transcript ends with:

```text
ALL CDC CHECKS PASSED
```
