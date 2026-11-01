# Sparkle: each LED hashes (index, time bucket) and lights when the hash clears a
# threshold. Contract: see leds-live.nix.
scope:
let
  mod = a: b: a - (a / b) * b;

  # Reduce to 16 bits before the multiply: with `t` in ms since boot the raw product
  # overflows i64 within the hour, and fix raises IntegerOverflow.
  hash = x: mod (mod x 65536 * 40503) 65536;

  bucket = mod (scope.t / 100) 65536; # twinkle lifetime 100 ms, bounded

  led =
    i:
    let
      h = hash (i * 7919 + bucket * 104729);
    in
    # ~1 LED in 6 lit per bucket.
    if mod h 6 == 0 then
      let
        v = 128 + mod h 128;
      in
      v * 65536 + v * 256 + v # white-ish
    else
      0;
in
{
  bitmap = builtins.genList led scope.width;
  nextMs = 50;
}
