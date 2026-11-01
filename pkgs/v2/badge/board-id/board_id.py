#!/usr/bin/env python3
# Badge board-identity codec: pack a nix-badge-board store path losslessly
# into the 40-byte SG2000 eFuse USER area, and the 8-char serial into the 8-byte
# DEVICE_ID area, then read them back to reconstruct the descriptor at runtime.
#
# The USER area is a 320-bit record; the layout (MSB-first, fields in this order):
#
#   epoch       3 bits   record-format version, starts at 1 (001). Bump to change
#                        this layout without confusing an old decoder.
#   nix32 hash  160 bits 32 chars x 5 bits, the store-path input hash, each char
#                        stored as its index in nix's base32 alphabet (lossless).
#   drv name    105 bits 15 chars x 7-bit ASCII, NUL-padded ("nix-badge-board").
#   version     7 bits   e.g. 20 -> "2.0" (major = n//10, minor = n%10; max 12.7).
#   tapeout     17 bits  YYYYMMDD - 20250000 (e.g. 20260706 -> 10706); good until
#                        20250000 + 131071 = 20381071, ~13 years before an epoch rev.
#   git         28 bits  first 7 nibbles of the short commit (e.g. 0x07f6efc).
#                        --------
#                        320 bits = 40 bytes = the whole USER area.
#
# The USER area is physically scattered across ten 4-byte eFuse words at
# {0x40,0x48,0x50,0x58,0x60,0x68,0x70,0x78,0x80,0x88} (cvi_efuse_user[] in
# cmd/efuse.c). `efusew USER <hex>` and CVI_EFUSE_Read gather/scatter for us, so
# the 40-byte blob is contiguous/logical; only the raw-nvmem reader must gather.

import sys

NIX32 = "0123456789abcdfghijklmnpqrsvwxyz"  # nix base32 alphabet (no e,o,u,t)

# Physical byte offsets of the ten USER words in the raw 256-byte eFuse image.
USER_WORDS = [0x40, 0x48, 0x50, 0x58, 0x60, 0x68, 0x70, 0x78, 0x80, 0x88]
DEVICE_ID_OFF = 0x8C
DEVICE_ID_LEN = 8

NAME_CHARS = 15
EPOCH = 1
TAPEOUT_BASE = 20250000


