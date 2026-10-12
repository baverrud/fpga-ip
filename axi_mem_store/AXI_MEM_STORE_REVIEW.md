# axi_mem_store Review

Review of `axi_mem_store` (`rtl/axi_mem_store.vhd`, `rtl/axi_mem_store_core.vhd`),
its submodules (`axis_latency_gen`, `jitter_gen`), the three testbenches, the
top wrappers and the README.

Overall the design is sound. It has careful range checks (a carry bit so an
address can't wrap past the top of memory, and an out-of-range flag that stays
set for the rest of the burst), registered R fields, and memory that survives
reset. The default testbench also exercises the core directly, without the
latency wrapper.

## Status

| # | Task | Severity | Status |
|---|---|---|---|
| 1 | RVALID drops after a long `r_ready` stall | High | **Done** |
| 2 | Unaligned reads don't follow AXI byte lanes | High | **Done** |
| 3 | Latency and jitter controls are not verified | Medium | **Done** |
| 4 | Address-wrap guarantee fails at minimum address width | Medium | **Done** |
| 5 | Synthesis defaults are impractical | Medium | Open |
| 6 | Core `ar_ready` is high during reset | Low | **Done** |
| 7 | Burst-start code is duplicated | Low | **Done** |
| 8 | Memory size vs. beat size is not asserted | Low | **Done** |
| 9 | `simple` testbench checks nothing | Low | **Done** |
| 10 | Testbench nits | Low | **Done** |
| 11 | Missing test coverage | Low | **Done** |
| 12 | `axis_latency_gen` README claims a check that doesn't exist | Low | **Done** |
| 13 | Queued entries behind a stalled head can be delayed | Low | Documented limit |
| 14 | `axi_mem_model` has the same non-AXI unaligned mapping | Medium | **Done** |
| 15 | `axis_latency_gen` emits startup metavalue warnings | Low | **Done** |

Items 12 and 13 are in `axis_latency_gen`, which is a separate IP. Changing it
needs explicit approval under the workspace rules.

---

## 1. RVALID drops after a long `r_ready` stall - DONE

**Where:** `axis_latency_gen/rtl/axis_latency_gen.vhd`, release logic.

**Problem:** the output was released by `signed(timer - t_departure) >= 0`.
The timer keeps counting while the output is stalled, so after
2^(GC_TIMER_WIDTH-1) cycles past departure the difference wrapped negative,
`m_axis_tvalid` fell without a handshake, and `r_valid` of `axi_mem_store`
dropped. That is an AXI violation. It happened after 128 cycles with the
testbenches' 8-bit timer.

**Fix:** a register `head_released` remembers that the head entry is due until
it is popped:

```vhdl
time_arrived <= '1' when (ff_valid = '1') and
                        ((head_released = '1') or
                         (signed(timer - ff_t_departure) >= 0)) else '0';
head_released <= time_arrived and not m_axis_tready;  -- clocked, cleared on pop
```

**Verification:**
- New Phase 15 in `axis_latency_gen_tb`: 300-cycle output stall. It failed
  before the fix (`m_axis_tvalid dropped without a handshake after 128 stall
  cycles`) and passes after it.
- New 300-cycle `r_ready` stall in `axi_mem_store_tb`. It failed before the
  fix and passes after it.
- Every testbench mode of all 8 IPs that use `axis_latency_gen`: 20/20 pass on
  ModelSim. `axis_latency_gen` and `axi_mem_store` also pass on XSim (5/5).
- Normal latency is unchanged: the measured delays in Phases 1-14 are the
  same as before the fix.

---

## 2. Unaligned reads don't follow AXI byte lanes - DONE

**Where:** `rtl/axi_mem_store_core.vhd`, burst start in `S_WAIT_AR` and in
the last-beat branch of `S_SEND_BEATS`.

**Problem:** the core put the byte at `ar_addr` on lane 0 and advanced every
beat by `n * GC_DATA_BYTES` from the unaligned start. In AXI, byte address A
belongs on lane `A mod GC_DATA_BYTES`, and every beat after the first is
aligned. Aligned reads were correct; unaligned reads returned shifted data.

**Fix:** a new function `aligned_beat` clears the low
`log2(GC_DATA_BYTES)` address bits when a burst starts. Every beat then reads
the aligned window that contains it, and the range check is done on that
window. The one-byte bus needs no special case (`log2ceil(1) = 0`).

**Consequences, intended:**
- An unaligned first beat also carries the bytes below the start address on
  its lower lanes; an AXI master ignores those lanes.
