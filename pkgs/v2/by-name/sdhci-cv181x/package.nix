# The vendor CV181x SDHCI host driver (sophgo/linux_5.10, drivers/mmc/host/cvitek),
# out of tree on mainline: with mainline dwcmshc the AIC8800D80 firmware never starts.
{
  pkgs,
  kernel,
}:
pkgs.stdenv.mkDerivation {
  pname = "sdhci-cv181x";
  version = "vendor-5.10-unstable-${kernel.version}";

  src = ./sdhci-cv181x;

  nativeBuildInputs = kernel.moduleBuildDependencies;

  inherit (pkgs.stdenv.hostPlatform) linuxArch;
  crossPrefix = pkgs.stdenv.cc.targetPrefix;

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
    instdir="$out/lib/modules/${kernel.modDirVersion}/kernel/drivers/mmc/host"
    mkdir -p "$instdir"
    install -p -m 0644 sdhci-cv181x.ko "$instdir/"
    ${pkgs.buildPackages.removeReferencesTo}/bin/remove-references-to -t ${kernel.dev} "$instdir/sdhci-cv181x.ko"
    runHook postInstall
  '';

  dontStrip = true;

  meta = {
    description = "Out-of-tree CVITEK cv181x SDHCI host driver for mainline (WiFi SDIO bring-up)";
    license = pkgs.lib.licenses.gpl2Only;
  };
}
