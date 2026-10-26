# SG2000 MIPI DSI host for the badge's HDMI output, built out of tree against
# the image kernel. Register provenance (Sophgo osdrv aa542c41, the vendor
# display stack) is cited in the source.
{
  pkgs,
  kernel,
}:
pkgs.stdenv.mkDerivation {
  pname = "sophgo-dsi";
  version = "unstable-${kernel.version}";

  src = ./src;

  nativeBuildInputs = kernel.moduleBuildDependencies;

  makeFlags = [
    "-C"
    "${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
    "M=$(PWD)"
    "ARCH=${pkgs.stdenv.hostPlatform.linuxArch}"
    "CROSS_COMPILE=${pkgs.stdenv.cc.targetPrefix}"
    "modules"
  ];

  installPhase = ''
    runHook preInstall
    instdir="$out/lib/modules/${kernel.modDirVersion}/kernel/drivers/gpu/drm/sophgo"
    mkdir -p "$instdir"
    install -p -m 0644 sophgo-dsi.ko "$instdir/"
    ${pkgs.buildPackages.removeReferencesTo}/bin/remove-references-to -t ${kernel.dev} "$instdir/sophgo-dsi.ko"
    runHook postInstall
  '';

  dontStrip = true;

  meta = {
    description = "SG2000 MIPI DSI host driver for the Milk-V Duo S HDMI output";
    license = pkgs.lib.licenses.gpl2Only;
  };
}
