#!/usr/bin/env python3
"""Generate the example Intel HEX images shipped with axi_mem_image.

Usage (from anywhere):

    python tb/data/make_images.py

Every file written here is also loaded and checked by
``mem_image_examples_tb.vhd``, so a wrong checksum or a wrong byte shows up
as a test failure instead of a silent mistake in the documentation.

Intel HEX record layout (byte addressed)::

    :LLAAAATT[DD..]CC

    LL   payload byte count, 00..FF
    AAAA 16 bit big endian address, relative to the current base address
    TT   record type:
           00  data                payload is stored at AAAA
           01  end of file         last record, no payload
           02  extended segment    payload is the new base >> 4, base = value << 4
           03  start segment       ignored here
           04  extended linear     payload is the new base >> 16, base = value << 16
           05  start linear        ignored here
    CC   two's complement of the sum of all preceding bytes

Addresses are absolute byte addresses: after a type 02 or 04 record the
base is set, and a type 00 record lands at ``base + AAAA``.  There is no
alignment requirement and no padding: a record may start in the middle of
a 32 bit word, and bytes that no record mentions read back as zero.
"""

from pathlib import Path

OUT = Path(__file__).resolve().parent


def typed_record(addr: int, record_type: int, data: bytes) -> str:
    """Create any Intel HEX record and calculate its checksum."""
    body = [len(data), (addr >> 8) & 0xFF, addr & 0xFF,
            record_type] + list(data)
    return ":" + "".join(f"{b:02X}" for b in body) + f"{(-sum(body)) & 0xFF:02X}"


def record(addr: int, data: bytes) -> str:
    """One data record (type 00) at a 16 bit offset."""
    return typed_record(addr, 0x00, data)


def ext_linear(upper: int) -> str:
    """Type 04 record: the following addresses get bits 31..16 = upper."""
    body = [0x02, 0x00, 0x00, 0x04, (upper >> 8) & 0xFF, upper & 0xFF]
    return ":" + "".join(f"{b:02X}" for b in body) + f"{(-sum(body)) & 0xFF:02X}"


def ext_segment(segment: int) -> str:
    """Type 02 record: the following addresses get bits 19..4 = segment."""
    body = [0x02, 0x00, 0x00, 0x02, (segment >> 8) & 0xFF, segment & 0xFF]
    return ":" + "".join(f"{b:02X}" for b in body) + f"{(-sum(body)) & 0xFF:02X}"


EOF = ":00000001FF"


def pattern(addr: int) -> int:
    """byte(A) = (A[7:0] + A[15:8]) mod 256.

    Used by demo_image.hex: every byte differs from both its neighbours and
    from every byte of every other row, so a shifted or swapped beat cannot
    pass by accident.
    """
    return ((addr & 0xFF) + ((addr >> 8) & 0xFF)) & 0xFF


def write(name: str, lines: list[str], note: str) -> None:
    path = OUT / name
    path.write_text("\n".join(lines) + "\n", encoding="ascii")
    print(f"{name:<22} {path.stat().st_size:>5} bytes  {note}")


# ---------------------------------------------------------------------------
# simple_image.hex - the smallest useful example, 8 bytes at 0x0000
#   address 0x0000: EF BE AD DE -> reads back as the 32 bit word 0xDEADBEEF
#   address 0x0004: 78 56 34 12 -> reads back as the 32 bit word 0x12345678
# Two lines of file, one word per line, no address record needed.  This is
# the file used by the "very simple example" in the README and by
# mem_image_simple_tb.vhd.
# ---------------------------------------------------------------------------
write(
    "simple_image.hex",
    [record(0x0000, bytes([0xEF, 0xBE, 0xAD, 0xDE,
                           0x78, 0x56, 0x34, 0x12])), EOF],
    "8 bytes at 0x0000: 0xDEADBEEF then 0x12345678",
)

# ---------------------------------------------------------------------------
# minimal_image.hex - one word, at address 0
# ---------------------------------------------------------------------------
write(
    "minimal_image.hex",
    [record(0x0000, bytes([0x11, 0x22, 0x33, 0x44])), EOF],
    "one word at 0x0000 (smallest useful image)",
)

# ---------------------------------------------------------------------------
# ascii_image.hex - text in memory, 32 bytes at 0x1000
#   0x1000: "HELLO FROM A HEX FILE"   16 bytes, readable in the file itself
#   0x1010: "\\n" 0x00 then 9 zero bytes, so 16 byte reads still fit
# ---------------------------------------------------------------------------
text = b"HELLO FROM A HEX FILE\n\x00" + bytes(9)
ascii_lines = [
    record(0x1000 + off, text[off:off + 16])
    for off in range(0, len(text), 16)
]
write("ascii_image.hex", ascii_lines + [EOF], "32 bytes of text at 0x1000")

# ---------------------------------------------------------------------------
# hole_image.hex - one region with an unloaded hole
#   0x10000: 8 bytes 0xA0..0xA7
#   0x10008: hole (8 bytes, not in the file)
#   0x10010: 16 bytes 0xB0..0xBF
# The region extent is therefore 0x10000..0x1001F (32 bytes, 8 words) and
# the hole reads back as zero.
# ---------------------------------------------------------------------------
hole = [
    ext_linear(0x0001),
    record(0x0000, bytes(range(0xA0, 0xA8))),
    record(0x0010, bytes(range(0xB0, 0xC0))),
    EOF,
]
write("hole_image.hex", hole, "one region 0x10000..0x1001F, 8 byte hole")

