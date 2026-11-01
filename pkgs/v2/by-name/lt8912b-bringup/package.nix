# A hand-loadable bring-up module for the SG2000 -> LT8912B -> HDMI path.
{
  pkgs,
  kernel,
}:
let
  inherit (pkgs.stdenv.hostPlatform) linuxArch;
  crossPrefix = pkgs.stdenv.cc.targetPrefix;
in
pkgs.stdenv.mkDerivation {
  pname = "lt8912b-bringup";
  version = "0.1-${kernel.version}";

  src = ./lt8912b-bringup;

  nativeBuildInputs = kernel.moduleBuildDependencies;

  makeFlags = [
    "-C"
    "${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
    "M=$(PWD)"
    "ARCH=${linuxArch}"
    "CROSS_COMPILE=${crossPrefix}"
    "modules"
  ];

  installPhase = ''
    runHook preInstall
    instdir="$out/lib/modules/${kernel.modDirVersion}/kernel/drivers/video/lt8912b-bringup"
    mkdir -p "$instdir"
    install -p -m 0644 lt8912b-bringup.ko "$instdir/"

    # Keep kernel.dev out of the runtime closure.
    ${pkgs.buildPackages.removeReferencesTo}/bin/remove-references-to \
      -t ${kernel.dev} "$instdir/lt8912b-bringup.ko"
    runHook postInstall
  '';

  # kbuild strips the .ko already.
  dontStrip = true;

  meta = {
    description = "SG2000 HDMI (LT8912B) mainline bring-up kernel module";
    license = pkgs.lib.licenses.gpl2Only;
  };
}
