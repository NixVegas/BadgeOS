#!/usr/bin/env python3
"""Check Sophgo's prebuilt BL31 (no source exists) against a board's DRAM, from three
facts read out of its code:

  - its footprint: it runs at the DRAM base, and its RW data ends at __RW_END__, which
    must stay below the next stage (U-Boot's text base);
  - its page tables: the normal-memory region from the DRAM base must cover all of DRAM;
  - its PSCI: the highest non-secure entry point it accepts must reach the DRAM top.

The offsets are those of the blob sophgone pins; another blob needs them found again.

usage: check-bl31.py BL31 DRAM_BASE DRAM_SIZE NEXT_STAGE_BASE
"""

import struct
import sys

blob = open(sys.argv[1], "rb").read()
base, size, next_base = (int(a, 0) for a in sys.argv[2:5])
top = base + size


def word(off):
    return struct.unpack_from("<I", blob, off)[0]


def quad(off):
    return struct.unpack_from("<Q", blob, off)[0]


def expect(off, mask, value, what):
    ins = word(off)
    if ins & mask != value:
        sys.exit(f"check-bl31: {off:#x} is {ins:#010x}, not {what}")
    return ins


def check(ok, msg):
    if not ok:
        sys.exit(f"check-bl31: {msg}")
    print(f"check-bl31: {msg}: ok")


# bl31_entrypoint: `ldr x1, =__RW_END__` for the RW-data invalidate.
ins = expect(0x9C, 0xFF00001F, 0x58000001, "ldr x1, <literal>")
limit = quad(0x9C + ((ins >> 5) & 0x7FFFF) * 4)
check(base < limit <= next_base, f"BL31 spans {base:#x}..{limit:#x}, below {next_base:#x}")

# The platform setup: `adrp x0, <page>; add x0, x0, #<off>; bl mmap_add`.
ins = expect(0x3B64, 0x9F00001F, 0x90000000, "adrp x0")
page = ((((ins >> 5) & 0x7FFFF) << 2 | (ins >> 29) & 3) << 12) + (0x3B64 & ~0xFFF)
ins = expect(0x3B68, 0xFFC003FF, 0x91000000, "add x0, x0, #imm")
regions = page + ((ins >> 10) & 0xFFF)
off, window = regions, 0
while quad(off + 16):
    pa, va, length = quad(off), quad(off + 8), quad(off + 16)
    if pa == va == base:
        window = length
    off += 32
check(window >= size, f"the DRAM region maps {window:#x} bytes from {base:#x}, all {size:#x}")

# PSCI's entry-point check: `sub x19, x19, #lo, lsl #12; mov x0, #hi0; movk x0, #hi1,
# lsl #16; cmp x19, x0`, so it takes lo << 12 <= entry <= (lo << 12) + hi.
lo = (expect(0x7C8, 0xFFC003FF, 0xD1400273, "sub x19, x19, #imm, lsl #12") >> 10) & 0xFFF
hi0 = (expect(0x7CC, 0xFFE0001F, 0xD2800000, "movz x0, #imm") >> 5) & 0xFFFF
hi1 = (expect(0x7D0, 0xFFE0001F, 0xF2A00000, "movk x0, #imm, lsl #16") >> 5) & 0xFFFF
expect(0x7D4, 0xFFFFFFFF, 0xEB00027F, "cmp x19, x0")
bound = (lo << 12) + (hi1 << 16 | hi0) + 1
check(bound >= top, f"PSCI takes entry points below {bound:#x}, up to the DRAM top {top:#x}")
