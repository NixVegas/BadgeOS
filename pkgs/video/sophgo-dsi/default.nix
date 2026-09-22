# Standalone SG2000 driver; register provenance is cited in the sources.
{ pkgs, kernel }:
pkgs.stdenv.mkDerivation {
  pname = "sophgo-dsi";
  version = "aa542c41-${kernel.version}";
  src = ./src;
  nativeBuildInputs = kernel.moduleBuildDependencies;
  makeFlags = [
    "-C"
    "${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
    "M=$(PWD)"
    "ARCH=${pkgs.stdenv.hostPlatform.linuxArch}"
    "CROSS_COMPILE=${pkgs.stdenv.cc.targetPrefix}"
    "CONFIG_DRM_SOPHGO_DSI=m"
    "W=1"
    "KCFLAGS=-Werror"
    "modules"
  ];
  preBuild = ''
    test -s ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build/Module.symvers
  '';
  installPhase = ''
    runHook preInstall
    instdir="$out/lib/modules/${kernel.modDirVersion}/kernel/drivers/gpu/drm/sophgo"
    install -Dm644 sophgo-dsi.ko "$instdir/sophgo-dsi.ko"
    ${pkgs.buildPackages.removeReferencesTo}/bin/remove-references-to \
      -t ${kernel.dev} "$instdir/sophgo-dsi.ko"
    runHook postInstall
  '';
  dontStrip = true;
  meta = {
    description = "SG2000 DSI host with a manual 1280x720 test-pattern path";
    license = pkgs.lib.licenses.gpl2Only;
  };
}
