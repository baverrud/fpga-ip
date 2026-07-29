# axi_mem_model — AXI4 Memory Latency Model

AXI4 read-slave that models DRAM-like first-beat latency and per-beat
inter-beat gaps. Delegates all timing to reusable `axis_latency_gen`
instances; the core module only handles burst sequencing and address-based
data generation.

The primary use case is to stand in for real DRAM (DDR4, LPDDR4, etc.)
when designing and verifying DMA engines, AXI interconnect, or other
memory-centric hardware — providing deterministic, repeatable timing
without the complexity and simulation cost of a full DRAM controller
model.

Licensed under Zero-Clause BSD (0BSD).

## Architecture

```
AR channel ──► axis_latency_gen ──► axi_mem_model_core ──► axis_latency_gen ──► R channel
                  (AR delay)           (beat sequencer)        (beat gap)
```

| Block | Role |
|-------|------|
| **AR-side `axis_latency_gen`** | Delays the AR request by `base_latency + jitter`. FIFO depth = `GC_AR_FIFO_DEPTH` for in-flight AR tracking. |
| **`axi_mem_model_core`** | Receives delayed AR info, tracks beat index, generates address-based read data patterns, packs per-beat response entries. |
| **R-side `axis_latency_gen`** | Delays each beat by `base_beat_gap + jitter`. FIFO depth configurable via `GC_R_FIFO_DEPTH` (default 8). The gen's internal timer provides inter-beat spacing; the core pushes beats at maximum rate (1 per cycle) and the gen buffers them for timed release. |

## Features

- **Configurable first-beat latency** — `base_latency` runtime port
- **Configurable inter-beat gap** — `base_beat_gap` runtime port
- **CDF-based jitter** — Internal to `axis_latency_gen`, 0-20 cycle spread
  by default (suitable for LPDDR4 modelling)
- **In-flight AR tracking** — AR-side FIFO depth limits concurrent requests
- **Zero-latency mode** — `enable=0` sets both delays to 0 for
  near-pass-through behaviour