- An unaligned beat near the top of memory is now `OKAY` when its aligned
  window is inside memory. Before, it was `SLVERR` because the shifted window
  crossed the top.

**Testbench changes:**
- `read_burst` (default) and `check_pattern_bytes` (wide) now expect the
  aligned window for every beat.
- New unaligned burst: `read_burst(17, 6, 3, ...)`.
- Address 62 (default) and 1024-32 (wide) now expect `OKAY` with data. A new
  check at address 64 keeps `SLVERR` covered at the first beat above memory.
- The reset-preservation read at address 21 now expects the aligned word at
  20 (`x"00000055"`); byte 21 (lane 1) must still be zero.

**Verification:**
- With alignment temporarily disabled, the default testbench fails
  (`stored byte data mismatch`) and the wide one fails (`R RESP mismatch`),
  so the new expectations catch the old mapping.
- With the fix: `axi_mem_store` (default, simple, wide) and `axi_read_tester`
  (default, model, simple) pass on ModelSim, 6/6; `axi_mem_store` passes on
  XSim, 3/3.
- `axi_read_tester` passing with both memories shows it issues only aligned
  reads, so it is unaffected.

The complete ModelSim suite passes: `axi_mem_model` default, all
`axi_mem_store` modes, both `axis_latency_gen` modes, and all
`axi_read_tester` modes (9/9).

---

## 3. Latency and jitter controls are not verified - DONE

**Where:** `tb/axi_mem_store_tb.vhd` (line 505 onward) and
`tb/axi_mem_store_wide_tb.vhd` (lines 321 and 328).

**Fix:** `axi_mem_store_tb` now measures AR-acceptance-to-RVALID latency.
It verifies that enabled AR/R base delays increase the measured latency and
that four enabled-jitter samples produce variation. The full m20 regression
passes with these checks enabled.

---

## 4. Address-wrap guarantee fails at minimum address width - DONE

**Where:** `rtl/axi_mem_store_core.vhd`, `beat_addr` (line 97) and the
`cur_invalid` logic. README line 200.

**Problem:** the original beat-address calculation truncated at the minimum
address width, allowing a burst to wrap into address zero.

**Fix:** beat-address arithmetic now uses a widened intermediate value and
checks the carry before narrowing. The direct core test drives a two-beat
burst from address 60 in a 64-byte memory and verifies the first beat is
`OKAY` while the second is zero-data `SLVERR`. The complete m20 regression
passes.

---

## 5. Synthesis defaults are impractical - OPEN

**Where:** `rtl/axi_mem_store_core.vhd`, `make_rdata` (line 133), called at
lines 265, 292 and 311. README line 254.

**Problem:**
- The memory is read asynchronously, `GC_DATA_BYTES` bytes wide.
- `make_rdata` is called for a new AR (lines 265 and 292) and for the next
  beat (line 311), with different addresses. That creates two such read ports.
- With the top-level defaults (16 KiB, 64-byte beats) that is roughly 128 k
  flip-flops plus very large multiplexers.

**Proposed fix:**
- Select the address first and call `make_rdata` once (see item 7).
- Either make the synthesis-top defaults small, or add an explicit README
  warning with a realistic size limit.

---

## 6. Core `ar_ready` is high during reset - DONE

**Where:** `rtl/axi_mem_store_core.vhd` line 254.

**Problem:** in `S_WAIT_AR`, `ar_ready` was `'1'` even while `aresetn = '0'`.
`mem_wr_ready` was gated by reset, so the two ports behaved differently.

**Fix:** `ar_ready <= aresetn` in `S_WAIT_AR`, matching `mem_wr_ready`.
The direct-core reset checks pass in `axi_mem_store_tb`.

---

## 7. Burst-start code is duplicated - DONE

**Where:** `rtl/axi_mem_store_core.vhd`, `S_WAIT_AR` (line 250 onward) and the
last-beat branch of `S_SEND_BEATS` (line 272 onward).

**Problem:** the same burst initialization assignments were written twice.

**Fix:** a local `p_start_burst` procedure now initializes both burst-entry
paths. The m20 regression passes after the refactor.

---

## 8. Memory size vs. beat size is not asserted - DONE

**Where:** `rtl/axi_mem_store_core.vhd`, assertions around line 203.

**Problem:** the README says `GC_MEM_SIZE_BYTES` must be a multiple of
`GC_DATA_BYTES`, but nothing enforced it. A non-multiple size silently made
the top of memory unreachable.

