{ lib, stdenv }:

stdenv.mkDerivation {
  pname = "badgedemo";
  version = "1.0";
  src = lib.cleanSource ./.;

  # libm only: it drives the scanout buffer directly.
  buildPhase = ''
    runHook preBuild
    $CC -O3 -Wall -march=armv8-a -o badgedemo badgedemo.c -lm
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 badgedemo $out/bin/badgedemo
    runHook postInstall
  '';

  meta = with lib; {
    description = "A looping 720p demoscene prod for the badge";
    longDescription = ''
      Six procedural parts (plasma, starfield, tunnel, rotozoomer, raymarched
      torus, tunnel reprise) rendered at 640x360 and point-doubled to 1280x720,
      beat-synced to a built-in 5-channel softsynth at 140 BPM. Audio goes out
      over ALSA, which on this badge lands on I2S -> LT8912B -> HDMI. Runs the
      full 90 s loop at 60 fps on the badge's single Cortex-A53.
    '';
    platforms = platforms.linux;
    mainProgram = "badgedemo";
  };
}
