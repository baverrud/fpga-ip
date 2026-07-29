# Parallel PRNG — Xorshift Pseudo-Random Number Generators

Collection of lightweight pseudo-random number generators (PRNGs) for FPGA
implementation. All use the xorshift family of algorithms — pure XOR and shift
operations, no multipliers needed. Single-clock iteration with `step` gating.

Licensed under Zero-Clause BSD (0BSD).

## Features

- **Xorshift algorithms** — Pure XOR and shift, zero DSP blocks.
- **Single-cycle iteration** — New value every clock when `step` is tied high.
- **No external dependencies** — Only IEEE standard libraries.
- **Two implementations** — 32-bit xorshift32 (Marsaglia 2003) and 64-bit
  xorshift128 (xoroshiro128+, Vigna 2016).
- **Synthesis top wrapper** — `prng_top` instantiates both with independent
  step controls.

## Interface

### Generics

#### xorshift32

| Generic | Type | Default | Description |
|---------|------|---------|-------------|
| `GC_SEED` | `std_logic_vector(31 downto 0)` | `x"DEADBEEF"` | Reset seed value |

#### xorshift128

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

#### xorshift128

| Port | Direction | Width | Description |
|------|-----------|-------|-------------|
| `clk` | in | 1 | System clock |
| `rstn` | in | 1 | Synchronous reset (active low) — loads seed pair |
| `step` | in | 1 | Pulse high to advance one iteration |
| `data` | out | 64 | Current PRNG output value |

Tie `step` to `'1'` for free-running operation (new value every cycle).
Drive `step` with a qualified enable for gated operation.

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

### xorshift128

Single-clock process with two 64-bit state registers (s0, s1):

```
s1 ^= s0;
s0 = rotl(s0, 24) ^ s1 ^ (s1 << 16);
s1 = rotl(s1, 37);
result = s0 + s1;
```

| Property | Value |
|----------|-------|
| **Reference** | D. Blackman & S. Vigna, "Scrambled linear pseudorandom number generators", ACM Trans. Math. Soft., 2021 |
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
│   ├── xorshift128.vhd      # xoroshiro128+ (Vigna 2016), 64-bit
│   └── prng_top.vhd         # Synthesis top — instantiates both
├── scripts/
│   └── vhdl.f               # File list for sim/synth flows
└── tb/
    └── parallel_prng_tb.vhd # Testbench for both modules
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
