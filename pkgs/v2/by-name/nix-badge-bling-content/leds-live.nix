# A rotating rainbow. An LED pattern is a function the runtime applies every frame:
#   scope: { t; width; ... } -> { bitmap = [ <0xRRGGBB int> per LED ]; nextMs = <int>; }
# The ring is width x 1; nextMs is the delay until the next frame.
scope:
let
  mod = a: b: a - (a / b) * b;

  # A 0..255 hue -> packed 0xRRGGBB int (the standard three-phase colour wheel).
  wheel =
    h:
    let
      p = mod h 256;
    in
    if p < 85 then
      (255 - p * 3) * 65536 + (p * 3) * 256 + 0
    else if p < 170 then
      let
        q = p - 85;
      in
      0 * 65536 + (255 - q * 3) * 256 + (q * 3)
    else
      let
        q = p - 170;
      in
      (q * 3) * 65536 + 0 * 256 + (255 - q * 3);
in
{
  # One hue rotation around the ring, advanced by the clock.
  bitmap = builtins.genList (i: wheel (mod (i * 256 / scope.width + scope.t / 8) 256)) scope.width;
  # ~30 fps
  nextMs = 33;
}