- **Address-based data pattern** — Each R beat returns deterministic
  address-derived values sized to the configured bus width
  (see [Read Data Pattern](#read-data-pattern)).
- **All 2ⁿ data widths supported** — `GC_DATA_BYTES` accepts any power of
  two from 1 to 128 (n = 0..7), giving bus widths 8 to 1024 bits.
- **AXI3 compatible** — Uses only the subset common to AXI3 and AXI4
  (AR/R channels). AXI3's 4-bit `arlen` works; upper bits are ignored.

## Interface

### Generics

| Generic | Default | Description |
|---------|---------|-------------|
| `GC_DATA_BYTES` | 64 | Bus width in bytes. Supports 2ⁿ for n=0..7 (1, 2, 4, 8, 16, 32, 64, 128). |
| `GC_ADDR_WIDTH` | 49 | Address width |
| `GC_ID_WIDTH` | 6 | AXI ID width |
| `GC_AR_FIFO_DEPTH` | 8 | Max in-flight AR requests (AR-side FIFO depth) |
| `GC_TIMER_WIDTH` | 16 | Width of `base_latency` and `base_beat_gap` ports |
| `GC_R_FIFO_DEPTH` | 8 | R-side beat-gap FIFO depth. Only matters if the output is stalled (r_ready=0); during normal 1/cycle throughput the FIFO never exceeds a few entries. Minimum 2. |

### Ports

| Port | Direction | Width | Description |
|------|-----------|-------|-------------|
| `aclk` | in | 1 | Clock |
| `aresetn` | in | 1 | Synchronous reset, active low |
| `enable` | in | 1 | 0 = zero delays, 1 = configured delays |
| `base_latency` | in | GC_TIMER_WIDTH | Nominal first-beat delay (cycles) |
| `base_beat_gap` | in | GC_TIMER_WIDTH | Nominal inter-beat gap (cycles) |
| `ar_valid` | in | 1 | AR channel valid |
| `ar_ready` | out | 1 | AR channel ready |
| `ar_id` | in | GC_ID_WIDTH | Read address ID |
| `ar_addr` | in | GC_ADDR_WIDTH | Read address |
| `ar_len` | in | 8 | Burst length (number of beats - 1) |
| `r_valid` | out | 1 | R channel valid |
| `r_ready` | in | 1 | R channel ready |
| `r_id` | out | GC_ID_WIDTH | Read response ID |
| `r_data` | out | 8×DATA_BYTES | Read data |
| `r_resp` | out | 2 | Read response (OKAY = "00") |
| `r_last` | out | 1 | Last beat indicator |

### Omitted AR signals: `ar_size` and `ar_burst`

The standard AXI read address channel includes `ar_size` (AxSIZE) and
`ar_burst` (AxBURST), but neither is present on the `axi_mem_model`
interface. This is intentional — they are not needed for the model's
purpose as a DRAM simulator.

**`ar_size` — transfer width per beat (bytes = 2^arsize)**

In a real slave, `ar_size` controls byte-lane validity for narrow
transfers (e.g. `ar_size=2` means only 4 of the 64 data-byte lanes are
valid per beat). The model always drives the full bus width; there is no
byte-level masking. Since the intended use is DMA emulation (always
`ar_size = log2(bus_bytes)`), a narrower `ar_size` never occurs.

**`ar_burst` — addressing pattern across beats**

The three AXI burst types are:
- `FIXED (00)` — same address every beat (e.g. reading from a FIFO)
- `INCR  (01)` — address increments by `2^arsize` each beat
- `WRAP  (10)` — increments but wraps to a burst-aligned boundary

The model unconditionally increments the address by the data bus width
each beat, which is exactly INCR behaviour with `ar_size = log2(bus_bytes)`.
FIXED and WRAP are irrelevant for DRAM simulation (DRAM only does INCR).

**Upshot:** Adding `ar_size` and `ar_burst` as ignored/unconnected ports
would increase AXI protocol fidelity but would not change any behaviour.
They are omitted for simplicity.

## Timing

- **First-beat latency**: `base_latency + jitter` cycles from AR accept to
  first R beat valid
- **Inter-beat gap**: `base_beat_gap + jitter` cycles between consecutive
  R beats
- **Zero-latency**: With `enable=0` both delays are zeroed; pipeline
  depth adds a few cycles of unavoidable latency

## Read Data Pattern

Every R beat carries a deterministic, address-derived payload. The pattern
varies by bus width:

| GC_DATA_BYTES | Pattern | Description |
|:-:|---|---|
| ≥ 4 | 32-bit word-address | Each word `w` = `ar_addr[31:0] + w·4` |
| 2 | 16-bit address | `r_data[15:0] = ar_addr[15:0]` |
| 1 | 8-bit address | `r_data[7:0] = ar_addr[7:0]` |

### Four bytes and above (`GC_DATA_BYTES ≥ 4`)

Each 32-bit word in the data bus gets a 32-bit address value:

```
word w  =  ar_addr[31:0] + w·4        for w = 0, 1, …, GC_DATA_BYTES/4−1
```

Examples with `ar_addr = 0x76543210`:

| GC_DATA_BYTES | Beat 0 word breakdown |
|:-:|---|
| 4 | `r_data[31:0]` = 0x76543210 |
| 8 | word 1 = 0x76543214, word 0 = 0x76543210 |
| 16 | word 3 = 0x7654321C, …, word 0 = 0x76543210 |
| 32 | word 7 = 0x7654322C, …, word 0 = 0x76543210 |
| 64 | word 15 = 0x7654324C, …, word 0 = 0x76543210 |
| 128 | word 31 = 0x7654328C, …, word 0 = 0x76543210 |

### Two-byte buses (`GC_DATA_BYTES = 2`)

The 16-bit data value is simply the bottom 16 bits of the address:

| Beat (base addr) | `r_data[15:0]` |
|---|---|
| 0 (0x76543210) | `0x3210` |
| 1 (0x76543212) | `0x3212` |
| 2 (0x76543214) | `0x3214` |

### Single-byte buses (`GC_DATA_BYTES = 1`)

The 8-bit data value is the bottom 8 bits of the address:

| Beat (base addr) | `r_data[7:0]` |
|---|---|
| 0 (0x76543210) | `0x10` |
| 1 (0x76543211) | `0x11` |
| 2 (0x76543212) | `0x12` |

### Consecutive beats

Each burst beat advances the base address by `GC_DATA_BYTES`:

```
beat_N_base = ar_addr + N × GC_DATA_BYTES
```

Example with `GC_DATA_BYTES = 4`, `ar_addr = 0x76543210`:

| Beat | base addr | `r_data[31:0]` (word 0) |
|:-:|---|---|
| 0 | 0x76543210 | `0x76543210` |
| 1 | 0x76543214 | `0x76543214` |
| 2 | 0x76543218 | `0x76543218` |
| 3 | 0x7654321C | `0x7654321C` |

Each beat's word 0 equals its base address, providing a straight-forward
"address return" check in simulation.

## Internal Packed Data Formats

The core communicates with the latency generators via packed AXI-Stream buses.

### AR payload (`s_axis_tdata` on core)

```
[ar_id][araddr][ar_len]         — MSB to LSB
```

| Field | Width | Position |
|-------|-------|----------|
| `ar_len` | 8 | LSB |
| `araddr` | GC_ADDR_WIDTH | middle |
| `ar_id` | GC_ID_WIDTH | MSB |

### R payload (`m_axis_tdata` on core)

```
[r_id][rdata][r_resp][r_last]   — MSB to LSB
```

| Field | Width | Position |
|-------|-------|----------|
| `r_last` | 1 | LSB |
| `r_resp` | 2 | |
| `rdata` | 8 × GC_DATA_BYTES | middle |
| `r_id` | GC_ID_WIDTH | MSB |

## Throughput

The core pushes beats into the R-side `axis_latency_gen` at the maximum
rate (1 beat per clock cycle). The gen buffers them in a FIFO and releases
each beat after `base_beat_gap + jitter` cycles from its arrival time.

```text
Core output:   [beat0][beat1][beat2][beat3]...  (1/cycle, no gaps)
                       ↓
Gen internal:  FIFO (depth = GC_R_FIFO_DEPTH, buffers up to N beats)
                       ↓
R output:      ...gap...beat0...gap...beat1...beat2...  (spaced by base_beat_gap)
```

In steady state (after the first-beat latency), the R channel delivers
beats at 1/cycle with the configured inter-beat gap, provided
`r_ready` is continuously asserted. The gen's timer handles spacing;
the FIFO absorbs any mismatch between core push rate and output spacing.

Natural backpressure occurs if the FIFO fills: `m_axis_tready` drops,
the core stalls, and resumes when space is available.

## Testing

The IP ships with a self-checking testbench that exercises all
supported widths (1, 2, 4, 8, 16, 32, 64, 128 bytes) through the
following phases:

| Phase | Description |
|-------|-------------|
| Reset | Assert/deassert synchronous reset |
| P1 | Single-beat burst (len=0) |
| P2 | Short burst (len=3) |
| P3 | Mid burst (len=7) |
| P4 | Back-to-back AR requests |
| P5 | Zero-latency mode (enable=0) |
| P6 | Max burst (len=255, 256 beats) |
| P7 | FIFO-full AR backpressure |
| P8 | R-channel backpressure |
| P9 | Reset during active burst |

To run (after environment/tool setup):

```
# From the fpga-ip repo root:
run axi_mem_model vhdl modelsim
```

## Dependencies

| Dependency | Path |
|------------|------|
| `util_pkg` | `../common/rtl/util_pkg.vhd` |
| `axis_fifo` | `../axis_fifo/rtl/axis_fifo.vhd` (wrapped by `axis_latency_gen`) |
| `xorshift32` | `../parallel_prng/rtl/xorshift32.vhd` (wrapped by `jitter_gen`) |
| `jitter_gen` | `../jitter_gen/rtl/jitter_gen.vhd` (wrapped by `axis_latency_gen`) |
| `axis_latency_gen` | `../axis_latency_gen/rtl/axis_latency_gen.vhd` |
