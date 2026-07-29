# jitter_gen — CDF-Based Jitter Generator

Combines a selectable internal PRNG (xorshift32 or xorshift128) with a CDF
comparator to produce non-uniform jitter values. On each `step` pulse, the
internal PRNG advances and the lowest 8 bits are compared against configurable
thresholds.

Licensed under Zero-Clause BSD (0BSD).

## Features

- **Selectable built-in PRNG** — xorshift32 or xorshift128, chosen by
  commenting/uncommenting the instantiation in `rtl/jitter_gen.vhd`.
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
| `GC_JITTER_WIDTH` | positive | 16 | Width of output jitter value |
| `GC_SEED` | std_logic_vector(31:0) | x"DEADBEEF" | PRNG seed (xorshift32) |
| `GC_SEED0` | std_logic_vector(63:0) | x"DEADBEEFCAFEBABE" | PRNG seed 0 (xorshift128) |
| `GC_SEED1` | std_logic_vector(63:0) | x"0123456789ABCDEF" | PRNG seed 1 (xorshift128) |
| `GC_VAL_0` | integer | 0 | Jitter value when slice < GC_TH_0 |
| `GC_VAL_1` | integer | 1 | Jitter value when slice < GC_TH_1 |
| `GC_VAL_2` | integer | 5 | Jitter value when slice < GC_TH_2 |
| `GC_VAL_3` | integer | 20 | Jitter value when slice >= GC_TH_2 |
| `GC_TH_0` | integer | 128 | First threshold (8-bit, 0–255) |
| `GC_TH_1` | integer | 192 | Second threshold (must be > GC_TH_0) |
| `GC_TH_2` | integer | 240 | Third threshold (must be > GC_TH_1) |

### Ports

| Port | Direction | Width | Description |
|------|-----------|-------|-------------|
| `clk` | in | 1 | System clock |
| `rstn` | in | 1 | Synchronous reset (active low) |
| `step` | in | 1 | Pulse high to advance PRNG and update jitter |
| `enable` | in | 1 | Gating; output held at 0 when low |
| `jitter` | out | GC_JITTER_WIDTH | Selected unsigned jitter value |

## Architecture

One of two PRNGs is instantiated internally (selectable by commenting/
uncommenting in the source):

- **xorshift32** — 32-bit state, single seed `GC_SEED`, 32-bit output (lower
  8 bits used for CDF comparison).
- **xorshift128** — 128-bit state, two 64-bit seeds `GC_SEED0`/`GC_SEED1`,
  64-bit output (lower 8 bits used for CDF comparison).

On each `step` pulse, the PRNG advances and its lowest 8 bits are compared
against three cumulative thresholds. The `enable` port gates the output:
when low, `jitter` is forced to zero regardless of `step`.

A synthesis wrapper (`jitter_gen_top.vhd`) exposes both seeds unconditionally
for top-level instantiation.

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
