# axis_cdc

AXI4-Stream clock-domain converter (CDC) using a Gray-pointer asynchronous
FIFO core.

Transfers an AXI4-Stream from the source clock domain (`s_axis_aclk`) to
the destination clock domain (`m_axis_aclk`). With sufficient FIFO depth it
sustains the slower side's **line-rate throughput** for unrelated, equal,
faster-source, or faster-destination clocks. Small legal depths remain safe
but can insert bubbles because synchronized pointers reduce immediately
usable capacity.

## Overview

This is the industry-standard high-performance CDC: a dual-port RAM whose
write port runs on the source clock and whose read port runs on the
destination clock. Only the **Gray-coded pointers** cross the boundary,
each re-timed through a 2..4 flip-flop synchronizer chain. Because the
pointers are the only cross-domain signals and they are safe by
construction (Gray code changes one bit per increment), the data plane is
fully decoupled. The default depth is sized for line-rate operation in the
committed clock-ratio and synchronizer-stage regressions.

The FIFO depth is a power-of-two generic (`GC_CDC_DEPTH`, default 8).
Pick the smallest depth that covers your throughput and burst needs. The
first-word fall-through (combinational) read requires a distributed-RAM
(LUTRAM) implementation at any depth, so a large depth is expensive in
LUTs; keep it small.

### When to use this

- You need to cross a data stream between unrelated clocks at high rate.
- The source or destination must run at line rate and the FIFO can be sized
  for the clock ratio and synchronizer latency.
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
| `GC_CDC_DEPTH`   | `2 to 1024`    | 8       | FIFO depth (must be a power of two). Depths 2 and 4 are safe but can insert throughput bubbles. The FWFT combinational read always infers distributed RAM, so keep it small. |
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
     write pointer. Because that pointer lags, empty deasserts late - the
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
different bits different flight times. The max-delay constraint bounds the
absolute route time, while the bus-skew constraint bounds the arrival-time
spread between bits of one pointer bus.

For each pointer bus, constrain the path from the source pointer registers
to the first synchronizer-stage registers. Vivado applies the constraints to
the register `Q`-to-`D` data paths. The committed ZCU102 integration uses the
fastest involved clock period (4 ns) for every max delay and 2 ns for every
bus skew. Apply bus skew separately to each logical pointer bus; combining
independent FIFO instances into one collection creates meaningless
cross-instance comparisons.

Do not apply `set_clock_groups -asynchronous` or a broad `set_false_path`
over these same pointer paths. Those exceptions can take precedence over
`set_max_delay` and leave the Gray bus physically unconstrained. The
`-datapath_only` max-delay exception removes phase alignment requirements
between the unrelated clocks while still bounding the routed bus delay.

### Using the XDC in Vivado

`constraints/axis_cdc.xdc` is a per-instance integration template. It is
not included in the standalone `vhdl.f` synthesis manifest because that flow
does not know the real top-level clock objects or final hierarchy.

The constraints folder also contains a complete reusable integration example:

- `constraints/axis_cdc_multi_instance_example.xdc`
- `constraints/axis_cdc_impl_hook_example.tcl`
- `constraints/axis_cdc_find_hierarchy.tcl`
- `constraints/AXIS_CDC_CONSTRAINTS.md`
- `constraints/VIVADO_GUI_QUICK_START.md`

Start with `VIVADO_GUI_QUICK_START.md`. Use `AXIS_CDC_CONSTRAINTS.md` when
adapting clocks, hierarchy, instance count, or FIFO depth.

1. Add the CDC RTL to the integrating Vivado project. Copy and adapt either
  the single-instance XDC template or the worked multi-instance example. A
  hierarchical XDC must be read after `link_design`, when the clock objects
  and synthesized cells exist. In a GUI project, use the `opt_design` pre-
  hook procedure documented in the quick start. In a non-project flow, read
  the XDC after synthesis and design linking:

   ```tcl
   synth_design -top my_top -part <part>
   create_clock -name s_axis_aclk -period 10.000 [get_ports s_axis_aclk]
  create_clock -name m_axis_aclk -period 4.000 [get_ports m_axis_aclk]
   read_xdc path/to/axis_cdc/constraints/axis_cdc.xdc
   ```

   If the clocks already come from a clocking wizard, PS, or another top-level
   constraint file, do not create duplicate clocks. Ensure the existing
   clock objects are available before the CDC XDC is read.

2. Review the explicit 4 ns max-delay and 2 ns bus-skew values against the
  integrating design's clocks. If using the implementation hook, update its
  required clock-object names as well.

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
  constraint types are active and cover all pointer bits:

   ```tcl
   report_exceptions -file cdc_exceptions.rpt
   report_timing -from [get_cells -hierarchical -regexp {.*r_s_reg\[wptr_gray\]\[[0-9]+\]$}] \
     -to [get_cells -hierarchical -regexp {.*wptr_gray_sync_chain_reg\[0\]\[[0-9]+\]$}] \
     -max_paths 8 -file cdc_wptr_timing.rpt
   report_timing -from [get_cells -hierarchical -regexp {.*r_m_reg\[rptr_gray\]\[[0-9]+\]$}] \
     -to [get_cells -hierarchical -regexp {.*rptr_gray_sync_chain_reg\[0\]\[[0-9]+\]$}] \
     -max_paths 8 -file cdc_rptr_timing.rpt
   report_bus_skew -warn_on_violation -file cdc_bus_skew.rpt
   ```

   There must be no empty object-list or ignored-constraint warning. The
  timing reports must show the intended max-delay requirement on every
  Gray-pointer bit, and the bus-skew report must list every logical pointer
  bus with non-negative slack. Do not accept a clean synthesis log as proof
  that the constraints were applied.

