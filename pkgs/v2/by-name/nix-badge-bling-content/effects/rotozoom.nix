# Rotozoomer: a tiled 32x32 texture, rotated and zoomed under the panel:
#
#   dx = x - CX ; dy = y - CY
#   u  = ( dx*cos + dy*sin ) * zoom / 4096 + panX     (cos, sin scale 256; zoom scale 16)
#   v  = (-dx*sin + dy*cos ) * zoom / 4096 + panY
#   lit = tex[v & 31] bit (u & 31)
#
# Angle, zoom and pan depend on t only through a phase p in 0..31 (one full turn per
# loop), so the 32 frames sit in the outer let, as in xor-munch.nix.
let
  p2 = n: builtins.foldl' (a: _: a * 2) 1 (builtins.genList (i: i) n);
  pow = builtins.genList (r: p2 r) 8;
  bit = r: builtins.elemAt pow r;

  width = 128;
  height = 64;
  pages = height / 8;
  intsPerPage = width / 4;
  nInts = pages * intsPerPage;
  cx = 64;
  cy = 32;

  # Parabolic sine as in plasma.nix, amplitude +-256, 256 entries per turn.
  sinRaw =
    i:
    let
      p = builtins.bitAnd i 255;
      neg = p >= 128;
      half = if neg then p - 128 else p;
      q = half - 64;
      parab = 64 * 64 - q * q; # 0..4096
      mag = (parab * 256) / 4096; # 0..256
    in
    if neg then 0 - mag else mag;
  SIN = builtins.genList sinRaw 256;
  sinAt = i: builtins.elemAt SIN (builtins.bitAnd i 255);
  cosAt = i: sinAt (i + 64);

  # The texture: 32 row masks, bit c = column c lit.
  tw = 32;
  th = 32;
  twMask = 31;
  thMask = 31;
  p2big = builtins.genList (r: p2 r) tw;
  # An 8x8 checkerboard XOR'd with a thin weave: a plaid that survives rotation.
  texRowFull =
    v:
    builtins.foldl' (
      acc: u:
      let
        checker = builtins.bitXor (builtins.bitAnd u 8) (builtins.bitAnd v 8) != 0;
        weave = builtins.bitAnd (builtins.bitXor u v) 6 == 0;
        litp = if checker then !weave else weave;
      in
      if litp then acc + builtins.elemAt p2big u else acc
    ) 0 (builtins.genList (i: i) tw);
  TEX = builtins.genList texRowFull th;
  texAt =
    u: v:
    let
      uu = builtins.bitAnd u twMask;
      vv = builtins.bitAnd v thMask;
      rowmask = builtins.elemAt TEX vv;
    in
    builtins.bitAnd (rowmask / (builtins.elemAt p2big uu)) 1 == 1;

  colPage = builtins.genList (i: {
    page = i / intsPerPage;
    col0 = (i - (i / intsPerPage) * intsPerPage) * 4;
  }) nInts;

  # The 8 pixels of column x on `page` for one phase.
  colByte =
    co: si: zoom: panX: panY: x: page:
    let
      base = page * 8;
      dx = x - cx;
    in
    builtins.foldl' (
      acc: r:
      let
        y = base + r;
        dy = y - cy;
        u = ((dx * co + dy * si) * zoom) / 4096 + panX;
        v = ((dy * co - dx * si) * zoom) / 4096 + panY;
      in
      if texAt u v then acc + bit r else acc
    ) 0 (builtins.genList (i: i) 8);

  frames = builtins.genList (
    p:
    let
      ang = p * 8;
      co = cosAt ang;
      si = sinAt ang;
      # 8..40 (0.5x .. 2.5x), one breath per loop.
      zoom = 24 + (sinAt (p * 8) * 16) / 256;
      pt = p * 160;
      panX = pt / 40;
      panY = pt / 55;
      cb = colByte co si zoom panX panY;
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
  # Warmup, as in xor-munch.nix. Then a full spin takes ~2 s.
  warm = scope.frameIndex < 32;
  phase = if warm then scope.frameIndex else builtins.bitAnd (scope.t / 66) 31;
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
