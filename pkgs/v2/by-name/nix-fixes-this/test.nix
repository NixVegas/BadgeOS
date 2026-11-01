# nix-fixes-this --selftest, then the same frame of scene 0 dumped twice: the two
# PPMs must be well formed and byte-identical, or --dump cannot compare builds.
# 6.04 s is 33 ms after a kick, so the frame also goes through the beat (g_kick).
{ runCommand, nix-fixes-this }:
runCommand "nix-fixes-this-selftest" { nativeBuildInputs = [ nix-fixes-this ]; } ''
  nix-fixes-this --selftest

  nix-fixes-this --dump 0:6.04:a.ppm
  nix-fixes-this --dump 0:6.04:b.ppm
  cmp a.ppm b.ppm

  { read -r magic; read -r w h; read -r maxval; } < a.ppm
  test "$magic $maxval" = "P6 255"
  header=$(printf 'P6\n%s %s\n255\n' "$w" "$h" | wc -c)
  test "$(stat -c %s a.ppm)" -eq $((header + w * h * 3))

  touch $out
''
