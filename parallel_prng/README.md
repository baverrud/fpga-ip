# Parallel PRNG — Xorshift and xoroshiro Pseudo-Random Number Generators

Collection of lightweight pseudo-random number generators (PRNGs) for FPGA
implementation. The collection contains Marsaglia xorshift32 and xoroshiro128+.
Both use XOR, shift/rotate, and addition operations only. Single-clock
iteration with `step` gating.

Licensed under Zero-Clause BSD (0BSD).

## Features

- **Lightweight algorithms** — XOR, shift/rotate, and addition; zero DSP blocks.
- **Single-cycle iteration** — New value every clock when `step` is tied high.
- **No external dependencies** — Only IEEE standard libraries.
- **Two implementations** — 32-bit xorshift32 (Marsaglia 2003) and 64-bit
  xoroshiro128+ (Blackman and Vigna).
- **Synthesis top wrapper** — `prng_top` instantiates both with independent
  step controls.

## Interface

### Generics

#### xorshift32

| Generic | Type | Default | Description |
|---------|------|---------|-------------|
| `GC_SEED` | `std_logic_vector(31 downto 0)` | `x"DEADBEEF"` | Reset seed value |

#### xoroshiro128+

| Generic | Type | Default | Description |
|---------|------|---------|-------------|
| `GC_SEED0` | `std_logic_vector(63 downto 0)` | `x"DEADBEEFCAFEBABE"` | First 64-bit seed |
| `GC_SEED1` | `std_logic_vector(63 downto 0)` | `x"0123456789ABCDEF"` | Second 64-bit seed |

### Ports

#### xorshift32

| Port | Direction | Width | Description |
|------|-----------|-------|-------------|
| `clk` | in | 1 | System clock |
| `rstn` | in | 1 | Synchronous reset (active low) — loads `GC_SEED` |
| `step` | in | 1 | Pulse high to advance one iteration |
| `data` | out | 32 | Current PRNG output value |

#### xoroshiro128+

| Port | Direction | Width | Description |
|------|-----------|-------|-------------|
| `clk` | in | 1 | System clock |
| `rstn` | in | 1 | Synchronous reset (active low) — loads seed pair |
| `step` | in | 1 | Pulse high to advance one iteration |
| `data` | out | 64 | Current PRNG output value |

For xoroshiro128+, `data` is the live `s0 + s1` sum modulo $2^{64}`;
therefore the initial output is `GC_SEED0 + GC_SEED1` before the first step.
Tie `step` to `'1'` for free-running operation, or drive it with a qualified
enable for gated operation.

## Architecture

### xorshift32

Single-clock process with a single 32-bit state register `x`:

```
x ^= x << 13;
x ^= x >> 17;
x ^= x << 5;
```

| Property | Value |
|----------|-------|
| **Reference** | G. Marsaglia, "Xorshift RNGs", J. Stat. Soft. **8**(14), 2003 |
| **State** | 32-bit register |
| **Output** | 32-bit |
| **Period** | 2³² − 1 |

Smallest PRNG in the collection. Suitable for simple addressing or basic
randomization. Not suitable for cryptographic or numerical simulation use.

### xoroshiro128+

Single-clock process with two 64-bit state registers (s0, s1):

```
s1 ^= s0;
s0 = rotl(s0, 24) ^ s1 ^ (s1 << 16);
s1 = rotl(s1, 37);
result = s0 + s1;
```

| Property | Value |
|----------|-------|
| **Reference** | [Official xoroshiro128+ reference implementation](https://prng.di.unimi.it/xoroshiro128plus.c) |
| **State** | 128-bit (2 × 64-bit registers) |
| **Output** | 64-bit |
| **DSP blocks** | 0 |
| **Period** | 2¹²⁸ − 1 |
| **Statistical** | Passes Crush, fails BigCrush |

Rotates are free in hardware (wire reordering). The only arithmetic is one
64-bit addition — no DSP blocks consumed. Good general-purpose choice for
numerical simulation and address generation.

### prng_top

Synthesis wrapper that instantiates both modules with independent step
controls. Exposes `step32`/`data32` and `step128`/`data128` ports.
Tie a step high for free-running operation of that generator.

## File Structure

```
parallel_prng/
├── README.md
├── rtl/
│   ├── xorshift32.vhd       # Marsaglia xorshift32 (2003), 32-bit
│   ├── xorshift128.vhd      # xoroshiro128+ (Blackman/Vigna), 64-bit
│   └── prng_top.vhd         # Synthesis top — instantiates both
├── scripts/
│   └── vhdl.f               # File list for sim/synth flows
└── tb/
    └── parallel_prng_tb.vhd # Self-checking golden-sequence testbench
```

## Verification

Before running, initialize your EDA tool environment (e.g. ModelSim or
Vivado via the project's launcher scripts). Then, from the fpga-ip root:

```
run parallel_prng all
```

### Jitter-gen integration test

The `jitter_gen` IP can instantiate either PRNG and drive it through a
CDF comparator. Its testbench (`jitter_gen_tb`) runs 65536 samples and
reports bucket distribution — a useful real-world integration test for
the PRNG core:

```
run jitter_gen vhdl modelsim    # Uses xorshift32 (default)
run jitter_gen all              # All available tools
```

To test the other PRNG, comment/uncomment the instantiation in
`jitter_gen/rtl/jitter_gen.vhd` and re-run.
