# Fire: per-LED red/orange flicker, never fully dark. Contract: see leds-live.nix.
scope:
let
  mod = a: b: a - (a / b) * b;
  # Overflow-safe 16-bit hash, as in sparkle.nix.
  hash = x: mod (mod x 65536 * 40503) 65536;

  bucket = mod (scope.t / 66) 65536; # flicker rate, bounded

  led =
    i:
    let
      h = hash (i * 6271 + bucket * 15485863);
      # Ember floor 96 + flicker up to 159 above it.
      v = 96 + mod h 160;
    in
    v * 65536 + (v / 3) * 256; # red + a third green = orange
in
{
  bitmap = builtins.genList led scope.width;
  nextMs = 45;
}