**Fix:** an elaboration assertion now rejects a non-integral number of native
data beats. Existing default and wide configurations pass the assertion.

---

## 9. `simple` testbench checks nothing - DONE

**Where:** `tb/axi_mem_store_simple_tb.vhd` line 71.

**Problem:** it previously wrote one byte and stopped: no read-back, no
assertion. It passed even if the DUT was broken.

**Fix:** it now writes the four bytes of `DEADBEEF`, reads one beat back, and
checks ID, data, response and `r_last`. The simple test passes on ModelSim and
as part of the XSim `axi_mem_store` regression.

---

## 10. Testbench nits - DONE

**Where:** `tb/axi_mem_store_tb.vhd`.

- The redundant `while ar_ready = '0'` loop was removed from
  `check_pending_ar_buffering`.
- The same procedure now checks the held R ID, data, response and last fields
  while two queued ARs are present.
- The two delta-cycle waits used for the registered write-error pulse are now
  named `wait_for_dut_update`, documenting why they do not advance time.

---

## 11. Missing test coverage - DONE

- **Done:** maximum-length burst (`ARLEN = 255`).
- **Done:** several ARs queued back to back, checking order, ID and the held
  R payload.
- **Done:** added the VS Code task `Run axi_mem_store xsim (all modes)` and
  documented the three XSim commands in the README. XSim was not run during
  this task because the active instruction prohibited running Vivado.

---

## 12. `axis_latency_gen` README claims a check that doesn't exist - DONE

**Where:** `axis_latency_gen/README.md` lines 48 and 225.

**Problem:** the README says an unsafe `base_delay` (at or above half the
timer range) reports a configuration error with severity failure. The RTL
contains no assertions at all.

**Fix:** the README now states the actual contract: the RTL does not perform
the claimed run-time assertion, so integrators must keep the configured delay
and jitter below the timer half-range.

---

## 13. Queued entries behind a stalled head can be delayed - DOCUMENTED LIMIT

**Where:** `axis_latency_gen/rtl/axis_latency_gen.vhd`.

**Problem:** the item 1 fix covers the entry at the head of the queue. An
entry queued behind a long-stalled head can reach the head more than
2^(GC_TIMER_WIDTH-1) cycles after its own departure time. It is then seen as
"not yet due" and waits up to 2^(GC_TIMER_WIDTH-1) extra cycles.

**Impact:** added latency only; the handshake is never broken.

**Why not fixed:** a complete fix needs logic per queue entry, which isn't
possible while `axis_fifo` stays a separate block.

**Current mitigation:** documented in the `axis_latency_gen` README ("Long
output stalls"). Choose `GC_TIMER_WIDTH` so output stalls stay well below
2^(GC_TIMER_WIDTH-1) cycles (32768 with the default 16 bits).

---

## 14. `axi_mem_model` has the same non-AXI unaligned mapping - DONE

**Where:** `axi_mem_model/rtl/axi_mem_model_core.vhd`, `beat_addr` and
`make_rdata`.

**Problem:** found while fixing item 2. `axi_mem_model` builds each beat from
the unaligned start address, exactly as `axi_mem_store` did before item 2. The
two memory models now differ for unaligned reads. `axi_read_tester` is
unaffected because it issues only aligned reads.

**Fix:** `axi_mem_model_core` now aligns each burst start using the same
`aligned_beat` rule as `axi_mem_store_core`. Its testbench adds an unaligned
read at address `0x1001` and expects the aligned `0x1000` data window.
The full ModelSim regression passes.

---

## 15. `axis_latency_gen` emits startup metavalue warnings - DONE

**Where:** `axis_latency_gen/rtl/axis_latency_gen.vhd`, `time_arrived` and
the two `axi_mem_store` latency-generator instances.

**Observation:** the ModelSim wide `axi_mem_store` test passes, but reports:

```text
NUMERIC_STD.">=": metavalue detected, returning FALSE
```

at startup in both the AR and R latency generators. The FIFO output timestamp
is not yet valid, but the signed timer comparison is still evaluated. This is
nonfatal because `ff_valid` is low, but it makes the regression noisy.

**Fix:** timestamp evaluation is now gated inside a VHDL function, so the
comparison is not evaluated while the FIFO output is invalid. The full
ModelSim regression passes without the previous startup warnings.

---

## Suggested order

1. **Items 7, 5 and 6** together: they touch the same core code.
2. **Items 4 and 8:** address and size checks.
3. **Items 3, 9, 10 and 11:** testbench work.
4. **Items 3, 5, 10 and 11**, which remain open.
