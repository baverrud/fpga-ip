# axis_latency_gen Review Note

## Scope

This note records the current timing behavior of `rtl/axis_latency_gen.vhd`.
No RTL changes are made by this review.

Update: the RTL has since added `head_released`, which keeps a due head entry
valid until it is popped. Before that, an output stall longer than
2^(GC_TIMER_WIDTH-1) cycles dropped `m_axis_tvalid` without a handshake. See
the README section "Long output stalls".

## Current Behavior

For each accepted input transfer at timer value `T`, the generator computes and stores:

```text
`t_departure = T + 1 + base_delay + jitter`
```

The payload and departure timestamp are stored together in the internal FIFO. The FIFO head is released when the modular timer comparison reports that its timestamp has arrived.

This implements independent per-entry delay. It does not implement a guaranteed gap between output handshakes.

## Consequence for Consecutive Transfers

If entries arrive on consecutive cycles, their departure timestamps are also normally consecutive. A configured `base_delay` shifts the stream in time but does not spread the entries apart.

For example, with a base delay of three cycles:

| Entry | Arrival timer | Departure timer |
|---|---:|---:|
| 0 | 100 | 104 |
| 1 | 101 | 105 |
| 2 | 102 | 106 |

The output remains one transfer per cycle after the initial delay.

If the downstream interface is stalled, queued entries can become overdue. Once `m_axis_tready` returns, those entries may be released on consecutive cycles without the configured delay between them.

## Jitter Semantics

Jitter is sampled on the input side. The current jitter value is associated with the accepted entry and the new PRNG sample is used by a later entry. Jitter therefore varies each entry's absolute departure time; it does not directly define the interval between output handshakes.

## Use in axi_mem_model

The R-side instance in `axi_mem_model` is described as providing inter-beat gaps. With the current generator implementation, it provides per-beat output latency instead. It can delay the first R beat and can add different delays to individual beats, but it cannot guarantee a gap between consecutive R handshakes.

The AR-side use is consistent with the implemented behavior: it provides request-to-core delay with optional per-request jitter.

## Current Integration Recommendation

For the current memory-model wrappers, keeping the same `axis_latency_gen`
core on both the AR and R paths is sensible. It preserves one proven FIFO,
timer and jitter implementation, keeps the runtime control ports symmetric,
and avoids introducing a second timing primitive before a true output-pacing
contract is required.

The R-side controls should be documented as per-entry response latency and
jitter for now. They should not be described as guaranteed inter-beat or
interpacket gaps. A future gap-capable generator can be evaluated separately
once exact handshake-to-handshake spacing is needed.

## Deliberately Deferred Change

No redesign is made here. A future gap-capable generator or pacing mode would need to schedule the next release from the previous output handshake, for example:

```text
`next_release = previous_handshake + base_gap + jitter`
```

It would also need to hold the current output stable while `m_axis_tready = '0'`, and define whether the first transfer after idle uses an initial delay or only the normal gap rule.

## Recommended Verification Before Any Redesign

1. Measure the cycle of each input handshake and output handshake.
2. Verify that current `base_delay` shifts output timing without changing full-rate spacing.
3. Fill the FIFO, stall the output, then verify that overdue entries drain without guaranteed spacing.
4. Record the jitter sequence and compare it with entry departure times.
5. Keep the AR latency use case separate from any future R-side pacing requirement.
