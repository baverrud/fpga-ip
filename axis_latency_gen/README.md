# axis_latency_gen — AXI-Stream Latency Generator

Pipeline module that inserts configurable per-entry delay with CDF-based
jitter between AXI-Stream slave and master interfaces.

Licensed under Zero-Clause BSD (0BSD).

## Features

- **Configurable base delay** — Runtime `base_delay` input port,
  adjustable without re-synthesis.
- **Per-entry jitter** — Uses `jitter_gen` CDF-based PRNG jitter, sampled
  at entry time on the write side.
- **Single wider `axis_fifo`** — Stores `{tdata, t_departure}` together,
  no sync risk between parallel FIFOs.
- **Timer-wrap safe** — Same-width modular subtraction interpreted as signed,
  `signed(timer - t_departure) >= 0`, handles rollover correctly when max
  delay is < half the timer range.
- **AXI-Stream compliant** — Standard `tvalid`/`tready` handshake on both
  slave and master sides.

## Interface

### Generics

| Generic | Type | Default | Description |
|---------|------|---------|-------------|
| `GC_DATA_WIDTH` | positive | 32 | Width of TDATA on both AXI-Stream interfaces |
| `GC_FIFO_DEPTH` | positive | 16 | Depth of internal FIFO (entries) |
| `GC_TIMER_WIDTH` | positive | 32 | Width of internal global timer and `base_delay` |
| `GC_JG_SEED` | slv(31:0) | x"DEADBEEF" | Jitter generator PRNG seed (xorshift32) |
| `GC_JG_SEED0` | slv(63:0) | x"DEADBEEFCAFEBABE" | Jitter gen seed 0 (xorshift128) |
| `GC_JG_SEED1` | slv(63:0) | x"0123456789ABCDEF" | Jitter gen seed 1 (xorshift128) |
| `GC_JG_VAL_0` | integer | 0 | Jitter value when slice < GC_JG_TH_0 |
| `GC_JG_VAL_1` | integer | 1 | Jitter value when slice < GC_JG_TH_1 |
| `GC_JG_VAL_2` | integer | 5 | Jitter value when slice < GC_JG_TH_2 |
| `GC_JG_VAL_3` | integer | 20 | Jitter value when slice >= GC_JG_TH_2 |
| `GC_JG_TH_0` | integer | 128 | First CDF threshold |
| `GC_JG_TH_1` | integer | 192 | Second CDF threshold |
| `GC_JG_TH_2` | integer | 240 | Third CDF threshold |

### Ports

| Port | Direction | Width | Description |
|------|-----------|-------|-------------|
| `aclk` | in | 1 | Clock (AMBA naming) |
| `aresetn` | in | 1 | Synchronous reset, active low |
| `s_axis_tdata` | in | GC_DATA_WIDTH | Slave AXI-Stream data |
| `s_axis_tvalid` | in | 1 | Slave valid |
| `s_axis_tready` | out | 1 | Slave ready (FIFO backpressure) |
| `m_axis_tdata` | out | GC_DATA_WIDTH | Master AXI-Stream data |
| `m_axis_tvalid` | out | 1 | Master valid (gated by time) |
| `m_axis_tready` | in | 1 | Master ready (downstream backpressure) |
| `base_delay` | in | GC_TIMER_WIDTH | Base delay added to every entry |
| `fifo_count` | out | unsigned | FIFO occupancy |

## Architecture

```
  S_AXIS ──┬──► [timer + base + jitter] ──► FIFO({data, t_depart})
           │                                        │
           └──► jitter_gen (step on write)           ▼
                                              [signed(timer - t) >= 0?]
                                                        │
                                                        ▼
                                                     M_AXIS
```

### Write path (entry)

On `s_axis_tvalid & s_axis_tready`:
1. Step `jitter_gen` → get random jitter value
2. Compute `t_departure = global_timer + base_delay + jitter`
3. Push `{s_axis_tdata, t_departure}` into the wider `axis_fifo`

### Read path (dispatch)

When FIFO not empty and `signed(global_timer - head.t_departure) >= 0`:
1. Pop FIFO, split `{data, timestamp}`
2. Drive `m_axis_tdata`, assert `m_axis_tvalid` (gated by `m_axis_tready`)

### Timer wrap (deep dive)

The timer is an unsigned counter. With the default 32-bit width it counts from
0 to 4,294,967,295 and then wraps back to 0. The departure timestamp is also
stored in the same modulo-2^N range.

The correct wrap-safe comparison is **same-width modular subtraction**, then
interpret the result as signed:

```vhdl
v_time_diff <= signed(global_timer - t_departure);
release     <= (v_time_diff >= 0);
```

