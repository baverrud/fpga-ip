# axi_ar_mux Review

> This review describes revision 1.01, where credit was charged at grant
> time. Revision 2.00 charges credit when a request is accepted and removes
> `f_fits_live`, `f_clamp_beats`, `f_eligible` and the registered grant; see
> `AR_MUX_ARCHITECTURE.md`. The debug checklist below still applies.

## Summary

The credit system is the main source of complexity in `axi_ar_mux`, but it is
not the only reason the RTL may appear to produce no AR output. The design
combines four mechanisms:

1. Per-client beat-credit accounting.
2. One request buffer per client.
3. A registered round-robin grant.
4. An active AR slot plus one pending AR slot.

The result is intentional backpressure and a registered request-to-AR
pipeline. A request is not transferred to the downstream AR channel on the
same edge that it is accepted from a client.

No functional defect was identified from the reported symptom. The most likely
causes are misunderstanding the two-cycle pipeline, holding `ar_ready` low,
not holding `req_valid` until handshake, or presenting a burst larger than the
available credit depth.

## Request-to-AR Timing

For an eligible request with downstream `ar_ready = '1'`:

```text
Edge N     req_valid & req_ready handshake
           Request is captured into the client buffer.

Edge N+1   Registered grant is placed in the active AR slot.
           ar_valid and the AR payload become visible after this edge.

Edge N+2   ar_valid & ar_ready handshake
           The AR transaction transfers downstream.
```

Therefore, observing no `ar_valid` on the same edge as the `req_valid` /
`req_ready` handshake is expected. `ar_valid` is registered and held until
`ar_ready` accepts it.

When `ar_ready = '0'`, the active AR transaction remains valid and its payload
must remain stable. One additional transaction may be buffered in the pending
slot, but it is not presented until the active transaction transfers.

## Credit System

Each client starts with `GC_FIFO_DEPTH` beat credits. A request consumes
`req_len + 1` credits when it is granted. Credits return only through the
corresponding `r_pop` input, normally driven by the matching R-side FIFO or
`axi_r_demux`.

A request is eligible only when its complete beat count fits the client's
remaining credits. This protects the downstream response storage from
overflowing.

A single request larger than `GC_FIFO_DEPTH` can never be granted. Credits are
capped at `GC_FIFO_DEPTH`, and no `r_pop` can return credits before that
request is granted. The RTL reports this condition as a failure assertion.

## Function and Procedure Roles

The functions in `rtl/axi_ar_mux.vhd` are combinational helpers; they do not
emit AR transactions by themselves.

### `f_beats`

Converts AXI `ARLEN` to a beat count:

```text
beats = ARLEN + 1
```

### `f_clamp_beats`

Stores the beat count in a bounded client-buffer field. An oversized request
is represented by a sentinel value above the legal credit range, while the
request is separately rejected by the contract assertion.

### `f_fits_live`

Checks whether the post-grant credit value can accommodate the requested
burst. For narrow credit widths it first rejects nonzero upper `ARLEN` bits,
then compares the lower bits against the available credits.

### `f_sat_return`

Adds `GC_R_BEATS_PER_POP` credits for an `r_pop` pulse and saturates at
`GC_FIFO_DEPTH`. Saturation prevents erroneous extra pops from overflowing the
counter.

### `f_rr_grant_idx`

Scans the eligible-client vector after the current round-robin pointer and
returns the next client index. It selects fairly among eligible clients but
does not decide eligibility or manage credits.

### `f_eligible`

Builds the next eligible-client vector using the post-edge credit values and
post-accept client buffers. It also handles the special case where the client
whose grant was consumed presents a replacement request on the same edge.

### `p_retire` and `p_place`

These local procedures manage the active and pending AR slots:

- `p_retire` removes a transferred active request and promotes a pending one.
- `p_place` places a granted client request into either the active or pending
  slot.

The actual outputs are driven from the registered `r.active` record. The
combinational process computes `r_in`, and `p_reg` commits it on the next
clock edge.

## No-Output Debug Checklist

Check the following in this order:

1. **Reset:** `aresetn` is synchronously high after a rising edge. During reset,
   `req_ready` is forced low and the registered AR slot is cleared.
2. **Client handshake:** the source holds `req_valid`, `req_addr`, and
   `req_len` stable until `req_valid and req_ready` is true at a rising edge.
3. **Burst size:** `req_len + 1 <= GC_FIFO_DEPTH`.
4. **Downstream ready:** `ar_ready` is high, or the source understands that
   `ar_valid` will remain high while it is low.
5. **Credit returns:** the matching `r_pop(client)` is pulsed when the
   client's response FIFO actually pops a response beat.