For non-Vivado tools, express the same max-delay and bus-skew intent in SDC
and verify that no asynchronous-clock exception overrides the max delay.

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
3. **`ASYNC_REG` is set in RTL** to preserve and cluster synchronizer
  stages. The XDC max-delay constraints separately bound Gray-bus routing.
4. **Release the shared reset.** With both domains out of reset the link is
  fully functional; the flags are conservative and cannot corrupt data.

### Protocol-level reliability (beyond metastability)

- **No corruption:** data never crosses the boundary as a bus; it moves
  through the dual-port RAM.
- **No overflow:** the write side accepts the final free slot, then
  deasserts ready while the synchronized read pointer catches up.
- **No underflow:** the read side only asserts valid when the pointers
  differ (empty deasserts late against a lagging write pointer).
- **No deadlock under backpressure:** a stalled consumer back-pressures
  through `s_axis_tready`; nothing is dropped.
- **Recovery after reset:** the shared reset returns both pointers to a
  well-defined empty state and the link re-establishes. In-flight data is
  intentionally flushed.

## Latency and Throughput

- **Throughput ceiling:** one word per clock on each side. The sustained
  rate cannot exceed the slower side and reaches that ceiling only when FIFO
  depth is sufficient for the clock ratio and synchronizer round-trip delay.
- **Latency:** fill latency is roughly `GC_SYNC_STAGES + 2` destination
  clocks (empty flag release) plus the FWFT read. Depths 2 and 4 are useful
  for area-limited, intermittent traffic but showed bubbles in the committed
  line-rate scenario. Depth 8 is the tested throughput default.

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
- Reset always flushes in-flight data. Transfers are disabled while reset is
  active; upstream logic must not rely on data presented during reset.
- `s_axis_tready` and `m_axis_tvalid` clear asynchronously when `aresetn`
  asserts. The regression checks this while data is queued and the output is
  stalled.

## Instantiation

Ready-to-copy templates for instantiating `axis_cdc` in a design. The
example uses the default **32-bit, depth-8, 2 sync stages** configuration;
data width and FIFO depth follow from `GC_TDATA_WIDTH` / `GC_CDC_DEPTH`.

### VHDL

```vhdl
architecture rtl of <your_design> is

  -- Shared reset (synchronized into both clock domains)
  signal aresetn : std_logic;  -- synchronous, active low

  -- Source domain (narrow input)
  signal s_axis_aclk   : std_logic;                      -- source clock
  signal s_axis_tdata  : std_logic_vector(31 downto 0);  -- source data
  signal s_axis_tvalid : std_logic;                      -- source valid
  signal s_axis_tready : std_logic;                      -- source ready

  -- Destination domain (wide output)
  signal m_axis_aclk   : std_logic;                      -- destination clock
  signal m_axis_tdata  : std_logic_vector(31 downto 0);  -- destination data
  signal m_axis_tvalid : std_logic;                      -- destination valid
  signal m_axis_tready : std_logic;                      -- destination ready

begin

  u_cdc : entity work.axis_cdc
    generic map (
      GC_TDATA_WIDTH => 32,  -- data width (bits)
      GC_CDC_DEPTH   => 8,   -- FIFO depth (power of two)
      GC_SYNC_STAGES => 2    -- synchronizer stages
    )
    port map (
      -- Shared reset
      aresetn => aresetn,

      -- Source domain
      s_axis_aclk   => s_axis_aclk,
      s_axis_tdata  => s_axis_tdata,
      s_axis_tvalid => s_axis_tvalid,
      s_axis_tready => s_axis_tready,

      -- Destination domain
      m_axis_aclk   => m_axis_aclk,
      m_axis_tdata  => m_axis_tdata,
      m_axis_tvalid => m_axis_tvalid,
      m_axis_tready => m_axis_tready
    );

end architecture;
```

### SystemVerilog

