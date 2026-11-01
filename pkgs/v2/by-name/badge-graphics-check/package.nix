# Draws colour bars into an SDL window surface and reports the framebuffer's
# format, pitch and update behaviour.
{
  lib,
  stdenv,
  sdl3,
}:
stdenv.mkDerivation {
  pname = "badge-graphics-check";
  version = "1.0";

  src = ./badge-graphics-check.c;

  dontUnpack = true;

  buildInputs = [ sdl3 ];

  buildPhase = ''
    runHook preBuild
    $CC -O2 -Wall $src -o badge-graphics-check -lSDL3
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 badge-graphics-check $out/bin/badge-graphics-check
    runHook postInstall
  '';

  meta = {
    description = "Colour-bar check for SDL window framebuffers";
    mainProgram = "badge-graphics-check";
    platforms = lib.platforms.linux;
  };
}
