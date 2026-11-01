# Starfield: fixed star seeds, each flying toward the viewer and projected:
#
#   z    = ((z0 - t*speed) mod ZRANGE) + ZNEAR      (wraps -> respawn far)
#   col  = CX + sx * FOCAL / z
#   row  = CY + sy * FOCAL / z
#
# Near stars are drawn as a 3px streak. Lit pixels collect in a per-column map of page
# bytes, read back to pack the bitmap (same layout as xor-munch.nix).
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

  focal = 70; # projection focal length (smaller = wider FOV, more on-panel)
  znear = 6; # nearest depth before a star wraps
  zrange = 200; # depth span the field occupies
  nStars = 170; # star count (dense enough to read as a starfield, still cheap)

  # A hash of the index seeds each star; z0 is its phase into the depth sweep.
  hash =
    n:
    let
      h = (n * 2654435761 + 1013904223);
    in
    h - (h / 2147483647) * 2147483647;
  mod = a: b: a - (a / b) * b;
  seeds = builtins.genList (
    i:
    let
      h0 = hash (i + 1);
      h1 = hash (h0 + 7);
      h2 = hash (h1 + 13);
    in
    {
      sx = mod h0 241 - 120;
      sy = mod h1 241 - 120;
      z0 = mod h2 zrange;
    }
  ) nStars;

  colPage = builtins.genList (i: {
    page = i / intsPerPage;
    col0 = (i - (i / intsPerPage) * intsPerPage) * 4;
  }) nInts;

  emptyRow = builtins.genList (_: 0) pages;
in
scope:
let
  speed = scope.t / 12;

  # On-panel stars as { x; y; big; }, big = near.
  points = builtins.foldl' (
    acc: s:
    let
      z = mod (s.z0 + zrange - mod speed zrange) zrange + znear;
      x = cx + s.sx * focal / z;
      y = cy + s.sy * focal / z;
      big = z < znear + 26; # near stars streak
    in
    if x >= 0 && x < width && y >= 0 && y < height then acc ++ [ { inherit x y big; } ] else acc
  ) [ ] seeds;

  # OR pixel (x,y) into the column map `m`.
  setPx =
    m: x: y:
    if x < 0 || x >= width || y < 0 || y >= height then
      m
    else
      let
        k = toString x;
        cur = if m ? ${k} then m.${k} else emptyRow;
        pg = y / 8;
        r = y - pg * 8;
        upd = builtins.genList (
          p: if p == pg then builtins.bitOr (builtins.elemAt cur p) (bit r) else builtins.elemAt cur p
        ) pages;
      in
      m // { ${k} = upd; };

  litByCol = builtins.foldl' (
    m: pt:
    let
      m1 = setPx m pt.x pt.y;
    in
    if pt.big then setPx (setPx m1 pt.x (pt.y - 1)) pt.x (pt.y + 1) else m1
  ) { } points;

  colBytesAt =
    x:
    let
      k = toString x;
    in
    if litByCol ? ${k} then litByCol.${k} else emptyRow;

  frame = builtins.genList (
    i:
    let
      cp = builtins.elemAt colPage i;
      c0 = cp.col0;
      pg = cp.page;
      b0 = builtins.elemAt (colBytesAt c0) pg;
      b1 = builtins.elemAt (colBytesAt (c0 + 1)) pg;
      b2 = builtins.elemAt (colBytesAt (c0 + 2)) pg;
      b3 = builtins.elemAt (colBytesAt (c0 + 3)) pg;
    in
    b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
  ) nInts;
in
{
  bitmap = frame;
  nextMs = 33;
}
