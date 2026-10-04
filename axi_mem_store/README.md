# axi_mem_store - Real-Data AXI Memory Model

`axi_mem_store` is a simulation-only AXI3/AXI4-compatible read slave for
full-width INCR bursts, backed by a
parameterizable byte-addressed memory. Testbench or simulation logic populates
the memory through a clocked one-byte write interface. Reads return stored
values rather than an address-derived pattern.

The IP keeps the current serialized burst behavior: AR requests may be
buffered by the AR latency FIFO, but R responses are produced for one burst at
a time and are not interleaved across IDs.

## Start Here

Use `axi_mem_store` when a testbench needs a real byte store behind an AXI
read interface. Use `axi_mem_store_core` only when the enclosing testbench
already provides its own request and response timing. The IP is not
synthesizable: there is no synthesis top and no `[top]` manifest section.

For the simplest useful configuration:

1. Set `GC_MEM_SIZE_BYTES` to the required capacity.
2. Keep `ar_base_enable`, `ar_jitter_enable`, `r_base_enable`, and
   `r_jitter_enable` low until functional reads work.
3. Write bytes through `mem_wr_*` before issuing AR requests.
4. Drive `ar_len` as beats minus one. A single-beat read uses `ar_len = x"00"`.
5. Keep `r_ready` high for an unrestricted read stream, or deassert it to test
   response backpressure.

The external wrapper has two independent per-entry timing stages. AR timing
controls request delay; R timing controls response-entry delay. The R stage
delays each entry from its arrival, so it does not guarantee a fixed gap
between R handshakes; do not use `base_beat_gap` as a physical bandwidth
model.

### Minimal VHDL Usage

The following is the essential shape of an instance. The full port list is in
`rtl/axi_mem_store.vhd`.

```vhdl
u_mem : entity work.axi_mem_store
  generic map (
    GC_DATA_BYTES     => 4,
    GC_ADDR_WIDTH     => 32,
    GC_ID_WIDTH       => 4,
    GC_MEM_SIZE_BYTES => 16*1024
  )
  port map (
    aclk            => aclk,
    aresetn         => aresetn,
    ar_base_enable  => '0',
    ar_jitter_enable => '0',
    r_base_enable   => '0',
    r_jitter_enable => '0',
    base_latency    => (others => '0'),
    base_beat_gap   => (others => '0'),
    mem_wr_addr     => mem_wr_addr,
    mem_wr_data     => mem_wr_data,
    mem_wr_valid    => mem_wr_valid,
    mem_wr_ready    => mem_wr_ready,
    mem_wr_error    => mem_wr_error,
    ar_id           => ar_id,
    ar_addr         => ar_addr,
    ar_len          => ar_len,
    ar_valid        => ar_valid,
    ar_ready        => ar_ready,
    r_id            => r_id,
    r_data          => r_data,
    r_resp          => r_resp,
    r_last          => r_last,
    r_valid         => r_valid,
    r_ready         => r_ready
  );
```

For a testbench, the common `axis_bfm_pkg` can drive a packed helper stream;
the supplied testbenches show this through the local `mem_wr` procedure.

## Architecture

```text
AR -> axis_latency_gen -> axi_mem_store_core -> axis_latency_gen -> R
                         ^
                         |
                   byte write port
```

The shared `axis_latency_gen` remains unchanged and is used on both paths. It
supplies request-side and response-side per-entry latency and jitter. On the
R side it does not guarantee a fixed gap between output handshakes.

## Generics

| Generic | Default | Description |
|---|---:|---|
| `GC_DATA_BYTES` | 64 | AXI data width in bytes: 1, 2, 4, 8, 16, 32, 64 or 128. |
| `GC_ADDR_WIDTH` | 32 | Byte-address width. Minimum `log2ceil(GC_MEM_SIZE_BYTES)`, which is the width that reaches every byte. |
| `GC_ID_WIDTH` | 6 | AXI ID width. |
| `GC_TIMER_WIDTH` | 16 | Width of the AR and R latency controls (`base_latency`, `base_beat_gap`). |
| `GC_AR_FIFO_DEPTH` | 8 | AR latency FIFO depth. |
| `GC_R_FIFO_DEPTH` | 8 | R-side response latency FIFO depth. |
| `GC_MEM_SIZE_BYTES` | 16384 | Memory capacity, mapped from address zero. |

