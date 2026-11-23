# The GalaxyCore GC4653 driver for the cvi_mpi ISP, from Sipeed's LicheeRV Nano SDK (the
# sensor on the panel carrier's MIPI CSI connector). It programs the sensor over
# i2c-dev and hands the ISP its exposure and white-balance callbacks.
{
  lib,
  stdenv,
  fetchurl,
  soph-mpi,
}:
let
  mpi = soph-mpi.override { withCamera = true; };
  rev = "d4003f15b35d43ad4842f427050ab2bba0114fa5";
  file =
    name: hash:
    fetchurl {
      url = "https://raw.githubusercontent.com/sipeed/LicheeRV-Nano-Build/${rev}/middleware/v2/component/isp/sensor/cv182x/gcore_gc4653/${name}";
      inherit hash;
    };
  sources = [
    (file "gc4653_cmos.c" "sha256-ZR1vilmya2uyHjGsU8+kdV+hTFRpdHekvfO8rkOQnv4=")
    (file "gc4653_cmos_ex.h" "sha256-nKcgErKRg1h8S8SFLMB+F5pRzbUXWODwuzlEbktEbtQ=")
    (file "gc4653_cmos_param.h" "sha256-x4qtKh61fGJuppw50NexewtsqboS+qaoBq+BaEHr2sQ=")
    (file "gc4653_sensor_ctl.c" "sha256-n7xGorcpeAzQ9iY75zC7yXnqfR4SXrYnAVTqqbuKy+U=")
  ];
in
stdenv.mkDerivation {
  pname = "soph-sensor-gc4653";
  version = "0-unstable-2024-${builtins.substring 0 8 rev}";

  dontUnpack = true;
  strictDeps = true;
  buildInputs = [ mpi ];

  # The vendor's trace macros print through non-literal format strings.
  hardeningDisable = [ "format" ];

  buildPhase = ''
    runHook preBuild
    for s in ${lib.concatStringsSep " " sources}; do
      cp "$s" "''${s#*-}"
    done
    for c in *.c; do
      $CC -O2 -fPIC -Wall -D__CV181X__ -I. -I${mpi}/include -I${mpi}/include/isp/cv181x \
        -I${mpi}/include/linux -c "$c" -o "''${c%.c}.o"
    done
    $CC -shared -o libsns_gc4653.so *.o
    $AR rcs libsns_gc4653.a *.o
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm644 -t $out/lib libsns_gc4653.so libsns_gc4653.a
    runHook postInstall
  '';

  passthru.mpi = mpi;

  meta = {
    description = "GC4653 image sensor driver for the Sophgo cvi_mpi ISP";
    homepage = "https://github.com/sipeed/LicheeRV-Nano-Build";
    # No license: the SDK tree ships none.
    platforms = [
      "aarch64-linux"
      "riscv64-linux"
    ];
  };
}
