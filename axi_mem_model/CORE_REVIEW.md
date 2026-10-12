# axi_mem_model_core Review

## Scope

This review covers `rtl/axi_mem_model_core.vhd` and its contract with the surrounding `axi_mem_model` wrapper and `axis_latency_gen` instances.

## Summary

`axi_mem_model_core` is a compact and readable two-process burst sequencer. It generates deterministic address-based read data, holds R-channel outputs correctly under backpressure, and has deliberate lookahead logic for accepting a new AR transaction on the same cycle that the current burst's final R beat is consumed.

The core is appropriate for a serialized AXI read-slave model. Its main limitation is architectural: it emits beats as quickly as the downstream stream accepts them and therefore does not implement inter-beat timing itself. The documented timing behavior depends on `axis_latency_gen`.

## Findings

### 1. Burst transactions are serialized

While a burst is active, `ar_ready` is deasserted except when the current final R beat is being consumed. The upstream AR latency generator can buffer requests, but the core processes only one burst at a time and never interleaves responses from different IDs.

This is valid for a serialized memory model, but the limitation should be explicit in the IP documentation. Users expecting multiple outstanding transactions or AXI response interleaving should use a different architecture.

### 2. The core does not implement inter-beat gaps

In `S_SEND_BEATS`, each accepted R beat advances the beat index and prepares the next beat. This is intentional maximum-rate behavior. The comments state that the downstream R-side `axis_latency_gen` supplies the inter-beat gap.

That contract must be verified independently. The current latency generator assigns a departure timestamp to each beat based on its arrival time. Since the core emits beats one cycle apart, a configured `base_beat_gap` does not automatically create that gap between output beats.

The core should remain a maximum-rate producer unless the design requirement changes. The timing fix belongs in `axis_latency_gen` or in a dedicated beat-spacing stage, not in this burst sequencer.

### 3. Handshake intent could be made more explicit

The implementation checks `ar_valid`, `r_valid`, and `r_ready` directly in the state machine. The logic is currently coherent because `ar_ready` is asserted in the matching conditions and R outputs are registered.

Named handshake expressions such as `ar_fire` and `r_fire` would make the acceptance conditions easier to audit and would reduce the risk of a future change creating an implicit handshake mismatch.

### 4. Address arithmetic needs a documented width contract

`beat_addr` calculates the byte offset with:

```vhdl
 to_integer(beat_idx) * GC_DATA_BYTES
```

and converts the result to `GC_ADDR_WIDTH`. The default address width is large enough for all supported burst lengths and data widths, but small custom address widths can truncate the offset or produce tool warnings.

The implementation should either document modular address wraparound as intentional or add a generic assertion describing the minimum supported address width.

### 5. The data pattern intentionally truncates to 32 bits

For buses of four bytes and wider, `make_rdata` derives each word from the low 32 bits of the address. This matches the README examples and is suitable for a deterministic verification pattern, but it is not a complete-width physical-address pattern for `GC_ADDR_WIDTH > 32`.

This is not a bug, but the truncation should remain clearly documented as part of the test pattern contract.

## Verification Performed

The repository testbench was run with ModelSim using the `vhdl.f` manifest:

- All eight supported data widths passed: 1, 2, 4, 8, 16, 32, 64, and 128 bytes.
- Burst lengths 0, 3, 7, and 255 passed.
- Back-to-back AR traffic passed.
- R-channel backpressure and held-valid behavior passed.
- Reset during an active burst passed.
- The run completed with zero errors.
- ModelSim reported 48 `numeric_std` metavalue warnings from the latency-generator comparison path.

The testbench does not currently measure exact first-beat latency or exact inter-beat spacing. Therefore, it does not prove the documented timing behavior.

## Recommended Follow-up

1. Add cycle-accurate assertions for first-beat latency and inter-beat spacing.
2. Decide and document whether serialized burst handling is a deliberate limitation.
3. Correct or redesign the R-side timing behavior in `axis_latency_gen`.
4. Add a parameter check or documented wraparound rule for small `GC_ADDR_WIDTH` values.
5. Consider explicit `ar_fire` and `r_fire` signals for handshake clarity.
6. Investigate the 48 `numeric_std` metavalue warnings in `axis_latency_gen` separately from this core.

## Related Files

- [`rtl/axi_mem_model_core.vhd`](rtl/axi_mem_model_core.vhd)
- [`rtl/axi_mem_model.vhd`](rtl/axi_mem_model.vhd)
- [`../axis_latency_gen/rtl/axis_latency_gen.vhd`](../axis_latency_gen/rtl/axis_latency_gen.vhd)
- [`tb/axi_mem_model_tb.vhd`](tb/axi_mem_model_tb.vhd)
- [`scripts/vhdl.f`](scripts/vhdl.f)
- [`README.md`](README.md)
