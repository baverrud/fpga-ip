# Session Summary

## Completed

- Reviewed `axis_cdc` RTL, constraints, wrappers, and existing testbenches.
- Corrected throughput documentation: depths 2 and 4 are safe but can insert bubbles; depth 8 is the tested throughput default.
- Strengthened the direct testbench with:
  - Full-FIFO backpressure coverage.
  - Output data/valid stability during stalls.
  - Reset while data is queued and output is stalled.
  - Asynchronous reset clearing checks.
  - Distinct pre-reset marker data to detect leaked words.
  - Payload patterns valid from 1-bit through wide payloads.
- Added 13 ModelSim presets covering widths, depths 2/4/8/16, synchronizer stages 2/3/4, equal clocks, extreme ratios, and combined stress.
- Added `scripts/sv.f` and verified the mixed-language SystemVerilog wrapper with Vivado 2023.2.
- Added reusable CDC constraint examples, hierarchy discovery helper, implementation hook, detailed guide, and GUI quick start under `axis_cdc/constraints`.
- Updated `axis_cdc/README.md` and wrapper comments.
- Added the UVVM VVC harness/sequencer, `scripts/uvvm.f` manifest, and `doc/UVVM_TESTBENCH.md`; all eight UVVM configurations pass under ModelSim 2020.1 (see the UVVM section below).

## Validation

- All 13 direct ModelSim presets passed.
- All 42 repository Python tests passed.
- Vivado 2023.2 mixed-language synthesis passed.
- Formatter, diagnostics, ASCII, manifest, and diff checks passed.
- Fixed settle delays were removed from both testbenches. All 13 direct and
  all eight UVVM ModelSim profiles passed afterward; the asynchronous reset
  checks now prove ready/valid clear without advancing simulation time.
- The ZCU102 hook validated sixteen logical buses with four source and four
  sync cells each. Routed Vivado 2023.2 checks confirmed all max-delay groups
  at 4 ns and all sixteen logical pointer buses at 2 ns skew. Worst measured
  bus skew was 0.851 ns, leaving 1.149 ns slack. Worst-path max-delay slacks
  were 3.334 ns (`ar_wptr`), 3.332 ns (`ar_rptr`), 2.828 ns (`r_wptr`), and
  2.749 ns (`r_rptr`). `report_exceptions -ignored` found no ignored timing
  exceptions. The integrating top-level design still has unrelated ordinary
  timing violations (`WNS = -0.576 ns`); these do not involve the axis_cdc
  max-delay or bus-skew constraints.

## UVVM VVC Testbench (Complete)

- Created the UVVM AXI-Stream VVC harness (`tb/axis_cdc_uvvm_th.vhd`) and
  sequencer (`tb/axis_cdc_uvvm_tb.vhd`).
- Harness: independent source/destination clocks, master/slave VVCs, a
  deterministic forced-stall mux, and debug taps for structural checks.
- Sequencer phases: ordered multi-wrap, full backpressure with
  stalled-output stability, randomized valid/ready gaps (0.35 / 0.40
  probability), and queued-data reset flush with distinct pre/post-reset
  markers. Coverage signals confirm the behaviors were exercised.
- The default UVVM run previously had one `TB_WARNING` from the 13 ns
  reverse preset (non-representable timestamps in the UVVM log); the
  `rev` preset now uses 13.2 ns.
- All eight UVVM configurations in `scripts/uvvm.f` (default, rev, depth2,
  sync4, equal, fast_source, fast_destination, stress) **pass** under
  ModelSim 2020.1 with zero `ERROR`/`TB_ERROR`/`FAILURE` alerts, ending in
  `AXIS_CDC UVVM VVC TEST PASSED`.
- Documented in `doc/UVVM_TESTBENCH.md` and linked from `README.md`.

## Residual Limits

RTL simulation cannot prove analog metastability behavior or future routed
implementations. Every integrating design must retain the `ASYNC_REG`
attributes, apply its max-delay and per-bus-skew constraints through the
post-link hook, and rerun post-route timing and bus-skew reports after clock,
hierarchy, device, or implementation changes.

Do not commit or push unless explicitly requested.

## Lessons for fpga-rules

These workflow findings should be considered for a future update to the
shared `fpga-rules` documentation.

### Vivado XDC timing

- A constraint file being listed in a Vivado constraint set does not prove
  that its constraints apply. `read_xdc` can succeed while `get_cells` and
  `get_clocks` match nothing.
- In this project, normal constraint files are read before `link_design`.
  Hierarchical synthesized cells and generated PS clock objects do not exist
  at that point. Hierarchical constraints that depend on those objects need
  to be loaded from an implementation hook after `link_design`.
- Keep XDC files declarative. Vivado reports `Designutils 20-1307` when
  procedural Tcl such as `if` is placed directly in an XDC file. Put checks,
  loops, path construction, and `error` commands in a Tcl hook, then use
  `read_xdc` from that hook.
