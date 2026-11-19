# The camera app: the GC4653's live picture in a window, reading QR codes and joining
# the Wi-Fi network a Wi-Fi QR code names. Started as root by badge-camera@USER.service
# (the camera devices), it drops to USER before it connects to sway.
{
  lib,
  stdenv,
  callPackage,
  pkg-config,
  sdl3,
  zxing-cpp,
  bash,
  coreutils,
  networkmanager,
  systemd,
  shellcheck-minimal,
  soph-sensor-gc4653,
}:
let
  mpi = soph-sensor-gc4653.mpi;
  libexec = "${placeholder "out"}/libexec/badge-camera";
in
stdenv.mkDerivation {
  pname = "badge-camera";
  version = "1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./camera.c
      ./convert.c
      ./convert.h
      ./pipeline.c
      ./pipeline.h
      ./qrread.cc
      ./qrread.h
      ./wifiqr.c
      ./wifiqr.h
      ./vector-shim.c
      ./session.sh
    ];
  };

  strictDeps = true;
  nativeBuildInputs = [
    pkg-config
    shellcheck-minimal
  ];
  # bash for patchShebangs
  buildInputs = [
    bash
    sdl3
    systemd
    zxing-cpp
    mpi
    soph-sensor-gc4653
  ];

  buildPhase = ''
    runHook preBuild
    cpu=${lib.optionalString stdenv.hostPlatform.isAarch64 "-mcpu=cortex-a53"}
    $CC -O2 $cpu -Wall -Wextra -Werror \
      -Wno-unused-parameter -D__CV181X__ \
      -I${mpi}/include -I${mpi}/include/isp/cv181x -I${mpi}/include/linux \
      $($PKG_CONFIG --cflags sdl3 libsystemd) \
      -c camera.c convert.c pipeline.c wifiqr.c vector-shim.c
    # The QR reader is a C++ library, so its one wrapper is too, and the link is C++'s.
    $CXX -O2 $cpu -Wall -Wextra -Werror -c qrread.cc
    $CXX camera.o convert.o pipeline.o wifiqr.o vector-shim.o qrread.o \
      -o badge-camera -rdynamic \
      $($PKG_CONFIG --libs sdl3 libsystemd) -lZXing \
      -L${soph-sensor-gc4653}/lib -L${mpi}/lib -Wl,-rpath,${soph-sensor-gc4653}/lib:${mpi}/lib \
      -Wl,--no-as-needed -lsns_gc4653 -Wl,--start-group -lisp -lisp_algo -lae -lawb -laf \
      -lcvi_bin -lcvi_bin_isp -lvi -lvpss -lvo -lsys -Wl,--end-group -lpthread -lm -ldl
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 badge-camera $out/bin/badge-camera
    install -Dm755 session.sh ${libexec}/session
    substituteInPlace ${libexec}/session \
      --replace-fail @path@ ${
        lib.makeBinPath [
          coreutils
          systemd
          networkmanager
          (placeholder "out")
        ]
      }
    shellcheck ${libexec}/session
    runHook postInstall
  '';

  passthru.tests.qr = callPackage ./test.nix { };

  meta = {
    description = "Camera preview and QR Wi-Fi joining for the panel";
    mainProgram = "badge-camera";
    platforms = [
      "aarch64-linux"
      "riscv64-linux"
    ];
  };
}
