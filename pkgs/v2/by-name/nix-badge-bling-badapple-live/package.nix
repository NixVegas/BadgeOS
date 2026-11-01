# Bad Apple!! as a pure-Nix screen: emit_delta.c re-encodes the badapple blob as
# keyframes and deltas in one flat list, sliced per frame. Flat because per-frame
# attrsets would pin ~400 MB in fix's heap. The format is in badapple-delta.md.
{
  lib,
  stdenv,
  gcc,
  pkgs,
}:
{
  # Must match the runtime OLED.
  width ? 128,
  height ? 32,

  fps ? 20,

  # Clip length cap in seconds; null = the whole song (~219 s, a ~6 MB .nix).
  durationSeconds ? 20,

  # Frame f is a keyframe iff f % K == 0. K = 1 means keyframes only.
  keyframeInterval ? 60,

  badapple ? pkgs.badapple.override {
    inherit
      pkgs
      width
      height
      fps
      durationSeconds
      ;
  },

  name ? "badapple-live",
}:

let
  fbLen = width * height / 8;
  wordsPerFrame = fbLen / 4;
in

assert lib.assertMsg (height / 8 * 8 == height) "badapple-live: height must be a multiple of 8";
assert lib.assertMsg (
  fbLen / 4 * 4 == fbLen
) "badapple-live: frame byte count ${toString fbLen} must be a multiple of 4";

stdenv.mkDerivation {
  pname = name;
  version = "1.0";

  dontUnpack = true;

  nativeBuildInputs = [ gcc ];

  buildPhase = ''
    runHook preBuild

    gcc -O2 -Wall -Wextra -std=c11 -o emit_delta ${./emit_delta.c}

    ./emit_delta ${toString keyframeInterval} < ${badapple}/badapple.bin > badapple-live.nix

    runHook postBuild
  '';

  # Shape only; nix-badge-bling-content evaluates frame 0.
  doCheck = true;
  checkPhase = ''
    runHook preCheck

    blob=${badapple}/badapple.bin
    fc=$(od -An -tu4 -j12 -N4 "$blob" | tr -d ' ')
    echo "badapple-live: blob declares $fc frames"

    grep -q "^  nframes = $fc;" badapple-live.nix || {
      echo "SELF-TEST FAIL: nframes != $fc header frames" >&2; exit 1; }

    # starts has fc+1 entries (a trailing sentinel), ns has fc.
    n_starts=$(grep '^  starts = ' badapple-live.nix | grep -oE '[0-9]+' | wc -l)
    [ "$n_starts" -eq "$(( fc + 1 ))" ] || {
      echo "SELF-TEST FAIL: starts has $n_starts entries != fc+1 = $(( fc + 1 ))" >&2; exit 1; }

    n_ns=$(grep '^  ns = ' badapple-live.nix | grep -oE '[0-9]+' | wc -l)
    [ "$n_ns" -eq "$fc" ] || {
      echo "SELF-TEST FAIL: ns has $n_ns entries != $fc" >&2; exit 1; }

    K=${toString keyframeInterval}
    keys=$(( ( fc + K - 1 ) / K ))
    grep -q "^  keyint = $K;" badapple-live.nix || {
      echo "SELF-TEST FAIL: keyint != $K" >&2; exit 1; }

    echo "SELF-TEST PASS: $fc frames flat (starts=$n_starts, ns=$n_ns, $keys keyframes @ K=$K)"

    echo "$fc" > .fc
    echo "$keys" > .keys

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    install -Dm644 badapple-live.nix "$out/badapple-live.nix"

    fc=$(cat .fc)
    keys=$(cat .keys)
    size=$(stat -c%s "$out/badapple-live.nix")
    {
      echo "badapple-live.nix: pure-Nix Bad Apple delta pattern (fix applyValue per frame)"
      echo "format:       delta codec v1 (see badapple-delta.md)"
      echo "geometry:     ${toString width}x${toString height} (${toString fbLen} bytes/frame)"
      echo "keyframe:     ${toString wordsPerFrame} ints (4 page-bytes/int, LE)"
      echo "delta:        variable ints/frame (2 change entries/int, E = offset*256+byte)"
      echo "keyframe_K:   ${toString keyframeInterval} (frame f is a keyframe iff f % K == 0)"
      echo "keyframes:    $keys"
      echo "fps:          ${toString fps}"
      echo "frame_count:  $fc"
      echo "duration_cap: ${
        if durationSeconds == null then "none (full song)" else toString durationSeconds + " s"
      }"
      echo "nix_bytes:    $size"
    } > "$out/badapple-live.info"

    runHook postInstall
  '';

  meta = {
    description = "Bad Apple!! as a pure-Nix per-frame delta pattern for the badge OLED (fix applyValue)";
    longDescription = ''
      A Nix function the badge applies every frame. Each frame is a keyframe or
      a delta of changed (offset,byte) pairs; see badapple-delta.md.
    '';
    platforms = lib.platforms.all; # build-host tool; output is arch-neutral Nix text
  };
}