## Ports

| Port | Dir | Width | Description |
|---|---|---|---|
| `aclk` | in | 1 | Clock. |
| `aresetn` | in | 1 | Synchronous reset, active low. |
| `ar_base_enable` | in | 1 | Enables the AR base delay. |
| `ar_jitter_enable` | in | 1 | Enables AR jitter. |
| `r_base_enable` | in | 1 | Enables the R base delay. |
| `r_jitter_enable` | in | 1 | Enables R jitter. |
| `base_latency` | in | `GC_TIMER_WIDTH` | Nominal request-side delay in cycles. |
| `base_beat_gap` | in | `GC_TIMER_WIDTH` | Nominal response-side delay in cycles. |
| `mem_wr_addr` | in | `GC_ADDR_WIDTH` | Byte address to write. |
| `mem_wr_data` | in | 8 | Byte value to write. |
| `mem_wr_valid` | in | 1 | Write request. |
| `mem_wr_ready` | out | 1 | High when a write is accepted. |
| `mem_wr_error` | out | 1 | One-clock pulse when the write address is outside memory. |
| `ar_id` | in | `GC_ID_WIDTH` | Read address ID. |
| `ar_addr` | in | `GC_ADDR_WIDTH` | Read start byte address. |
| `ar_len` | in | 8 | Burst length minus one. |
| `ar_valid` | in | 1 | Read address valid. |
| `ar_ready` | out | 1 | Read address ready. |
| `r_id` | out | `GC_ID_WIDTH` | Read response ID. |
| `r_data` | out | `8*GC_DATA_BYTES` | Read data, little endian. |
| `r_resp` | out | 2 | `00` = OKAY, `10` = SLVERR. |
| `r_last` | out | 1 | Last beat of the burst. |
| `r_valid` | out | 1 | Read data valid. |
| `r_ready` | in | 1 | Read data ready. |

## Runtime ports

The timing ports match `axi_mem_model`:

- `ar_base_enable`, `ar_jitter_enable`, `base_latency` control request delay.
- `r_base_enable`, `r_jitter_enable`, `base_beat_gap` control per-entry R
  response latency and jitter.

When both R controls are disabled, the R stage passes data at its normal
pipeline rate. When jitter is enabled, a CDF-based jitter sample is drawn for
each accepted response entry.

## Memory population

The write port accepts one byte per clock:

| Port | Description |
|---|---|
| `mem_wr_addr` | Byte address from `0` through `GC_MEM_SIZE_BYTES - 1`. |
| `mem_wr_data` | Byte value to store. |
| `mem_wr_valid` | Write request. |
| `mem_wr_ready` | High when writes are accepted; low during reset. |
| `mem_wr_error` | One-clock pulse when an accepted write address is outside memory. |

A write is accepted when `mem_wr_valid` and `mem_wr_ready` are both high at a
rising clock edge. Memory contents are initialized to zero and are not cleared
by `aresetn`.

An accepted write at an address outside `0 .. GC_MEM_SIZE_BYTES-1` is ignored
and pulses `mem_wr_error` for the following clock interval. The error pulse is
cleared on the next rising edge. Writes presented during reset are not
accepted and do not pulse the error output.

The supplied testbenches use `common/rtl/axis_bfm_pkg.vhd` through a small
testbench-only adapter that packs `{mem_wr_addr, mem_wr_data}` into one
AXI4-Stream word. The adapter does not change the DUT interface; it lets the
shared `axis_write` procedure exercise the normal memory population handshake.

## Read behavior

Memory is byte addressed and little endian, and reads follow AXI INCR byte
lanes: the byte at address `A` is returned on lane `A mod GC_DATA_BYTES`,
i.e. in `r_data(8*b+7 downto 8*b)` with `b = A mod GC_DATA_BYTES`. Every beat
is the aligned `GC_DATA_BYTES` window that contains it. Burst beat `n` reads
the window at:

```text
aligned(ar_addr) + n * GC_DATA_BYTES
aligned(a) = a with its low log2(GC_DATA_BYTES) bits cleared
```

