# XOR "munching squares":
#
#   pixel(x,y) lit  <=>  ((x ^ y) + phase) & 31 < 16
#
# Bitmap: 1024 GDDRAM bytes as 256 little-endian ints; int i covers page i/32, columns
# (i%32)*4 .. +3. Only 32 phases exist, so all 32 frames sit in the outer let, each
# computed the first time it is shown.
let
  # 2^n (no shift builtin).
  p2 = n: builtins.foldl' (a: _: a * 2) 1 (builtins.genList (i: i) n);
  pow = [
    (p2 0)
    (p2 1)
    (p2 2)
    (p2 3)
    (p2 4)
    (p2 5)
    (p2 6)
    (p2 7)
  ];
  bit = r: builtins.elemAt pow r; # 2^r for r in 0..7

  width = 128;
  height = 64;
  pages = height / 8; # 8
  intsPerPage = width / 4; # 32
  nInts = pages * intsPerPage; # 256

  colPage = builtins.genList (i: {
    page = i / intsPerPage;
    col0 = (i - (i / intsPerPage) * intsPerPage) * 4;
  }) nInts;

  mask5 = 31;

  # The 8 pixels of column x on `page` for phase p.
  colByte =
    p: x: page:
    let
      base = page * 8;
    in
    builtins.foldl' (
      acc: r:
      let
        y = base + r;
        v = builtins.bitAnd (builtins.bitXor x y + p) mask5;
      in
      if v < 16 then acc + bit r else acc
    ) 0 (builtins.genList (i: i) 8);

  frames = builtins.genList (
    p:
    builtins.genList (
      i:
      let
        cp = builtins.elemAt colPage i;
        c0 = cp.col0;
        pg = cp.page;
        b0 = colByte p c0 pg;
        b1 = colByte p (c0 + 1) pg;
        b2 = colByte p (c0 + 2) pg;
        b3 = colByte p (c0 + 3) pg;
      in
      b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
    ) nInts
  ) 32;
  font = import <nix-badge/lib/font.nix>;
in
scope:
let
  # Warmup: frameIndex restarts at 0 on screen entry, so the first 32 renders compute
  # one frame each under a "WARM n/32" overlay. After that the phase follows t.
  warm = scope.frameIndex < 32;
  phase = if warm then scope.frameIndex else builtins.bitAnd (scope.t / 24) mask5;
  f = builtins.elemAt frames phase;
  hud = font.renderText {
    text = "WARM ${toString (phase + 1)}/32";
    x = 0;
    page = 0;
    width = 128;
  };
in
{
  # A fresh copy, so forcing the bitmap pins no per-frame garbage into the table.
  bitmap = builtins.genList (i: builtins.elemAt f i) nInts;
  nextMs = if warm then 1 else 33;
  overlay = if warm then hud.overlay else [ ];
  overlayN = if warm then hud.overlayN else 0;
}
