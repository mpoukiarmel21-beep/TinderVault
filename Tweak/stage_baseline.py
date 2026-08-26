#!/usr/bin/env python3
"""Stage the pristine Mach-O header for IVAntiTamper's self-read redirection.

Run in CI on the ORIGINAL (pre-insert_dylib) main executable. Emits
`ivbaseline.bin` into the app bundle. At runtime IVAntiTamper overlays these
bytes onto the host's reads of its own binary, so an integrity self-check that
re-reads + hashes the on-disk Mach-O sees the untampered header (insert_dylib's
only change is one added load command in the header region; the code pages are
byte-identical to the original).

Usage: stage_baseline.py <pristine-macho> <output-ivbaseline.bin>

Format (little-endian): b"IVB1", u32 regionCount, then per region:
u64 fileOffset, u64 length, <length> bytes.
"""
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF   # thin 64-bit little-endian
FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFECA

PAGE = 0x4000              # 16 KiB — iOS code-signing page size
MIN_REGION = 0x10000       # 64 KiB floor: cover any fixed first-chunk hash


def round_up(x, a):
    return ((x + a - 1) // a) * a


def main():
    if len(sys.argv) != 3:
        sys.stderr.write("usage: stage_baseline.py <macho> <out.bin>\n")
        return 2

    src, out = sys.argv[1], sys.argv[2]
    with open(src, "rb") as f:
        data = f.read()

    if len(data) < 32:
        sys.stderr.write("ERROR: file too small to be a Mach-O\n")
        return 1

    magic = struct.unpack_from("<I", data, 0)[0]
    if magic in (FAT_MAGIC, FAT_CIGAM) or struct.unpack_from(">I", data, 0)[0] in (FAT_MAGIC, FAT_CIGAM):
        # iOS installs thin arm64 slices; a fat binary here means the pipeline's
        # thinning assumption is broken. Fail loudly rather than stage garbage.
        sys.stderr.write("ERROR: FAT binary — expected thin arm64. Thin it before staging.\n")
        return 1
    if magic != MH_MAGIC_64:
        sys.stderr.write("ERROR: not a thin 64-bit Mach-O (magic=0x%08x)\n" % magic)
        return 1

    # mach_header_64: magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved
    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    header_len = 32 + sizeofcmds
    region_len = max(round_up(header_len, PAGE), MIN_REGION)
    if region_len > len(data):
        region_len = len(data)
    region = data[:region_len]

    with open(out, "wb") as f:
        f.write(b"IVB1")
        f.write(struct.pack("<I", 1))              # one region
        f.write(struct.pack("<QQ", 0, len(region)))  # offset 0, length
        f.write(region)

    sys.stderr.write(
        "staged %d bytes (ncmds=%d sizeofcmds=%d header_len=%d) -> %s\n"
        % (len(region), ncmds, sizeofcmds, header_len, out)
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
