"""probe.py <ppm> <x> <y> <r|g|b>

Exits 0 when the pixel at (x, y) of a binary PPM (P6, 8 bits per channel) is
clearly the named primary: that channel above 150, the other two below 100.
Otherwise prints the pixel and exits 1.
"""

import sys


def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    fields = []
    pos = 0
    while len(fields) < 4:
        while data[pos : pos + 1].isspace():
            pos += 1
        if data[pos : pos + 1] == b"#":
            pos = data.index(b"\n", pos) + 1
            continue
        start = pos
        while not data[pos : pos + 1].isspace():
            pos += 1
        fields.append(data[start:pos])
    magic, width, height, maxval = fields[0], int(fields[1]), int(fields[2]), int(fields[3])
    if magic != b"P6" or maxval != 255:
        sys.exit(f"probe: {path}: not an 8-bit P6 PPM")
    return width, height, data[pos + 1 :]


def main():
    if len(sys.argv) != 5 or sys.argv[4] not in ("r", "g", "b"):
        sys.exit(__doc__.strip().splitlines()[0])
    path, x, y, want = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
    width, height, pixels = read_ppm(path)
    if not (0 <= x < width and 0 <= y < height):
        sys.exit(f"probe: ({x},{y}) is outside the {width}x{height} image")
    i = (y * width + x) * 3
    rgb = dict(zip("rgb", pixels[i : i + 3]))
    if rgb[want] > 150 and all(v < 100 for c, v in rgb.items() if c != want):
        return
    print(f"probe: ({x},{y}) is r={rgb['r']} g={rgb['g']} b={rgb['b']}, not {want}")
    sys.exit(1)


main()
