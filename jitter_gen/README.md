# jitter_gen — CDF-Based Jitter Generator

Combines a selectable internal PRNG (xorshift32 or xorshift128) with a CDF
comparator to produce non-uniform jitter values. On each `step` pulse, the
internal PRNG advances and the lowest 8 bits of its output are compared against
configurable cumulative thresholds to select one of four jitter output values.

Typical use case: injecting non-uniform timing jitter into delay generators
(e.g., `axis_latency_gen`) to model real-world DRAM or interconnect behaviour
where small delays are common and large outliers are rare.

Licensed under Zero-Clause BSD (0BSD).

## Features

- **Selectable built-in PRNG** — xorshift32 or xorshift128, chosen via the
  `GC_USE_XORSHIFT128` generic (no source-code editing needed).
- **CDF-based distribution** — Configurable thresholds shape the probability
  density of each jitter value.
- **4 jitter buckets** — Three thresholds split the 0–255 range into four
  zones, each with a configurable output value.
- **Enable gating** — `enable = '0'` forces output to zero, independent of
  `step`.
- **Elaboration-time safety checks** — Assertions verify thresholds are
  strictly ascending and fit within 8 bits.

## Interface

### Generics

| Generic | Type | Default | Description |
|---------|------|---------|-------------|
| `GC_JITTER_WIDTH` | positive | 16 | Width of output `jitter` port (unsigned) |
| `GC_USE_XORSHIFT128` | boolean | false | PRNG selection: `false` = xorshift32, `true` = xorshift128 |
| `GC_SEED` | slv(31:0) | x"DEADBEEF" | xorshift32 seed (ignored when `GC_USE_XORSHIFT128=true`) |
| `GC_SEED0` | slv(63:0) | x"DEADBEEFCAFEBABE" | xorshift128 seed 0 (ignored when `GC_USE_XORSHIFT128=false`) |
| `GC_SEED1` | slv(63:0) | x"0123456789ABCDEF" | xorshift128 seed 1 (ignored when `GC_USE_XORSHIFT128=false`) |
| `GC_VAL_0` | integer | 0 | Jitter value when `slice < GC_TH_0` (~50% probability) |
| `GC_VAL_1` | integer | 1 | Jitter value when `slice < GC_TH_1` (~25% probability) |
| `GC_VAL_2` | integer | 5 | Jitter value when `slice < GC_TH_2` (~19% probability) |
| `GC_VAL_3` | integer | 20 | Jitter value when `slice >= GC_TH_2` (~6% probability) |
| `GC_TH_0` | integer | 128 | First CDF threshold (0–255, must be < GC_TH_1) |
| `GC_TH_1` | integer | 192 | Second CDF threshold (must be > GC_TH_0, < GC_TH_2) |
| `GC_TH_2` | integer | 240 | Third CDF threshold (must be > GC_TH_1, < 256) |

### Ports

| Port | Direction | Width | Description |
|------|-----------|-------|-------------|
| `clk` | in | 1 | System clock |
| `rstn` | in | 1 | Synchronous reset (active low) |
| `step` | in | 1 | Pulse high to advance PRNG and update jitter |
| `enable` | in | 1 | Gating; output held at 0 when low |
| `jitter` | out | GC_JITTER_WIDTH | Selected unsigned jitter value |

## Architecture

One of two PRNGs is instantiated internally, selected by the
`GC_USE_XORSHIFT128` generic:

- **xorshift32** (`false`) — 32-bit state, single seed `GC_SEED`, 32-bit output.
  Lower 8 bits used for CDF comparison.
- **xorshift128** (`true`) — 128-bit state, two 64-bit seeds `GC_SEED0`/`GC_SEED1`,
  64-bit output. Lower 8 bits used for CDF comparison.

On each `step` pulse, the selected PRNG advances and its lowest 8 bits are
compared against three cumulative thresholds. The `enable` port gates the
output — when low, `jitter` is forced to zero regardless of `step`.

A synthesis wrapper (`jitter_gen_top.vhd`) passes all generics through for
top-level instantiation.

**CDF (Cumulative Distribution Function)** — the 8-bit random value (0–255)
is used as a probability axis. Each threshold divides the range into segments
whose widths determine the probability of each output value:

```
0              128             192          240     255
├─────50%──────┼──────25%──────┼────19%─────┼──6%──┤
    GC_VAL_0       GC_VAL_1      GC_VAL_2    GC_VAL_3
```

Each threshold is the cumulative sum of probabilities before it:

| Condition | Probability | Output |
|-----------|-------------|--------|
| `slice < GC_TH_0` (e.g. < 128) | 128/255 ≈ 50% | `GC_VAL_0` |
| `slice < GC_TH_1` (e.g. < 192) | 64/255  ≈ 25% | `GC_VAL_1` |
| `slice < GC_TH_2` (e.g. < 240) | 48/255  ≈ 19% | `GC_VAL_2` |
| `slice >= GC_TH_2` | 15/255  ≈ 6%  | `GC_VAL_3` |

Elaboration-time assertions catch invalid threshold configurations (not
strictly ascending or out of range).

## File Structure

```
jitter_gen/
├── README.md
├── rtl/
│   ├── jitter_gen.vhd        — Core CDF jitter generator
│   └── jitter_gen_top.vhd    — Synthesis wrapper (exposes all generics)
├── scripts/
│   └── vhdl.f
└── tb/
    └── jitter_gen_tb.vhd
```

## Verification

Before running, initialize your EDA tool environment. Then, from the fpga-ip
root:

```
run jitter_gen all
```