```systemverilog
module <your_module>;

  // Shared reset (synchronized into both clock domains)
  logic aresetn;  // synchronous, active low

  // Source domain (narrow input)
  logic        s_axis_aclk;    // source clock
  logic [31:0] s_axis_tdata;   // source data
  logic        s_axis_tvalid;  // source valid
  logic        s_axis_tready;  // source ready

  // Destination domain (wide output)
  logic        m_axis_aclk;    // destination clock
  logic [31:0] m_axis_tdata;   // destination data
  logic        m_axis_tvalid;  // destination valid
  logic        m_axis_tready;  // destination ready

  axis_cdc #(
      .GC_TDATA_WIDTH (32),  // data width (bits)
      .GC_CDC_DEPTH   (8),   // FIFO depth (power of two)
      .GC_SYNC_STAGES (2)    // synchronizer stages
  ) u_cdc (
      // Shared reset
      .aresetn (aresetn),

      // Source domain
      .s_axis_aclk   (s_axis_aclk),
      .s_axis_tdata  (s_axis_tdata),
      .s_axis_tvalid (s_axis_tvalid),
      .s_axis_tready (s_axis_tready),

      // Destination domain
      .m_axis_aclk   (m_axis_aclk),
      .m_axis_tdata  (m_axis_tdata),
      .m_axis_tvalid (m_axis_tvalid),
      .m_axis_tready (m_axis_tready)
  );

endmodule
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
run axis_cdc sv vivado                  # mixed-language SV-wrapper synthesis
run axis_cdc vhdl xsim                 # XSim simulation (default TB)
```

The single testbench file (`tb/axis_cdc_tb.vhd`) is parameterized by generics
for payload width, FIFO depth, synchronizer stages, clock periods, and whether
the selected configuration is expected to sustain line rate. `scripts/vhdl.f`
runs these committed configurations:

| Test | Width | Depth | Sync stages | Source / destination period | Line-rate assertion |
|---|---:|---:|---:|---|---|
| `default` | 16 | 8 | 2 | 10 ns / 13 ns | Destination |
| `rev` | 16 | 8 | 2 | 13 ns / 10 ns | Source |
| `wide` | 512 | 8 | 2 | 10 ns / 13 ns | Destination |
| `narrow` | 1 | 8 | 2 | 10 ns / 13 ns | Destination |
| `depth2` | 16 | 2 | 2 | 10 ns / 13 ns | Disabled; integrity only |
| `depth4` | 16 | 4 | 2 | 10 ns / 13 ns | Disabled; integrity only |
| `depth16` | 16 | 16 | 2 | 10 ns / 13 ns | Destination |
| `sync3` | 16 | 8 | 3 | 10 ns / 13 ns | Destination |
| `sync4` | 16 | 8 | 4 | 10 ns / 13 ns | Destination |
| `equal` | 16 | 8 | 2 | 10 ns / 10 ns | Destination |
| `fast_source` | 16 | 8 | 2 | 2 ns / 20 ns | Destination |
| `fast_destination` | 16 | 8 | 2 | 20 ns / 2 ns | Source |
| `stress` | 512 | 8 | 4 | 2 ns / 20 ns | Destination |

The runner passes manifest `generics` metadata to `vsim` as `-g` overrides
and to XSim as `-generic_top` overrides.

The testbench (all phases, all configurations):

- Uses two coprime clocks so edges drift continuously, exercising a real
  asynchronous clock relationship.
- **Phase A proves line rate** on the bottleneck side: the destination when
  the source is faster, the source when the destination is faster.
- **Phase B** holds the destination stalled until the FIFO backpressures the
  source, then uses a ready 3-of-4 cycle pattern. It proves the full boundary
  is reached and checks that `m_axis_tvalid` and `m_axis_tdata` remain stable
  throughout every stall.
- **Phase C** queues data with `m_axis_tvalid = '1'`, holds the output stalled,
  keeps source traffic active, then asserts reset. It checks asynchronous
  clearing of ready/valid, queued-data flushing, and clean restart from word
  zero.
- **Phase D** injects source-side `tvalid` gaps (1 cycle in 4) and verifies
  no word is lost or reordered.
- Has a watchdog so a deadlock fails instead of hanging the batch run.
- Generates data across every payload bit, including legal one-bit payloads.
- Sends enough words to wrap the pointers repeatedly at every tested depth.

The shared `util_pkg` regression separately exhausts binary/Gray round trips
for pointer widths 2 through 5 and checks full/empty predicates at FIFO depths
2, 4, and 8.

RTL simulation cannot inject analog metastability or prove routed Gray-bus
delay. Hardware CDC signoff therefore also requires the XDC setup and
post-implementation verification in `constraints/AXIS_CDC_CONSTRAINTS.md`.

`scripts/sv.f` synthesizes `rtl/axis_cdc_top.sv` with the VHDL core in Vivado,
checking mixed-language parameter and port binding.

On success the transcript ends with:

```text
ALL CDC CHECKS PASSED
```

### UVVM VVC testbench

`tb/axis_cdc_uvvm_th.vhd` and `tb/axis_cdc_uvvm_tb.vhd` provide an
independent, protocol-level testbench built on the UVVM AXI-Stream VVCs.
It covers ordered multi-wrap, full backpressure with stalled-output
stability, randomized valid/ready gaps, and queued-data reset flushing.
The eight UVVM configurations in `scripts/uvvm.f` are run with:

```text
run axis_cdc uvvm modelsim --tb all
```

See `doc/UVVM_TESTBENCH.md` for the full description, including the UVVM
VIP width limit (256-bit maximum payload) and how it relates to the
direct testbench's 512-bit configurations.