# ---------------------------------------------------------------------------
# seg_image.hex - the same image as hole_image.hex, addressed with type 02
# segment records instead of type 04 records.  Both files describe exactly
# the same memory, which is a good cross check of the loader.
# ---------------------------------------------------------------------------
seg = [
    ext_segment(0x1000),                      # base = 0x1000 << 4 = 0x10000
    record(0x0000, bytes(range(0xA0, 0xA8))),
    record(0x0010, bytes(range(0xB0, 0xC0))),
    EOF,
]
write("seg_image.hex", seg, "same image as hole_image.hex, via type 02")

# ---------------------------------------------------------------------------
# partial_image.hex - records that are not word aligned or word sized
#   0x0003: 3 bytes 0xAA 0xBB 0xCC   (starts mid word, crosses a word)
#   0x0007: 1 byte  0xDD
# 0x0006 is inside the region but was never loaded, so it reads as zero,
# and 0x0000..0x0002 are outside the region: only 0x0003..0x0007 is loaded.
# ---------------------------------------------------------------------------
partial = [
    record(0x0003, bytes([0xAA, 0xBB, 0xCC])),
    record(0x0007, bytes([0xDD])),
    EOF,
]
write("partial_image.hex", partial, "unaligned 3 + 1 byte records at 0x0003")

# ---------------------------------------------------------------------------
# two_regions.hex - two regions more than 64 KiB apart
#   0x00000: 10 20 30 40
#   0x10000: 50 60 70 80
# With the default GC_GAP_BYTES = 4096 this is 2 regions, so GC_MAX_REGIONS
# must be at least 2.  Anything in between is outside the image.
# ---------------------------------------------------------------------------
two = [
    record(0x0000, bytes([0x10, 0x20, 0x30, 0x40])),
    ext_linear(0x0001),
    record(0x0000, bytes([0x50, 0x60, 0x70, 0x80])),
    EOF,
]
write("two_regions.hex", two, "regions at 0x00000 and 0x10000")

# ---------------------------------------------------------------------------
# malformed_image.hex - valid data surrounding records that must be ignored
#   * a non-HEX comment line
#   * a valid type 03 start-segment record (ignored by the loader)
#   * a valid type 05 start-linear record (ignored by the loader)
#   * a type 00 record with a deliberately corrupted checksum
# The valid data at 0x0000 and 0x0008 remains, with 0x0004..0x0007 as a
# hole.  This checks that malformed records do not write stale payload data.
# ---------------------------------------------------------------------------
malformed_good = record(0x0000, bytes([0x10, 0x20, 0x30, 0x40]))
malformed_bad = record(0x0004, bytes([0xAA, 0xBB, 0xCC, 0xDD]))
malformed_bad = malformed_bad[:-2] + ("00" if malformed_bad[-2:] != "00" else "01")
malformed = [
    "this line is intentionally ignored",
    typed_record(0x0000, 0x03, bytes([0x00, 0x00, 0x00, 0x00])),
    malformed_good,
    malformed_bad,
    typed_record(0x0000, 0x05, bytes([0x00, 0x00, 0x00, 0x00])),
    record(0x0008, bytes([0x80, 0x81, 0x82, 0x83])),
    EOF,
]
write("malformed_image.hex", malformed,
      "valid records around ignored and bad-checksum records")

# ---------------------------------------------------------------------------
# boundary_image.hex - exact 64 KiB transition using type 04
#   0x0000FFFC..0x0000FFFF: 11 22 33 44
#   0x00010000..0x00010003: 55 66 77 88
# With GC_GAP_BYTES=0 these adjacent records are one region.  The first
# record ends exactly at the 16-bit address limit, so this catches a parser
# that mishandles the extended-address update or a record boundary.
# ---------------------------------------------------------------------------
boundary = [
    record(0xFFFC, bytes([0x11, 0x22, 0x33, 0x44])),
    ext_linear(0x0001),
    record(0x0000, bytes([0x55, 0x66, 0x77, 0x88])),
    EOF,
]
write("boundary_image.hex", boundary,
      "adjacent records across the exact 64 KiB boundary")

# ---------------------------------------------------------------------------
# bridge_image.hex - transitive region merge
#   0x0000..0x0003 and 0x2004..0x2007 are too far apart to merge directly
#   with GC_GAP_BYTES=4096.  The record at 0x1004 is close enough to both,
#   so all three records must merge into one extent.  Addresses in between
#   are holes inside the merged region, not misses.
# ---------------------------------------------------------------------------
bridge = [
    record(0x0000, bytes([0xA0, 0xA1, 0xA2, 0xA3])),
    record(0x1004, bytes([0xB0, 0xB1, 0xB2, 0xB3])),
    record(0x2004, bytes([0xC0, 0xC1, 0xC2, 0xC3])),
    EOF,
]
write("bridge_image.hex", bridge,
      "three records requiring a transitive region merge")

# ---------------------------------------------------------------------------
# demo_image.hex - four 64 byte blocks, 4096 bytes apart, byte(A) pattern
#   0x1000 0x2000 0x3000 0x4000, 64 bytes each
# With GC_GAP_BYTES = 256 the blocks are 4 regions; with GC_GAP_BYTES = 8192
# they merge into 1 sparse region and the space between them reads as zero.
# ---------------------------------------------------------------------------
demo: list[str] = []
for block in range(4):
    base = 0x1000 * (block + 1)
    for off in range(0, 64, 16):
        demo.append(
            record(base + off, bytes(pattern(base + off + i) for i in range(16)))
        )
write("demo_image.hex", demo + [EOF], "4 blocks of 64 B at 0x1000..0x4000")