6. **ID mapping:** `ar_id` is generated from the client index. The downstream
   R demux must route responses using the same ID mapping.
7. **Stable observation:** sample `ar_valid` after the clock edge, not only at
   the request acceptance edge. Check `ar_valid and ar_ready` for an actual
   downstream transfer.

## Verification Evidence

`tb/axi_ar_mux_tb.vhd` covers the relevant behavior:

- Reset behavior and initial `req_ready` state.
- First-request line rate after reset.
- Registered AR presentation and immediate handshake.
- AR locking while `ar_ready` is low.
- Credit exhaustion and recovery through `r_pop`.
- Round-robin fairness and wrap-around.
- One AR transfer per clock after pipeline fill.
- Mid-stream reset and watchdog deadlock detection.

The testbench's `p_send` procedure correctly holds `req_valid` until
`req_ready`, and its `p_wait_ar` procedure waits for the registered AR
presentation. This is the expected client-side usage model.

## Credit-Free Operation (Arbiter Only)

The arbiter and the credit system are separable. Credits exist for one
purpose: to bound the number of **in-flight beats** per client so the
per-client R storage (for example the elastic FIFOs in `axi_r_demux`) can
never overflow. AXI read has no R-side backpressure on AR, so once an AR is
accepted the downstream slave will produce its beats regardless of whether the
client can absorb them.

Dropping credits while keeping the arbiter is therefore valid only when
something else already bounds in-flight beats. That is a property of the
integration, not of the mux:

1. **Client-enforced limit.** Each client guarantees at most `D` beats in
   flight and the per-client R storage is at least `D`. Typical for a simple
   non-pipelined master that issues one request and waits for its burst.
2. **One outstanding request per client.** In-flight beats cannot exceed the
   largest single burst, and the R storage covers that burst length.
3. **R path can stall AR.** Not available on a shared AXI read channel,
   because stalling R for one client stalls every client.

If none of these holds - a client may pipeline several requests while its R
storage stays finite - then removing credits lets that client over-issue and
overflow its own response buffer. Note also that a credit-free arbiter does
not throttle the shared channel in aggregate: `ar_ready` bounds how many
requests the downstream accepts, not how many response beats are still in
flight. Aggregate AR backpressure is not a substitute for beat accounting.

### What "arbiter only" deletes

Removing credit tracking deletes:

- `GC_FIFO_DEPTH` and `GC_R_BEATS_PER_POP`
- the `r_pop` port
- `credit_cnt`, and the helpers `f_sat_return`, `f_fits_live`,
  `f_clamp_beats` and `f_beats`
- the `beats` field of the client buffer (it is used only by credit
  arithmetic)
- the request-size contract assertion

Eligibility then collapses to "a request is buffered, or a live refill is
present". The round-robin scan, the per-client buffers, the active/pending AR
pipeline and the registered AR output are unchanged, so the arbiter's
handshake and line-rate behavior survive the removal intact.

### Trade-off

- Simpler RTL, and the exact-credit loop currently identified as the critical
  path disappears, so the achievable clock should improve. The measured
  143 MHz ceiling is attributed to the credit check, round-robin scan and
  grant selection sharing one cycle.
- The upsize-ratio subtlety disappears too: `GC_R_BEATS_PER_POP` no longer
  has to match the R-side packing ratio.
- Safety changes from **structural** to **contractual**. Overflow prevention
  becomes an integration requirement documented by the user instead of a
  hardware guarantee, and a client that violates the contract corrupts data
  silently.

### Simplest safe middle ground

When full beat credits are unwanted but a pure client contract is too weak,
use **request-level** credits instead of **beat-level** credits: allow one
outstanding request per client, released by a per-client burst-complete
indication (for example a per-client `r_pop` asserted once per completed
burst, or a per-client `r_last`). The counter becomes one bit per client, and
`beats` and the upsize ratio are still not needed. Safety is preserved as long
as the per-client R storage holds one full burst, which is a much easier
constraint to meet and to state than a beat budget.

All three variants keep the same arbiter: only the eligibility predicate
changes.

## Conclusion

The credit system makes the module more difficult to understand because
request admission depends on future R-side storage capacity, not only on the
current AR output state. However, it is also the mechanism that prevents
response FIFO overflow.

For a first integration bring-up, use:

```text
r_pop    = '0'
ar_ready = '1'
req_valid held until req_ready
req_len  <= GC_FIFO_DEPTH - 1
```

Then confirm the basic AR path before adding multiple clients, long bursts,
or R-side credit returns. Once responses are actually being popped, connect
`r_pop` to the corresponding client FIFO events and verify that credits are
returned per the configured `GC_R_BEATS_PER_POP` ratio.