- The reliable project pattern is a pure XDC plus an `opt_design` `tcl.pre`
  hook. Disable the XDC's normal **Used In Synthesis** and **Used In
  Implementation** properties so it is not read early, while leaving the
  file on disk for the hook.
- A hook should fail closed: check required clocks and each logical bus's
  endpoint counts before reading the XDC. Aggregate counts can hide a missing
  instance and must not be used for bus-skew validation.
- Verify constraints at three levels: hook log marker, non-empty per-bus
  endpoint collections, and `report_exceptions`/`report_timing` plus
  `report_bus_skew -warn_on_violation`. A negative slack is different from a
  missing constraint: it means the active requirement is not met, not that
  the XDC failed to load.
- The GUI can configure the hook through **Design Runs -> Change Run
  Settings -> opt_design -> Pre Tcl Script**. Tcl Console commands are only
  a fallback for layouts that do not expose the field and for exact checks.
- Hierarchical names should be discovered from **Open Synthesized Design** or
  **Open Implemented Design**, not only the elaborated RTL view. A read-only
  helper that prints full cell names is easier and safer than guessing names
  from VHDL source.
- Reusable XDC examples should document clock names, hierarchy assumptions,
  endpoint-count formulas, and the exact report commands used to validate
  them.

### Vivado checkpoint validation

- Validate post-link XDC against an available synthesized/optimized
  checkpoint, but confirm that the checkpoint contains resolved clock and
  hierarchy objects. A synthesis checkpoint with unresolved generated IP
  black boxes may not contain the PS clocks and is unsuitable for hook
  validation.
- Implementation resets can remove optimized or routed checkpoints. Do not
  assume a previously generated `*_opt.dcp` or routed DCP still exists after
  resetting a run; locate the newest checkpoint before validating.
- When validating a checkpoint in batch mode, always use a dedicated
  temporary build directory and ensure the Tcl script ends with `exit`.

### Simulator and runner behavior

- Compile and simulate with the same simulator version/library format. A
  ModelSim 2021.1 `vsim` invocation cannot reliably load a `work` library
  compiled by ModelSim 2020.1; this produced an "obsolete library format"
  failure. Initialize and use the matching `m20` toolchain for the existing
  library.
- Prefer the repository manifest runner with `--tb all` over hand-written
  `vsim -do` commands. Nested Windows quoting can alter or truncate simulator
  commands, while the runner creates reproducible scripts in the IP's
  dedicated `.runs` directory.
- Run EDA tools from dedicated build directories. Vivado, ModelSim, and
  Questa create logs, libraries, checkpoints, and databases in the current
  directory.
- A parameterized testbench can cover a broad matrix without duplicating TB
  source files: use named manifest sections and `generics = name=value`
  overrides. Include both passing safety/integrity tests and explicit
  configurations where a performance assertion is intentionally disabled.

### Mixed-language manifests

- A `.f` manifest can compile VHDL RTL and use a SystemVerilog synthesis top;
  `run.py` emits `read_vhdl` and `read_verilog -sv` in the correct order.
- Mixed-language wrapper coverage should be an explicit Vivado manifest
  target. Merely having an `.sv` wrapper in the RTL directory does not test
  parameter/generic binding.

### CDC verification boundaries

- RTL simulation can verify ordering, data integrity, reset flushing,
  handshake stability, full/empty behavior, clock ratios, payload widths, and
  synchronizer-stage parameterization.
- RTL simulation cannot prove analog metastability tolerance, physical
  synchronizer placement, Gray-bus routing skew, or implementation timing.
  Those require `ASYNC_REG`, correct post-link XDC constraints, and
  post-implementation timing/exception reports.

### UVVM AXI-Stream VIP width limit

- The UVVM AXI-Stream VIP caps `TSTRB` (one bit per data byte) at
  `C_AXISTREAM_BFM_MAX_TSTRB_BITS = 32`, defined in
  `uvvm_util/src/adaptations_pkg.vhd`. This limits VVC-driven payloads to
  **32 bytes = 256 bits**. A 512-bit payload causes a fatal slice overflow
  inside `axistream_bfm_pkg.vhd` (`vsim-3471`: slice range `(63 downto 0)`
  does not belong to prefix index range `(31 downto 0)`) rather than a
  clean UVVM alert.
- Check the precompiled VIP's `C_AXISTREAM_BFM_MAX_*_BITS` constants before
  choosing a wide-payload VVC configuration; cover wider widths with a
  direct (hand-written BFM) testbench instead.
- The AXI-Stream VIP's `ready_default_value` only controls TREADY between
  commands; it does not keep TREADY low through a specific window. To stall
  the sink for a known number of cycles, mux TREADY with a structural
  `force_m_stall` override in the harness.
