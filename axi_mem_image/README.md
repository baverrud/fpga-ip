# axi_mem_image — file backed memory image for simulation

`mem_image` loads a memory image from an Intel HEX file at time zero and
│   ├── mem_image.vhd              the store (simulation only)
│   ├── axi_mem_image_core.vhd     AXI burst sequencer backed by the store
│   └── axi_mem_image.vhd          axi_mem_model-compatible AXI wrapper
is: how many regions it has, where they start and how large they are.
Nothing about the image is compiled into the HDL.

* Simulation only — it uses `std.textio` to read the file.
│   ├── mem_image_corner_tb.vhd    parser, boundary and merge corner cases
│   ├── axi_mem_image_bridge_tb.vhd four-client bridge integration demo
* Zero latency, combinational read port; one byte lane per byte.
* Sparse images with holes; several regions per image; byte exact.
│       ├── simple_image.hex       / minimal_image.hex / ascii_image.hex
│       ├── hole_image.hex         / seg_image.hex / partial_image.hex
│       ├── two_regions.hex        / malformed_image.hex
│       ├── boundary_image.hex     / bridge_image.hex / demo_image.hex

## Contents

| Section | What is in it |
|---------|---------------|
| [Getting started](#getting-started-the-simplest-possible-example) | The smallest working example, in three steps |
| [What it is / when to use it](#what-it-is-and-when-to-use-it) | Purpose and limits |
| [Features](#features) | Bullet list of what it does |
| [Interface](#interface) | Generic and port tables |
| [The image file format](#the-image-file-format) | Intel HEX, record by record, with a worked checksum |
| [Regions, holes and misses](#regions-holes-and-misses) | How address ranges and outside-image reads are handled |
| [Example images](#example-images) | Every shipped `.hex` file, byte by byte |
| [Making your own image](#making-your-own-image) | `objcopy`, `srec_cat`, Python, memory dumps |
| [Architecture](#architecture) | How the loader and the read port work |
| [File structure](#file-structure) | Tree of the IP |
| [Instantiation](#instantiation) | Copy-paste templates (testbench) |
| [Verification](#verification) | How to run the three testbenches |
| [Troubleshooting](#troubleshooting) | The messages you may see, and what they mean |
| [Limitations and notes](#limitations-and-notes) | Simulator portability, memory cost, why no synthesis wrapper |

---

## Getting started (the simplest possible example)

### Step 1 — write the image file

Two lines. The first line puts eight bytes of data at address `0x0000`,
the second line ends the file:

```text
:08000000EFBEADDE78563412AC
:00000001FF
```

That is `tb/data/simple_image.hex` in this IP. Memory is byte addressed and
little endian, so reading a 32 bit word at `0x0000` returns
`0xDEADBEEF`, and at `0x0004` returns `0x12345678`:

| Address | Bytes in the file | 32 bit read |
|---------|-------------------|-------------|
| `0x0000` | `EF BE AD DE` | `0xDEADBEEF` |
| `0x0004` | `78 56 34 12` | `0x12345678` |
| `0x0008` | (nothing is loaded) | miss — see [`GC_OUTSIDE`](#regions-holes-and-misses) |

### Step 2 — instantiate it in the testbench

Fifteen lines. No clock is needed: the image is loaded while the simulation
is elaborated, and the read port follows `addr` combinationally.

```vhdl
  signal addr  : std_logic_vector(31 downto 0) := (others => '0');
  signal data  : std_logic_vector(31 downto 0);
  signal hit   : std_logic;
  signal ready : std_logic;
  ...
  u_image : entity work.mem_image
    generic map (
      GC_DATA_BYTES => 4,
      GC_ADDR_WIDTH => 32,
      GC_FILE       => "axi_mem_image/tb/data/simple_image.hex",
      GC_OUTSIDE    => "zero"
    )
    port map (
      read_en => '1',
      addr    => addr,
      data    => data,
      hit     => hit,
      ready   => ready
    );
  ...
  addr <= x"00000000";                -- then wait, and check data/hit
```

The complete version of this, with the checks and the commentary, is
`tb/mem_image_simple_tb.vhd`.

### Step 3 — run it

```bash
run axi_mem_image vhdl modelsim --tb simple
run axi_mem_image vhdl xsim     --tb simple
```

Expected transcript (ModelSim):

```text
# ** Note: mem_image: loaded 8 bytes into 1 region(s) from 'axi_mem_image/tb/data/simple_image.hex'
# ** Note: mem_image:   region 0 0x0000000000000000..0x0000000000000007
# simple example: image loaded
# simple example: read 0x0000 -> 0xDEADBEEF
# simple example: read 0x0004 -> 0x12345678
# simple example: read 0x0008 -> miss, data 0x00000000
# simple example: SIMPLE EXAMPLE OK
result   : PASS
```

That is the whole idea. The rest of this document is the detail behind it.

---

## What it is and when to use it

Use `mem_image` when a testbench needs **real data** in memory rather than
a fixed pattern generated in HDL: a boot image, an overlay, a lookup
table, a packet capture, a dump taken from hardware, or per-client data so
that four read clients each see different contents.

Use it directly in a testbench, or use the included `axi_mem_image` wrapper
as a drop-in image-backed replacement for `axi_mem_model`.

Do not use it for synthesis: it reads a file at elaboration time and keeps
the loaded image in a process variable, neither of which is synthesizable.

## Features

* **The file decides the layout.** Region count, region base addresses and
  region sizes come from the image; only the *capacity limits* are
  generics. Adding a record to the file changes the image, not the HDL.
* **Sparse images with holes.** Unloaded addresses *between* two records
  are real memory that reads as zero, as long as the gap is not larger
  than `GC_GAP_BYTES`. Larger gaps split the image into separate regions.
* **Several regions per image**, up to `GC_MAX_REGIONS`, optionally merged
  by raising `GC_GAP_BYTES` (one sparse region) instead.
* **Byte exact.** Records may start and end on any byte address; a record
  that starts mid word is merged into the word it lands in.
* **Any low-level read width.** `mem_image` accepts any positive byte width;
  the AXI wrapper restricts its bus width to the AXI-model powers of two:
  1, 2, 4, 8, 16, 32, 64 or 128 bytes.
* **Three outside-image policies:** stop the simulation (`"fail"`), poison
  the data with `0xDEADBEEF` (`"poison"`), or drive zeros (`"zero"`).
* **Loud about mistakes:** a missing file, too many regions, a region that
  is too large, or a read outside the image is a `severity failure` with a
  message naming the file and the address.
* **Portable RTL:** ModelSim/Questa and XSim 2023.2 both compile and run the
  store and its regressions; the bridge integration may show startup
  `numeric_std` metavalue notes from shared CDC/latency infrastructure.

## Interface

### Generics

| Generic | Type | Default | Description |
|---------|------|---------|-------------|
| `GC_DATA_BYTES` | `positive` | `16` | Bytes served per read. 4 for a 32 bit bus, 16 for a 128 bit bus. |
| `GC_ADDR_WIDTH` | `positive` | `32` | Width of the byte address input. Must be at most 64. |
| `GC_FILE` | `string` | `""` | Image file. Empty string = no file: every read is a miss. |
| `GC_MAX_REGIONS` | `positive` | `4` | Separate address regions allowed in one image. Set it to the number of independent clients that need their own image contents. |
| `GC_GAP_BYTES` | `natural` | `4096` | Unloaded address span that still counts as *inside* one region. Loaded records closer together than this are merged into one region; raise it to model one sparse region, lower it to keep regions apart. |
| `GC_REGION_WORDS` | `positive` | `16384` | Capacity of one region in 32 bit words (16384 = 64 KiB). A region larger than this is an error — raise it and accept the extra simulation memory. |
| `GC_OUTSIDE` | `string` | `"fail"` | What a read outside the image drives: `"fail"`, `"poison"` or `"zero"`. Invalid values fail at time zero. |

Simulation memory used by one instance is
`GC_MAX_REGIONS * GC_REGION_WORDS * 4` bytes (the default is 256 KiB),
whether or not the image fills it.

### Ports

| Port | Direction | Type | Description |
|------|-----------|------|-------------|
| `read_en` | in | `std_logic` | Read enable. Only a consumed read (`read_en = '1'`) can fail under the `"fail"` policy. |
| `addr` | in | `std_logic_vector(GC_ADDR_WIDTH-1 downto 0)` | Byte address for the next read. |
| `data` | out | `std_logic_vector(8*GC_DATA_BYTES-1 downto 0)` | Read data. Byte *b* of the beat comes from address `addr + b`, so the bus is little endian. |
| `hit` | out | `std_logic` | `'1'` when the whole read lies inside one loaded region. |
| `ready` | out | `std_logic` | `'1'` once the image is loaded (at time zero, before the first wait). |

The read port has no clock and no latency: `data` and `hit` follow `addr`
and `read_en`. Register them in your testbench if the read slave needs
timing; the included AXI wrapper does that with `axis_latency_gen`.

### AXI wrapper: `axi_mem_image`

`axi_mem_image` has the same AXI ports and timing-control generics as
`axi_mem_model`, plus the image configuration generics below. Existing
`axi_read_bridge` or DMA testbenches can replace the entity name and add
these image generics without changing their native AXI wiring.

| Generic | Default | Description |
|---------|---------|-------------|
| `GC_DATA_BYTES` | `64` | Native AXI data width in bytes. Must be 1, 2, 4, 8, 16, 32, 64 or 128. |
| `GC_ADDR_WIDTH` | `49` | Native AXI byte-address width. Must be at most 64. |
| `GC_ID_WIDTH` | `6` | Native AXI ID width. |
| `GC_TIMER_WIDTH` | `16` | Width of latency and beat-gap controls. |
| `GC_AR_FIFO_DEPTH` | `8` | AR-side latency FIFO depth. |
| `GC_R_FIFO_DEPTH` | `8` | R-side beat-gap FIFO depth. |
| `GC_FILE` | `""` | Intel HEX image path. |
| `GC_MAX_REGIONS` | `4` | Maximum separate image regions. |
| `GC_GAP_BYTES` | `4096` | Gap threshold used to merge image records. |
| `GC_REGION_WORDS` | `16384` | Capacity of each image region in 32-bit words. |

The AXI wrapper always loads `mem_image` with `GC_OUTSIDE = "zero"` and
uses the store's `hit` output to generate AXI responses. A complete beat
inside a region returns `OKAY`, including an internal hole; a beat outside
the image returns zero data with `SLVERR`. The wrapper's AR and R latency
controls behave like `axi_mem_model`.

## The image file format

The format is **Intel HEX**, the byte addressed text format that nearly
every toolchain can write (`objcopy -O ihex`, `srec_cat`, IAR, Keil,
`avr-objcopy`, Xilinx `bootgen`, most memory dumps).

### The record

```text
:LLAAAATT[DD..]CC
```

| Field | Meaning |
|-------|---------|
| `:` | start code, always the first character of a record |
| `LL` | payload byte count, `00`..`FF` |
| `AAAA` | 16 bit big endian address, relative to the current base address |
| `TT` | record type (see below) |
| `DD..` | `LL` payload bytes |
| `CC` | two's complement of the sum of all preceding bytes |

All fields are ASCII hex digits; upper and lower case are both accepted.

### Record types

| `TT` | Name | Effect here |
|------|------|-------------|
| `00` | data | Store the `LL` payload bytes at `base + AAAA`. |
| `01` | end of file | Marks the end of the image. Should be the last record. |
| `02` | extended segment address | New base = `(payload as 16 bit big endian value) << 4`. The `AAAA` field of this record is zero; the value lives in the payload. |
| `03` | start segment address | Ignored (it carries a CPU start address, not memory). |
| `04` | extended linear address | New base = `(payload as 16 bit big endian value) << 16`. |
| `05` | start linear address | Ignored. |

A type `02` or `04` record repositions every following data record. Both
can be used for the same image; `hole_image.hex` and `seg_image.hex` in
this IP describe **the same memory** through type `04` and type `02`
respectively, and `mem_image_examples_tb` asserts that they read back
identically.

### Checksum, worked example

`simple_image.hex` starts with:

```text
:08000000EFBEADDE78563412AC
```

* `LL` = `08`, `AAAA` = `0000`, `TT` = `00`, payload = `EF BE AD DE 78 56 34 12`.
* Sum of all bytes before the checksum:
  `08 + 00 + 00 + 00 + EF + BE + AD + DE + 78 + 56 + 34 + 12 = 0x454`.
* `0x454` truncated to a byte is `0x54`; two's complement is
  `(0x100 - 0x54) & 0xFF = 0xAC`, which is the trailing byte.

A record whose checksum, length or field syntax does not check out is
**skipped silently**. That is deliberate: it makes a file with a stray
comment or a partly corrupt line still usable. If an image loads fewer
bytes than you expect, check the checksums first.

### Rules and freedoms

* Addresses are **byte** addresses. There are no 32 bit word addresses to
  convert, and no word alignment requirement.
* Records may be any length up to 255 bytes, and may start on any address.
* Bytes that no record mentions are *not* padding to be skipped silently:
  they become real memory that reads zero, as long as they are inside a
  region (see below).
* Blank lines, whitespace and a final `CR`/`LF` are tolerated; anything
  before `:` on a line is not (the line is then skipped).
* Little endian vs big endian is a property of *your* bus, not of the
  format: the file stores bytes in increasing address order and
  `mem_image` puts byte *b* at bits `8*b+7 downto 8*b`. If your upstream
  data is big endian, swap the bytes when generating the file.

### Where the file is looked for

`GC_FILE` may be an absolute path or a path relative to the *simulation
run directory*. Relative paths are tried with these prefixes, in order:

```text
""            ../           ../../          ../../../          ../../../../
```

That is what makes `GC_FILE => "axi_mem_image/tb/data/simple_image.hex"`
work from `axi_mem_image/.runs/<tool>/` as well as from the project root.
When nothing opens, the run stops with a message naming the file and the
places that were tried:

```text
** Failure: mem_image: cannot open image file 'my_image.hex': tried the run
   directory and its four parents
```

## Regions, holes and misses

A **region** is a maximal span of loaded addresses, plus the holes inside
it. Two loaded records belong to the same region when the gap between them
is at most `GC_GAP_BYTES` bytes; otherwise they form separate regions.

```text
demo_image.hex, 4 blocks of 64 bytes, 4096 bytes apart

  GC_GAP_BYTES = 256   -> 4 regions   0x1000..0x103F, 0x2000..0x203F, ...
  GC_GAP_BYTES = 8192  -> 1 region    0x1000..0x403F
                                       (the space between the blocks is
                                        inside the region and reads zero)
```

Reading rules:

| Situation | `hit` | `data` |
|-----------|-------|--------|
| Every byte of the read is inside one region | `'1'` | Loaded bytes, and zero for bytes inside the region that no record loaded |
| Any byte of the read is outside every region | `'0'` | Per `GC_OUTSIDE` |

`GC_OUTSIDE` in practice:

| Value | Behaviour on a miss | Use it for |
|-------|---------------------|------------|
| `"fail"` | `severity failure` naming the size and address of the read and the file. Only fires when `read_en = '1'`, so a stale address left on the bus between beats is harmless. | Catching an address map mistake immediately (default). |
| `"poison"` | Widths below 4 bytes are all `0xFF`; widths of 4 bytes or more repeat the byte pattern `EF BE AD DE`, truncating the final partial word if needed. | Seeing misses in a waveform, and making "this is a miss" distinguishable from "these bytes happen to be zero". |
| `"zero"` | Data = 0. | Modelling a device that returns zeros for unpopulated address space, or when misses are expected. |

The capacity and region-count limits are checked while loading, so a bad
image fails at time zero rather than halfway through a test:

```text
** Failure: mem_image: 'three_blocks.hex' has more than 4 separate regions
   (raise GC_MAX_REGIONS, or raise GC_GAP_BYTES to merge nearby records)
** Failure: mem_image: region 0 of 'big.hex' needs 32768 words, but
   GC_REGION_WORDS is 16384
```

## Example images

All files live in `tb/data/`, are generated by `tb/data/make_images.py`,
and are loaded by one of the testbenches, so the byte maps below cannot
drift away from the code.

| File | Content | Demonstrates | Checked by |
|------|---------|--------------|------------|
| `simple_image.hex` | 8 bytes at `0x0000` | The smallest useful image; one region, two words | `mem_image_simple_tb` |
| `minimal_image.hex` | 4 bytes at `0x0000` | One record, one word, no address record needed | `mem_image_examples_tb` |
| `ascii_image.hex` | 32 bytes at `0x1000` | Text in memory, read byte for byte with 16 byte beats | `mem_image_examples_tb` |
| `hole_image.hex` | `0x10000..0x1001F` with an 8 byte hole | Sparse region: the hole reads zero, the region does not end there | `mem_image_tb`, `mem_image_examples_tb` |
| `seg_image.hex` | The same image as `hole_image.hex` | Type `02` segment addresses equal type `04` linear addresses | `mem_image_examples_tb` |
| `partial_image.hex` | 3 bytes at `0x0003`, 1 byte at `0x0007` | Byte exact, unaligned records, and a loaded region that does not start on a word boundary | `mem_image_examples_tb` |
| `two_regions.hex` | `0x00000` and `0x10000` | Two regions more than 64 KiB apart; everything between is a miss | `mem_image_examples_tb` |
| `malformed_image.hex` | Valid records around a comment, type 03/05 records and a bad checksum | Invalid records are ignored without corrupting neighboring valid data | `mem_image_corner_tb` |
| `boundary_image.hex` | Data ending at `0xFFFF` followed by data at `0x10000` | Exact 64 KiB transition, type 04 update, adjacent records and a 64-bit address port | `mem_image_corner_tb` |
| `bridge_image.hex` | Records at `0x0000`, `0x1004` and `0x2004` | Transitive region merging and holes inside the merged extent | `mem_image_corner_tb` |
| `demo_image.hex` | Four 64 byte blocks at `0x1000`, `0x2000`, `0x3000`, `0x4000` | Pattern data where every byte differs from its neighbours; one image that is 4 regions or 1 region depending on `GC_GAP_BYTES` | `mem_image_tb` |

### `simple_image.hex`

```text
:08000000EFBEADDE78563412AC
:00000001FF
```

```text
address  00 01 02 03 04 05 06 07
data     EF BE AD DE 78 56 34 12
```

One region, `0x0000..0x0007`. Word at `0x0000` = `0xDEADBEEF`, word at
`0x0004` = `0x12345678`, address `0x0008` is a miss.

### `minimal_image.hex`

```text
:040000001122334452
:00000001FF
```

Bytes `11 22 33 44` at `0x0000`. A 4 byte read at `0x0000` hits; a 4 byte
read at `0x0001` does not, because it would need `0x0004` which is not
loaded.

### `ascii_image.hex`

```text
:1010000048454C4C4F2046524F4D204120484558B2
:101010002046494C450A0000000000000000000086
:00000001FF
```

```text
0x1000  48 45 4C 4C 4F 20 46 52 4F 4D 20 41 20 48 45 58   HELLO FROM A HEX
0x1010  20 46 49 4C 45 0A 00 00 00 00 00 00 00 00 00 00    FILE\n then zeros
```

One region, `0x1000..0x101F`. The text plus the line feed and the NUL is 23
bytes, written as two 16 byte records: the 7 bytes that did not fit in the
first record, followed by 9 zeros, so that 16 byte beats fit inside the
region. `0x1020` is a miss.

### `hole_image.hex`

```text
:020000040001F9
:08000000A0A1A2A3A4A5A6A7DC
:10001000B0B1B2B3B4B5B6B7B8B9BABBBCBDBEBF68
:00000001FF
```

```text
0x10000  A0 A1 A2 A3 A4 A5 A6 A7      loaded (type 04 sets base 0x10000)
0x10008  -- -- -- -- -- -- -- --      hole: no record, reads zero
0x10010  B0 B1 B2 B3 B4 B5 B6 B7      loaded
0x10018  B8 B9 BA BB BC BD BE BF      loaded
0x10020  (miss)
```

One region, `0x10000..0x1001F` (32 bytes, 8 words). The hole is *inside*
the region, so it is a hit that reads zero — with `GC_OUTSIDE = "poison"`
the testbench proves the difference between the hole and a miss.

### `seg_image.hex` — the same image through type 02

```text
:020000021000EC
:08000000A0A1A2A3A4A5A6A7DC
:10001000B0B1B2B3B4B5B6B7B8B9BABBBCBDBEBF68
:00000001FF
```

`:020000021000EC` sets the base to `0x1000 << 4 = 0x10000`, so the two
data records land exactly where they do in `hole_image.hex`. A testbench
instance of each file is driven with the same addresses and their `hit` and
`data` outputs are compared beat by beat.

### `partial_image.hex` — unaligned and not word sized

```text
:03000300AABBCCC9
:01000700DD1B
:00000001FF
```

```text
address  00 01 02 03 04 05 06 07
data     -- -- -- AA BB CC 00 DD
                    ^     ^
                    |     +-- inside the region, never loaded: reads zero
                    +-------- the region starts here, mid word
```

The region is `0x0003..0x0007` only. A 4 byte read at `0x0000` is a miss
(it would start before the region), a 4 byte read at `0x0004` returns
`BB CC 00 DD`, and a 4 byte read at `0x0007` is a miss because it would
run past the last loaded byte.

### `two_regions.hex`

```text
:04000000102030405C
:020000040001F9
:04000000506070805C
:00000001FF
```

```text
0x00000  10 20 30 40     region 0
0x00004  (miss)
   ...
0x08000  (miss — between the regions)
   ...
0x10000  50 60 70 80     region 1 (type 04 sets base 0x10000)
0x10004  (miss)
```

Two regions, so `GC_MAX_REGIONS` must be at least 2. This file also
exercises the loader's handling of a data record that comes *before* any
extended address record.

### `demo_image.hex` — pattern data

Four blocks of 64 bytes, 4096 bytes apart, written as 16 records of
16 bytes:

```text
:10100000101112131415161718191A1B1C1D1E1F68
:10101000202122232425262728292A2B2C2D2E2F58
...
:10403000707172737475767778797A7B7C7D7E7F08
:00000001FF
```

The byte at address `A` is `(A[7:0] + A[15:8]) mod 256`, so every byte
differs from its neighbours and from the byte in the corresponding
position of every other block. A shifted beat, a swapped lane or a wrong
block cannot pass by accident.

### `mem_image_tb` image coverage

`mem_image_tb` (the default testbench) uses `demo_image.hex` and
`hole_image.hex` to cover the region, hole, policy, width and merge
behaviour; `mem_image_examples_tb` covers all the other files. Together
they load every file in `tb/data/` at least once.

## Making your own image

**From a binary blob** (recommended, no address math):

```bash
objcopy -I binary -O ihex --change-addresses 0x10000000 blob.bin image.hex
srec_cat blob.bin -binary -offset 0x10000000 -o image.hex -intel
```

`srec_cat` additionally supports gaps, fills, byte swapping, multiple
input files with different offsets, and address checks — it is the most
flexible of the two.

**From a memory dump** of a running system, just record the base address
you dumped from.

**From a script**, which is how the examples in this IP are made:

```bash
python tb/data/make_images.py     # regenerates every tb/data/*.hex file
```

`tb/data/make_images.py` is a dependency free reference implementation of
the format that also documents each example file's byte map in comments.
Copy the two helper functions (`record`, `ext_linear`) into your own
generator:

```python
def record(addr, data):
    """One Intel HEX data record for 16 bit offsets."""
    body = [len(data), (addr >> 8) & 0xFF, addr & 0xFF, 0x00] + list(data)
    return ":" + "".join(f"{b:02X}" for b in body) + f"{(-sum(body)) & 0xFF:02X}"

def ext_linear(upper):
    """Type 04 record: following addresses get bits 31..16 = upper."""
    body = [0x02, 0x00, 0x00, 0x04, (upper >> 8) & 0xFF, upper & 0xFF]
    return ":" + "".join(f"{b:02X}" for b in body) + f"{(-sum(body)) & 0xFF:02X}"
```

**If your image is wider than the file format's 16 bit address field**
(above 64 KiB), emit a type `04` record whenever the address crosses a
64 KiB boundary; `make_images.py` shows the pattern. Note that a single
record must not cross a 64 KiB boundary either, because the `AAAA` field
is only 16 bits wide.

## Architecture

```text
           GC_FILE
              |
     +--------v---------+   time zero, two passes over the file
     |   p_store        |
     |  pass 1: parse every record, build region extents,
     |          merge regions that are closer than GC_GAP_BYTES
     |  pass 2: copy payload bytes into the store
     +--------+---------+
              |
     +--------v---------------------------+
     | store: GC_MAX_REGIONS slices of     |
     |        GC_REGION_WORDS 32 bit words |
     +--------+---------------------------+
              |  read (combinational)
   addr ----->|-----> data
   read_en -->|-----> hit
              |
     ready ---+  ('1' once the image is loaded)
```

One process, `p_store`, does everything:

1. **Load (phase 1).** It locates the file, then reads it twice. The first
   pass only looks at addresses and sizes: it builds the region extents
   and merges regions whose gap is at most `GC_GAP_BYTES` (repeatedly, so
   a record that bridges two regions merges them). The second pass copies
   payload bytes into the store, read-modify-write for records that start
   mid word.
2. **Serve (phase 2).** The same process then loops: it evaluates the read
   port, writes `data` and `hit`, and waits for a change on `addr` or
   `read_en`. From the outside this is combinational behaviour; keeping it
   in the loader process means the image stays in process variables.

Design notes worth knowing if you modify it:

* **No access types.** The store is a plain array variable with one slice
  per region. An earlier version allocated each region dynamically with
  `new`; XSim 2023.2 mis-sizes an unconstrained array whose bounds come
  from a variable (and crashes on the initialized-aggregate form), so the
  one capacity limit, `GC_REGION_WORDS`, is a generic instead.
* **No mixed-width arithmetic on addresses.** `byte_addr_t` is 64 bits;
  `unsigned + integer` has a tool dependent result width, so every address
  sum uses two `byte_addr_t` operands.
* **ASCII only in report strings** (ModelSim's VHDL `character` type) and
  no Unicode anywhere in the sources, comments included.
* The loader prints what it did, which is often the fastest way to see
  what an image actually contains:

  ```text
  ** Note: mem_image: loaded 256 bytes into 4 region(s) from 'axi_mem_image/tb/data/demo_image.hex'
  ** Note: mem_image:   region 0 0x0000000000001000..0x000000000000103F
  ** Note: mem_image:   region 1 0x0000000000002000..0x000000000000203F
  ```

## File structure

```text
axi_mem_image/
├── README.md                      this document
├── rtl/
│   ├── mem_image_pkg.vhd          types and Intel HEX record decoding
│   └── mem_image.vhd              the store (simulation only)
├── tb/
│   ├── mem_image_tb.vhd           comprehensive self-test (default)
│   ├── mem_image_simple_tb.vhd    the getting started example
│   ├── mem_image_examples_tb.vhd  verifies every example image file
│   └── data/
│       ├── make_images.py         generates all the .hex files below
│       ├── simple_image.hex       / minimal_image.hex
│       ├── ascii_image.hex        / hole_image.hex / seg_image.hex
│       ├── partial_image.hex      / two_regions.hex / demo_image.hex
└── scripts/
    └── vhdl.f                     file list (no [top]: simulation only)
```

## Instantiation

The templates below are testbench code: `mem_image` is not synthesizable,
so there are no `top/` wrappers.

### Testbench instance, wide bus, whole image in one region

```vhdl
  -- Image: one sparse region, misses read as zero
  constant C_FILE : string := "axi_mem_image/tb/data/demo_image.hex";

  signal read_en : std_logic := '0';                       -- read enable
  signal addr    : std_logic_vector(31 downto 0) := (others => '0'); -- byte address
  signal data    : std_logic_vector(127 downto 0);         -- 16 byte beat
  signal hit     : std_logic;                              -- inside the image
  signal ready   : std_logic;                              -- image loaded
  ...
  u_mem_image : entity work.mem_image
    generic map (
      GC_DATA_BYTES   => 16,                               -- bytes per beat
      GC_ADDR_WIDTH   => 32,                               -- address width
      GC_FILE         => C_FILE,                           -- image file
      GC_MAX_REGIONS  => 4,                                -- regions allowed
      GC_GAP_BYTES    => 8192,                             -- merge nearby records
      GC_REGION_WORDS => 16384,                            -- 64 KiB per region
      GC_OUTSIDE      => "zero"                            -- miss policy
    )
    port map (
      read_en => read_en,                                  -- read enable
      addr    => addr,                                     -- byte address
      data    => data,                                     -- read data
      hit     => hit,                                      -- inside the image
      ready   => ready                                     -- image loaded
    );
```

### Four clients, four regions in one file

For the multi-client case (`axi_read_bridge` and similar), one instance
per client, each with its own file, is the most readable arrangement:

```vhdl
  -- One instance per client; each client sees its own image contents
  u_client_0 : entity work.mem_image
    generic map (
      GC_DATA_BYTES  => 16, GC_ADDR_WIDTH => 32,
      GC_FILE        => "tb/data/client_0.hex",
      GC_MAX_REGIONS => 1,  GC_GAP_BYTES  => 4096,
      GC_OUTSIDE     => "zero"
    )
    port map (
      read_en => rd0, addr => addr0, data => data0, hit => hit0, ready => ready0
    );
  -- u_client_1 ... u_client_3 likewise
```

If instead you want a single file with one region per client, generate it
with records far enough apart (`GC_GAP_BYTES` below the spacing) and set
`GC_MAX_REGIONS` to the number of clients; reads outside a client's region
are then misses, which is how a shared address map is modelled.

### AXI wrapper instance

This is the native-side replacement for an `axi_mem_model` instance. The
AXI control and channel ports are unchanged; only the image generics are
new. The latency enables are all disabled below so the example focuses on
the image contents rather than timing jitter.

```vhdl
  -- Native AXI image-backed memory, 16-byte beats and four image regions
  u_axi_mem_image : entity work.axi_mem_image
    generic map (
      GC_DATA_BYTES    => 16,                              -- native bytes
      GC_ADDR_WIDTH    => 32,                              -- byte address width
      GC_ID_WIDTH      => 4,                               -- AXI ID width
      GC_TIMER_WIDTH   => 16,                              -- timing counters
      GC_AR_FIFO_DEPTH => 8,                               -- AR buffering
      GC_R_FIFO_DEPTH  => 8,                               -- R buffering
      GC_FILE          => "axi_mem_image/tb/data/demo_image.hex", -- image
      GC_MAX_REGIONS   => 4,                               -- client regions
      GC_GAP_BYTES     => 256,                             -- keep blocks separate
      GC_REGION_WORDS  => 16                               -- 64 bytes per block
    )
    port map (
      aclk             => mem_aclk,                        -- memory clock
      aresetn          => aresetn,                         -- active-low reset
      ar_base_enable   => '0',                             -- no AR delay
      ar_jitter_enable => '0',                             -- no AR jitter
      r_base_enable    => '0',                             -- no R gap
      r_jitter_enable  => '0',                             -- no R jitter
      base_latency     => (others => '0'),                 -- first-beat delay
      base_beat_gap    => (others => '0'),                 -- beat gap
      ar_id            => ar_id,                            -- AXI AR ID
      ar_addr          => ar_addr,                          -- AXI AR address
      ar_len           => ar_len,                           -- AXI burst length
      ar_valid         => ar_valid,                         -- AXI AR valid
      ar_ready         => ar_ready,                         -- AXI AR ready
      r_id             => r_id,                             -- AXI R ID
      r_data           => r_data,                           -- AXI R data
      r_resp           => r_resp,                           -- AXI R response
      r_last           => r_last,                           -- AXI final beat
      r_valid          => r_valid,                          -- AXI R valid
      r_ready          => r_ready                           -- AXI R ready
    );
```

The complete four-client example is
`tb/axi_mem_image_bridge_tb.vhd`; it uses `demo_image.hex` and checks each
client's returned 16-byte beat against an independent byte formula.

### Synthesis wrappers

None, by design. `mem_image` reads a file with `std.textio` at elaboration
time, so the AXI wrapper is simulation-only too. There is nothing sensible
for a `top/axi_mem_image_top.vhd` or `top/axi_mem_image_top.sv` synthesis
wrapper to contain. The manifest `scripts/vhdl.f` therefore has **no
`[top]` section**, and synthesis flows report it as skipped ("no [top]
section; synthesis requires a top-level wrapper") rather than attempting
to synthesize file I/O.

## Verification

Five testbenches, all in `tb/`:

| Testbench | Section | Covers |
|-----------|---------|--------|
| `mem_image_tb` | `[tb:default]` | Region splitting and merging via `GC_GAP_BYTES`, 16 byte and 4 byte reads, unaligned addresses, holes reading zero, hits that run past a region end, all three `GC_OUTSIDE` policies (`"fail"` by hand, see below), `read_en` gating |
| `mem_image_simple_tb` | `[tb:simple]` | The getting started example, end to end |
| `mem_image_examples_tb` | `[tb:examples]` | Loads and verifies every ordinary example image, including empty-file behavior, single-byte reads, one-word capacity and 5/7-byte poison widths |
| `mem_image_corner_tb` | `[tb:corner]` | Bad checksums, ignored type 03/05 records, exact 64 KiB boundary, 64-bit address input, adjacent records and transitive merging |
| `axi_mem_image_bridge_tb` | `[tb:bridge]` | Four simultaneous clients through `axi_read_bridge`, CDC, arbitration, response routing and independent image-byte checking |

```bash
run axi_mem_image vhdl modelsim                 # comprehensive (default)
run axi_mem_image vhdl modelsim --tb simple     # getting started example
run axi_mem_image vhdl modelsim --tb examples   # example image files
run axi_mem_image vhdl modelsim --tb corner     # parser/address/merge corners
run axi_mem_image vhdl modelsim --tb bridge     # four-client AXI demo
run axi_mem_image vhdl xsim                     # the same on XSim
run axi_mem_image vhdl xsim --tb corner         # corner cases on XSim
run axi_mem_image vhdl xsim --tb bridge         # AXI demo on XSim
```

The store-only testbenches are expected to produce `result : PASS` with
zero errors and warnings, and final notes (`ALL CHECKS PASSED`,
`SIMPLE EXAMPLE OK`, `ALL EXAMPLES CHECKED`, and `ALL CORNER CHECKS PASSED`).
The bridge demo ends with `FOUR CLIENT IMAGE CHECKS PASSED`. ModelSim may
also print a small number of time-zero `numeric_std` metavalue warnings
from the shared CDC and latency-generator infrastructure; these do not
originate in the testbench or image store and do not affect the checks.

`run.py` judges PASS/FAIL from the exit code plus a scan of the transcript
for ModelSim `** Failure:` / `** Error:` or XSim `Failure:` / `Error:`
lines, so a testbench assertion of `severity failure` is what makes a run
fail.

**Exercising the `"fail"` policy by hand.** It cannot be tested in a run
that is meant to pass, because it stops the simulation. To see it:
temporarily set `GC_OUTSIDE => "fail"` on an instance whose address is
driven outside the image with `read_en = '1'`, run, and expect

```text
** Failure: mem_image: read of 16 byte(s) at 0x0000000000008000 is outside
   the loaded image (file 'axi_mem_image/tb/data/demo_image.hex')
```

then revert. `mem_image_tb` uses the `"fail"` policy for one instance and
checks that a *stale* address with `read_en = '0'` is harmless, which is
the property that makes the policy usable in the middle of a burst.

## Troubleshooting

| Symptom | Cause and fix |
|---------|---------------|
| `mem_image: cannot open image file '...'` | The path is wrong for the run directory. Remember the file is searched relative to the run directory and its four parents; print `GC_FILE` or use an absolute path while debugging. |
| `mem_image: loaded 0 bytes into 0 region(s)` | The file opened but no record was accepted. Almost always a checksum or field-length error — regenerate the file, or compare against one of the `tb/data/*.hex` files. |
| `loaded N bytes into ... region(s)` with fewer regions than expected | Records were merged because their gap is at most `GC_GAP_BYTES`. Lower `GC_GAP_BYTES` to split them. |
| `has more than N separate regions` | `GC_MAX_REGIONS` is too low for this image, or `GC_GAP_BYTES` is too low to merge nearby records. |
| `region 0 of '...' needs N words, but GC_REGION_WORDS is M` | The region is larger than one slice of the store. Raise `GC_REGION_WORDS`, or split the image into several files/instances. |
| `read of N byte(s) at 0x... is outside the loaded image` | A read hit an address that no record loaded, with `GC_OUTSIDE = "fail"`. Either fix the address or the image, or switch that instance to `"poison"`/`"zero"`. |
| `data` is all `0x00` but `hit` is `'1'` | The read is inside a region but those bytes were never loaded (a hole). That is the documented behaviour; use `"poison"` if you want misses and holes to look different. |
| A read that "clearly fits" is a miss | The whole beat must fit inside the region: a 16 byte read at the last word of a 32 byte region is a miss. Check `hit` as well as `data` when debugging. |
| The image is loaded but `ready` is still low | `ready` goes high in the same process that loads the image, so it is high before the first `wait`. If it is low, the process stopped on a `severity failure` — look for the message above it in the transcript. |

## Limitations and notes

* **Simulation only.** `std.textio` file reads and the process variable
  store are not synthesizable. There is no synthesis wrapper and no
  `[top]` section (see [Instantiation](#instantiation)).
* **The low-level port has no clock or latency.** Use the included
  `axi_mem_image` wrapper when a read slave needs the `axi_mem_model`
  latency and inter-beat-gap controls.
* **Capacity is a generic, not dynamic.** One region holds at most
  `GC_REGION_WORDS` words. Simulation memory is reserved per instance up
  front: `GC_MAX_REGIONS * GC_REGION_WORDS * 4` bytes.
* **Image size is bounded by the file and the above**, not by any address
  compiled into the HDL: `GC_ADDR_WIDTH` only sets the address bus width,
  must be at most 64, and the loader works on 64 bit byte addresses
  internally.
* **A record may not cross a 64 KiB boundary** (the `AAAA` field is 16
  bits); emit a type `04` record instead.
* **Malformed records are skipped silently.** Only a missing file, too
  many regions, an oversized region and an outside-image read are hard
  errors. Compare the "loaded N bytes" note with your expectation.
* **Simulator portability.** The store and its regressions are verified on
  ModelSim/Questa 2020.1 and XSim 2023.2. The RTL avoids
  three XSim 2023.2 pitfalls on purpose: variable-sized allocation of an
  unconstrained array, aggregates at an access dereference target, and
  mixed `unsigned`/`integer` address arithmetic.
* **Traceability.** Every example `.hex` file is loaded by a testbench, so
  the byte maps in this document and the files in `tb/data/` cannot drift
  apart unnoticed.

* **AXI miss semantics.** The AXI wrapper maps a complete image hit to
  `OKAY` and an outside-image beat to zero data plus `SLVERR`; it does not
  expose the low-level `GC_OUTSIDE = "fail"` stop-simulation behavior.