For an unaligned `ar_addr`, the first beat therefore also carries the bytes
below the start address on the lower lanes; an AXI master ignores those lanes.
There are no `ar_size` or `ar_burst` inputs: every transfer is a full-width
INCR beat.

A beat whose window is wholly inside memory returns `r_resp = "00"` (`OKAY`).
If any byte of the window lies outside the configured memory, the beat returns
zero data and `r_resp = "10"` (`SLVERR`). The error is communicated on the R
channel and `r_last` still follows the burst length.

Once a beat of a burst is out of range, every remaining beat of that burst is
also `SLVERR`. A beat address that would wrap at the top of the address space
is therefore never reported as `OKAY`.

## Latency semantics

AR latency is measured from acceptance of an AR transfer to delivery to the
core. The R-side value is applied as per-entry response latency:

```text
R departure = R entry arrival + pipeline + base latency + jitter
```

R-channel fields remain stable while `r_valid = '1'` and `r_ready = '0'`,
for any stall length.

## Verification

Run from the `fpga-ip` repository root after initializing ModelSim:

```text
run axi_mem_store vhdl modelsim
run axi_mem_store vhdl modelsim --tb simple
run axi_mem_store vhdl modelsim --tb wide
run axi_mem_store vhdl modelsim --tb all    # also runs w1 and w128
```

Run the same three testbenches with XSim (Vivado 2023.2) from the `fpga-ip`
root:

```text
call C:\Xilinx\Vivado\2023.2\settings64.bat
python tools\run.py axi_mem_store vhdl xsim
python tools\run.py axi_mem_store vhdl xsim --tb simple
python tools\run.py axi_mem_store vhdl xsim --tb wide
```

The VS Code task **Run axi_mem_store xsim (all modes)** runs this sequence.

The comprehensive testbench populates real byte values and checks endian
assembly, burst sequencing, boundary `SLVERR`, reset preservation,
backpressure (including a 300-cycle `r_ready` stall, longer than half the
8-bit latency timer), R-side latency control, the one-clock `mem_wr_error`
pulse and
out-of-range bursts that wrap at the top of the address space. It also
instantiates `axi_mem_store_core` directly, without the latency wrapper, to
check the minimum legal address width and the core's own AR lookahead
handshake.

The `simple` testbench is a minimal smoke test. The `wide` testbench runs the
full wrapper with a 49-bit address, a 6-bit ID and a 1 KiB memory at
`GC_DATA_BYTES = 64`; the `w1` and `w128` sections rerun it at 1 and 128
bytes. It checks little-endian beat assembly, the top memory boundary, the
wide address wrap guard, R-field stability under backpressure and both
latency stages.

## Limits and Notes

- `GC_ADDR_WIDTH` must be at least `log2ceil(GC_MEM_SIZE_BYTES)` so every
  byte of the memory is addressable. Wider addresses are allowed and simply
  leave the upper address range unused; reads there return `SLVERR`. The
  internal memory bound is one bit wider than the address port, so a
  power-of-two memory size is compared correctly.
- Set `GC_MEM_SIZE_BYTES` to a whole multiple of `GC_DATA_BYTES`. A size that
  is not a multiple of the native beat width leaves the final part of the
  memory unreachable, because a beat must be wholly inside the memory to
  return `OKAY`.
- A burst that leaves the memory stays `SLVERR` for the remainder of the
  burst, even if the beat address would wrap at the top of the address space.
- Simulation only. The memory is a process variable and a whole beat is
  read in one clock, which cannot map to block RAM.
- `mem_wr_error` is registered, so it is asserted during the clock cycle after
  the accepted invalid write.
- A byte written on a clock edge is included in a beat loaded on that same
  edge.

## Files

- `rtl/axi_mem_store_core.vhd` - stored-memory AXI burst core.
- `axis_latency_gen/rtl/axis_latency_gen.vhd` - shared AR/R latency stage.
- `rtl/axi_mem_store.vhd` - full latency-enabled wrapper.
- `tb/` - comprehensive, simple and bus-width testbenches.
- `scripts/vhdl.f` - manifest: source closure and testbench selections.
