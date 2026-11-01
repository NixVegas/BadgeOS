# Update an installed eMMC's inactive slot from a running SD boot, keeping USERDATA.
{
  lib,
  writeShellApplication,
  callPackage,
  coreutils,
  gnused,
  util-linux,
  ubootTools,
  nix-badge-env-mirror,
}:
writeShellApplication {
  name = "nix-badge-emmc-update";
  runtimeInputs = [
    coreutils
    gnused
    util-linux
    ubootTools
    nix-badge-env-mirror
  ];
  text = builtins.readFile ./emmc-update.sh;
  passthru.tests.update = callPackage ./test.nix { };
  meta = {
    description = "Update an installed eMMC's inactive slot from the booted SD card";
    mainProgram = "nix-badge-emmc-update";
    platforms = lib.platforms.linux;
  };
}
