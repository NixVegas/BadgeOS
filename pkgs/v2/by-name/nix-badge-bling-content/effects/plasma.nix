# Plasma: four sine fields, Bayer-dithered to 1 bit:
#
#   v(x,y,p) = SIN[x*3 + t1] + SIN[y*5 + t2] + SIN[x+y + t3] + SIN[dist(x,y) + t4]
#   lit  <=>  v + 240 > bayer[y&3][x&3] * 30
#
# SIN is a 256-entry integer table, amplitude +-60. The field depends on t only through
# a phase p in 0..31 (t1..t4 = p*8, p*13, p*5, p*21), so the 32 frames sit in the outer
# let, each computed the first time it is shown (as in xor-munch.nix).
let
  p2 = n: builtins.foldl' (a: _: a * 2) 1 (builtins.genList (i: i) n);
  pow = builtins.genList (r: p2 r) 8;
  bit = r: builtins.elemAt pow r;

  width = 128;
  height = 64;
  pages = height / 8;
  intsPerPage = width / 4; # 32
  nInts = pages * intsPerPage; # 256

  # A parabolic sine: each half turn is a parabola, scaled to 0..60, sign flipped on the
  # second half.
  sinRaw =
    i:
    let
      p = builtins.bitAnd i 255;
      neg = p >= 128;
      half = if neg then p - 128 else p;
      q = half - 64;
      parab = 64 * 64 - q * q; # 0 .. 4096
      mag = (parab * 60) / 4096; # 0 .. 60
    in
    if neg then 0 - mag else mag;
  SIN = builtins.genList sinRaw 256;
  sinAt = i: builtins.elemAt SIN (builtins.bitAnd i 255);

  cx = 64;
  cy = 32;
  # Integer sqrt (Newton).
  isqrt =
    n:
    if n <= 0 then
      0
    else
      let
        step = g: (g + n / g) / 2;
        g0 = 1 + n / 2;
        g1 = step g0;
        g2 = step g1;
        g3 = step g2;
        g4 = step g3;
        g5 = step g4;
        g6 = step g5;
      in
      let
        g = g6;
      in
      if g * g > n then g - 1 else g;

  hArg = builtins.genList (col: col * 3) width;
  vArg = builtins.genList (row: row * 5) height;
  # Distance from the centre, per (col,row).
  radTab = builtins.genList (
    col:
    builtins.genList (
      row:
      let
        dx = col - cx;
        dy = row - cy;
      in
      isqrt (dx * dx + dy * dy)
    ) height
  ) width;
  radAt = col: row: builtins.elemAt (builtins.elemAt radTab col) row;

  # 4x4 ordered dither, levels 0..15; scaled by 30 to the biased 0..480 sum range.
  bayer = [
    [
      0
      8
      2
      10
    ]
    [
      12
      4
      14
      6
    ]
    [
      3
      11
      1
      9
    ]
    [
      15
      7
      13
      5
    ]
  ];
  bayerAt =
    col: row:
    let
      bx = builtins.bitAnd col 3;
      by = builtins.bitAnd row 3;
    in
    (builtins.elemAt (builtins.elemAt bayer by) bx) * 30;

  colPage = builtins.genList (i: {
    page = i / intsPerPage;
    col0 = (i - (i / intsPerPage) * intsPerPage) * 4;
  }) nInts;

  # The 8 pixels of column x on `page` for one phase.
  colByte =
    t1: t2: t3: t4: x: page:
    let
      base = page * 8;
      ha = builtins.elemAt hArg x; # horizontal arg (col only)
    in
    builtins.foldl' (
      acc: r:
      let
        y = base + r;
        va = builtins.elemAt vArg y;
        v = sinAt (ha + t1) + sinAt (va + t2) + sinAt (x + y + t3) + sinAt (radAt x y + t4);
        lvl = v + 240;
      in
      if lvl > bayerAt x y then acc + bit r else acc
    ) 0 (builtins.genList (i: i) 8);

  # Coprime-ish phase steps, so the fields drift apart across the loop.
  frames = builtins.genList (
    p:
    let
      t1 = p * 8; # horizontal
      t2 = p * 13; # vertical
      t3 = p * 5; # diagonal
      t4 = p * 21; # radial
      cb = colByte t1 t2 t3 t4;
    in
    builtins.genList (
      i:
      let
        cp = builtins.elemAt colPage i;
        c0 = cp.col0;
        pg = cp.page;
        b0 = cb c0 pg;
        b1 = cb (c0 + 1) pg;
        b2 = cb (c0 + 2) pg;
        b3 = cb (c0 + 3) pg;
      in
      b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
    ) nInts
  ) 32;
  font = import <nix-badge/lib/font.nix>;
in
scope:
let
  # Warmup, as in xor-munch.nix.
  warm = scope.frameIndex < 32;
  phase = if warm then scope.frameIndex else builtins.bitAnd (scope.t / 33) 31;
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
