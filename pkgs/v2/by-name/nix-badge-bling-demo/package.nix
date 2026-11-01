# Bakes a pure-Nix animation (demo.nix, leds-demo.nix) into a BADA or BLED blob with fix.
{
  runCommand,
  xxd,
}:
{
  fix,
  # Relative to the content dir; evaluates to the blob as hex.
  entry ? "demo.nix",
  name ? "bling-anim",
}:
runCommand "${name}.bin"
  {
    nativeBuildInputs = [
      fix
      xxd
    ];
    src = ../nix-badge-bling-content;
  }
  ''
    mkdir -p "$out"
    out_bin="$out/${name}.bin"
    fix eval --raw "$src/${entry}" | xxd -r -p > "$out_bin"

    # The size must match the header: 16 + count*w*h/8 (BADA) or 12 + count*nleds*3 (BLED).
    magic=$(head -c 4 "$out_bin")
    a=$(od -An -tu2 -j4 -N2 "$out_bin" | tr -d ' ')  # width | nleds
    total=$(wc -c < "$out_bin")
    case "$magic" in
      BADA)
        h=$(od -An -tu2 -j6 -N2 "$out_bin" | tr -d ' ')
        count=$(od -An -tu4 -j12 -N4 "$out_bin" | tr -d ' ')
        want=$(( 16 + count * a * (h / 8) )) ;;
      BLED)
        count=$(od -An -tu4 -j8 -N4 "$out_bin" | tr -d ' ')
        want=$(( 12 + count * a * 3 )) ;;
      *) echo "bad magic '$magic'"; exit 1 ;;
    esac
    [ "$total" -eq "$want" ] || { echo "size $total != $want ($magic a=$a count=$count)"; exit 1; }
    echo "baked ${name}: $magic, $count frames, $total bytes"
  ''
