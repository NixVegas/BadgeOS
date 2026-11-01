# Interactive installer for an SD-booted badge: the serial, the eMMC install or update, then
# the SD card as a data card if wanted.
{
  lib,
  writeShellApplication,
  callPackage,
  coreutils,
  gnused,
  nix-badge,
  nix-badge-emmc-init,
  nix-badge-emmc-update,
  nix-badge-env-mirror,
  nix-badge-make-data-card,
  systemd,
  ubootTools,
}:
writeShellApplication {
  name = "nix-badge-install";
  runtimeInputs = [
    coreutils
    gnused
    nix-badge
    nix-badge-emmc-init
    nix-badge-emmc-update
    nix-badge-env-mirror
    nix-badge-make-data-card
    systemd
    ubootTools
  ];
  text = builtins.readFile ./install.sh;
  passthru.tests.install = callPackage ./test.nix { };
  meta = {
    description = "Fuse a badge's serial and install or update its eMMC from the SD card";
    mainProgram = "nix-badge-install";
    platforms = lib.platforms.linux;
  };
}