class BitWriter:
    def __init__(self):
        self.bits = []

    def put(self, val, n):
        if val < 0 or val >= (1 << n):
            raise ValueError(f"value {val} does not fit in {n} bits")
        for i in range(n - 1, -1, -1):
            self.bits.append((val >> i) & 1)

    def bytes(self):
        if len(self.bits) % 8:
            raise ValueError(f"bit count {len(self.bits)} not byte-aligned")
        out = bytearray(len(self.bits) // 8)
        for i, b in enumerate(self.bits):
            out[i // 8] |= b << (7 - (i % 8))
        return bytes(out)


class BitReader:
    def __init__(self, data):
        self.bits = [(byte >> (7 - i)) & 1 for byte in data for i in range(8)]
        self.pos = 0

    def get(self, n):
        val = 0
        for _ in range(n):
            val = (val << 1) | self.bits[self.pos]
            self.pos += 1
        return val


def parse_store_path(path):
    """/nix/store/<32 nix32>-<name>-<major.minor>-<YYYYMMDD>-<git7> -> fields."""
    base = path.split("/")[-1]
    h, rest = base[:32], base[33:]  # 32-char hash, then '-', then the rest
    if base[32] != "-":
        raise ValueError("expected '-' after the 32-char hash")
    ver, date, git = rest.rsplit("-", 2)
    name = ver[: ver.rfind("-")]           # drv name is everything before -<ver>
    version_str = ver[ver.rfind("-") + 1:]  # "2.0"
    major, minor = version_str.split(".")
    return {
        "hash": h,
        "name": name,
        "version": int(major) * 10 + int(minor),
        "tapeout": int(date) - TAPEOUT_BASE,
        "git": int(git, 16),
        "version_str": version_str,
        "date": date,
        "git_str": git,
    }


def encode_user(f):
    w = BitWriter()
    w.put(EPOCH, 3)
    if len(f["hash"]) != 32:
        raise ValueError("hash must be 32 nix32 chars")
    for c in f["hash"]:
        w.put(NIX32.index(c), 5)
    name = f["name"].encode("ascii")
    if len(name) > NAME_CHARS:
        raise ValueError(f"name >{NAME_CHARS} chars")
    name = name.ljust(NAME_CHARS, b"\x00")
    for b in name:
        w.put(b, 7)
    w.put(f["version"], 7)
    w.put(f["tapeout"], 17)
    w.put(f["git"], 28)
    return w.bytes()


# Omission rule: a component that is 0 (version/tapeout/git) or an empty name
# (a leading-NUL 15-char field) is unset and must be dropped from the rebuilt
# strings, never emit an empty "-" segment or a stray field.
def build_store_path(h, name, version, version_str, tapeout, date, git, git_str):
    s = "/nix/store/" + h
    if name:
        s += "-" + name
    if version:
        s += "-" + version_str
    if tapeout:
        s += "-" + date
    if git:
        s += "-" + git_str
    return s


def build_product(name, version, version_str, tapeout, date, git, git_str):
    s = name if name else ""
    if version:
        s = (s + " " if s else "") + version_str
    extras = ([date] if tapeout else []) + ([git_str] if git else [])
    if extras:
        s = (s + " " if s else "") + "(" + ", ".join(extras) + ")"
    return s


def decode_user(blob):
    r = BitReader(blob)
    epoch = r.get(3)
    if epoch != EPOCH:
        raise ValueError(f"unknown record epoch {epoch}")
    h = "".join(NIX32[r.get(5)] for _ in range(32))
    # NUL-terminated: a leading NUL means the name is empty (omission rule).
    name = bytes(r.get(7) for _ in range(NAME_CHARS)).split(b"\x00", 1)[0].decode("ascii")
    version = r.get(7)
    tapeout = r.get(17)
    git = r.get(28)
    version_str = f"{version // 10}.{version % 10}"
    date = f"{tapeout + TAPEOUT_BASE:08d}"
    git_str = f"{git:07x}"
    return {
        "epoch": epoch, "hash": h, "name": name, "version": version,
        "version_str": version_str, "tapeout": tapeout, "date": date,
        "git": git, "git_str": git_str,
        "store_path": build_store_path(h, name, version, version_str, tapeout, date, git, git_str),
        "product": build_product(name, version, version_str, tapeout, date, git, git_str),
    }


def encode_serial(serial):
    b = serial.encode("ascii")
    if len(b) > DEVICE_ID_LEN:
        raise ValueError(f"serial >{DEVICE_ID_LEN} bytes")
    return b.ljust(DEVICE_ID_LEN, b"\x00")


def gather_user(raw256):
    """Reassemble the logical 40-byte USER blob from the scattered raw eFuse."""
    return b"".join(raw256[off:off + 4] for off in USER_WORDS)


def main():
    if len(sys.argv) < 2:
        print("usage: board_id.py <store_path> [serial]", file=sys.stderr)
        return 2
    path = sys.argv[1]
    serial = sys.argv[2] if len(sys.argv) > 2 else "SG1-0001"

    f = parse_store_path(path)
    user = encode_user(f)
    did = encode_serial(serial)

    # Round-trip proof.
    back = decode_user(user)
    ok = back["store_path"] == path
    did_back = did.rstrip(b"\x00").decode("ascii")

    print(f"input store path : {path}")
    print(f"  hash    : {f['hash']}")
    print(f"  name    : {f['name']}")
    print(f"  version : {f['version_str']}  (int {f['version']})")
    print(f"  tapeout : {f['date']}  (offset {f['tapeout']})")
    print(f"  git     : {f['git_str']}  (0x{f['git']:07x})")
    print()
    print(f"USER  (40 B): {user.hex()}")
    print(f"DEVICE_ID(8B): {did.hex()}   ascii={did_back!r}")
    print()
    print(f"round-trip store path : {back['store_path']}")
    print(f"product string (iProduct) : {back['product']}")
    print(f"round-trip serial     : {did_back}")
    print(f"LOSSLESS: {'YES' if ok and did_back == serial else 'NO !!!'}")
    print()
    print("# Burn (U-Boot, IRREVERSIBLE OTP -- USER/DEVICE_ID have no lock bits):")
    print(f"efusew USER {user.hex()}")
    print(f"efusew DEVICE_ID {did.hex()}")
    return 0 if ok and did_back == serial else 1


if __name__ == "__main__":
    sys.exit(main())
