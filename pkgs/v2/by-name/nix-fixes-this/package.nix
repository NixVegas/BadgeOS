# "Nix Fixes This": a 1280x720 software-rendered demoscene prod with a chiptune.
# font8x8_basic.h is Daniel Hepper's, public domain.
{
  lib,
  stdenv,
  callPackage,
  sdl3,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "nix-fixes-this";
  version = "1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./demo.c
      ./font8x8_basic.h
    ];
  };

  buildInputs = [ sdl3 ];

  buildPhase = ''
    runHook preBuild
    $CC -O3 -ffast-math -Wall demo.c -o nix-fixes-this -lSDL3 -lm
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 nix-fixes-this $out/bin/nix-fixes-this
    runHook postInstall
  '';

  passthru.tests.selftest = callPackage ./test.nix { nix-fixes-this = finalAttrs.finalPackage; };

  meta.description = "Software-rendered 1280x720 demoscene prod with a chiptune, for the SG2000 badge";
})
