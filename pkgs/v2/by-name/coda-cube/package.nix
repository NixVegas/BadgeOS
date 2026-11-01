# The CODA980 H.264 decoder as a live 3D renderer: a cube decoded from P-pictures
# the A53 writes each frame, in a fullscreen SDL window on sway.
{
  lib,
  stdenv,
  buildPackages,
  pkg-config,
  wayland-scanner,
  sdl3,
  wayland,
  soph-mpi,
  soph-ion-uapi,
}:
stdenv.mkDerivation {
  pname = "coda-cube";
  version = "0.2";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./coda-cube.c
      ./present-dmabuf.c
      ./present-dmabuf.h
    ];
  };

  strictDeps = true;

  nativeBuildInputs = [
    pkg-config
    wayland-scanner
  ];
  buildInputs = [
    sdl3
    wayland
    soph-ion-uapi
  ];

  # -ffp-contract=off: the generator's float operations must not fuse, or the
  # streams stop matching the research model byte for byte.
  buildPhase = ''
    runHook preBuild
    xml=${buildPackages.wayland-protocols}/share/wayland-protocols/stable/linux-dmabuf/linux-dmabuf-v1.xml
    wayland-scanner client-header $xml linux-dmabuf-v1-client-protocol.h
    wayland-scanner private-code $xml linux-dmabuf-v1-protocol.c
    $CC -O2 -mcpu=cortex-a53 -ffp-contract=off -Wall -Wextra -Werror \
      -DCODA_HW -DCODA_SDL -D__CV181X__ -I. -I${soph-mpi}/include \
      coda-cube.c present-dmabuf.c linux-dmabuf-v1-protocol.c -o coda-cube \
      $($PKG_CONFIG --cflags --libs sdl3 wayland-client) -lm -lpthread
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 coda-cube $out/bin/coda-cube
    runHook postInstall
  '';

  meta = {
    description = "The CODA980 H.264 decoder drawing a live 3D cube, scanned out zero-copy under sway";
    mainProgram = "coda-cube";
    # The A53 tuning and NEON paths.
    platforms = [ "aarch64-linux" ];
  };
}
