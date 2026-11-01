# Integer helpers for the screens, and a builder for the "BADA" 1-bit frame blob.
# Builtins only, so `fix eval` runs it standalone. Strings cannot hold NUL, so a blob
# is emitted as hex (fix eval --raw | xxd -r -p).
#
# BADA (little-endian): magic "BADA", u16 width, u16 height, u16 fps, u16 flags (0),
# u32 frame_count, then frames of width*(height/8) bytes, page-major:
# byte[page*width + col], bit `row` = pixel (col, page*8+row).
rec {
  # [a, a+1, ..., a+n-1]
  range = a: n: builtins.genList (i: a + i) n;
  concatMap = f: xs: builtins.concatLists (map f xs);

  # 2^n by repeated doubling (no bit-shift builtin in Nix).
  p2 = n: builtins.foldl' (acc: _: acc * 2) 1 (builtins.genList (i: i) n);
  # a mod b (no builtins.mod; Nix integer division floors for non-negatives).
  mod = a: b: a - (a / b) * b;

  # little-endian byte lists
  u16 = n: [
    (mod n 256)
    (mod (n / 256) 256)
  ];
  u32 = n: [
    (mod n 256)
    (mod (n / 256) 256)
    (mod (n / 65536) 256)
    (mod (n / 16777216) 256)
  ];

  # Pack one frame into page-major bytes. `px` is `col: row: bool` (true = lit).
  packFrame =
    {
      width,
      height,
      px,
    }:
    let
      pages = height / 8;
    in
    concatMap (
      page:
      map (
        col: builtins.foldl' (b: row: b + (if px col (page * 8 + row) then p2 row else 0)) 0 (range 0 8)
      ) (range 0 width)
    ) (range 0 pages);

  # Whole blob as a byte list. `frames` is a list of `col: row: bool` functions.
  badaBytes =
    {
      width,
      height,
      fps,
      frames,
    }:
    let
      count = builtins.length frames;
    in
    [
      66
      65
      68
      65
    ] # "BADA"
    ++ u16 width
    ++ u16 height
    ++ u16 fps
    ++ u16 0 # flags = 0 (uncompressed)
    ++ u32 count
    ++ concatMap (
      f:
      packFrame {
        inherit width height;
        px = f;
      }
    ) frames;

  # Byte list -> lowercase hex string.
  hex =
    bytes:
    let
      d = "0123456789abcdef";
    in
    builtins.concatStringsSep "" (
      map (b: "${builtins.substring (b / 16) 1 d}${builtins.substring (mod b 16) 1 d}") bytes
    );

  # An animation spec -> hex blob string (the thing `fix eval --raw` prints).
  badaHex = spec: hex (badaBytes spec);
}