The subtractor bits are the same whether the result is viewed as `unsigned` or
`signed`; the important part is the **interpretation**. The MSB of the
same-width subtract result tells us whether the departure time is still in the
future:

| Result MSB | Signed meaning | Action |
|---|---|---|
| `0` | zero or positive | Release |
| `1` | negative | Wait |

So this would be equivalent in hardware:

```vhdl
v_time_diff <= global_timer - t_departure;  -- unsigned bits
release     <= not v_time_diff(GC_TIMER_WIDTH-1);
```

The RTL keeps `v_time_diff` as `signed` because `v_time_diff >= 0` documents
the intent directly: negative means "not yet", non-negative means "arrived".

Do **not** zero-extend the operands before subtracting. Zero-extension turns
the comparison into a normal unsigned magnitude comparison, which releases too
early when `t_departure` has wrapped to a small value and `global_timer` is
still near the maximum value.

#### Example with an 8-bit timer

Use an 8-bit timer so the numbers are small. The timer counts 0..255.

Write an entry at timer = 250 with delay = 10:

```
t_departure = 250 + 10 = 260 mod 256 = 4
```

Before the wrap, while timer = 251:

```
global_timer - t_departure = 251 - 4 = 247
247 as signed(8-bit) = -9
```

Negative means "not yet", so the entry waits. That is correct: timer still
has to pass 252, 253, 254, 255, 0, 1, 2, 3, then 4.

At timer = 4:

```
global_timer - t_departure = 4 - 4 = 0
0 as signed(8-bit) = 0
```

Zero means "arrived", so the entry is released.

#### Why zero-extension is wrong

If the comparison used 9-bit zero-extension instead:

```
signed('0' & 251) - signed('0' & 4) = +247
```

Positive means "arrived", so the entry would release immediately at timer
251, before the counter has wrapped. That is wrong.

#### Safety limit

This modular signed-difference method is valid only when the maximum delay is
less than half the timer range:

```
base_delay + jitter < 2^(GC_TIMER_WIDTH-1)
```

Why half? Because modulo time has two possible directions around the circle.
For an 8-bit timer, a difference of 10 clearly means "10 cycles in the
future", but a difference of 200 could also look like "56 cycles in the
past". Keeping all delays below half the range removes that ambiguity.

With `GC_TIMER_WIDTH = 32`, the safe maximum is 2^31 cycles. At 100 MHz,
that is about 21.5 seconds, far beyond the intended latency range for this
IP.

### Corner cases

| Scenario | Behavior |
|---|---|
| **FIFO empty** | `ff_valid = '0'`. `ff_ready` stays low, `m_axis_tvalid` stays low. No pop, no spurious output. |
| **FIFO full** | `tf_ready = '0'`, reflected to `s_axis_tready = '0'`. Upstream sees backpressure. |
| **`base_delay = 0`** | Delay is purely from jitter. `t_departure` may be <= current timer if jitter also = 0. |
| **Jitter = 0** | Possible when CDF thresholds route to `GC_VAL_0 = 0`. Still valid — pass-through with only base delay. |
| **`t_departure` in the past** | `v_time_diff >= 0` immediately. Entry dispatched on the next read cycle. |
| **`m_axis_tready` deasserted** | `ff_ready` blocked. Entry sits at FIFO head, `v_time_diff` continues to grow. Dispatched as soon as downstream is ready. |
| **Simultaneous write + read** | Independent write/read paths on single clock. FIFO handles concurrent push and pop. |
| **Write burst faster than dispatch** | FIFO fills up. When full, `s_axis_tready` deasserts, gating further writes. |
| **Back-to-back writes** | Each gets its own `jitter_gen` sample (stepped on each accepted write). Independent departure times. |
| **`aresetn` during operation** | Timer resets to 0. FIFO and `jitter_gen` reset. All in-flight entries discarded. |
| **Timer wraps mid-queue** | Same-width modular subtraction keeps the entry waiting until the wrapped timer reaches `t_departure`. No premature release. |
| **Max delay exceeded** | Ambiguous if `base_delay + jitter >= 2^(GC_TIMER_WIDTH-1)`. At `GC_TIMER_WIDTH=32` and 100 MHz: safe delay range is < 21.5 s. |

## File Structure

```
axis_latency_gen/
├── README.md
├── rtl/
│   ├── axis_latency_gen.vhd     — Main RTL
│   └── axis_latency_gen_top.vhd — Synthesis wrapper
├── scripts/
│   └── vhdl.f
└── tb/
    └── axis_latency_gen_tb.vhd  — Testbench
```

## Verification

Before running, initialize your EDA tool environment. Then, from the fpga-ip
root:

```
run axis_latency_gen all
```
