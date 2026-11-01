# deploy-rs and nixos-rebuild on the dual-core badge: the installer copies the generation's
# FIT into the booted slot, /<core>/slot-<A|B>/boot.itb.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hardware.sg2k;
in
{
  config = lib.mkIf cfg.enable {
    # switch-to-configuration calls this with the new toplevel as $1.
    system.build.installBootLoader = lib.mkForce (
      pkgs.nix-badge-install-bootloader {
        inherit (cfg) core;
        inherit (cfg.firmware) secureBoot recoveryFip fipPath;
        activeFip = cfg.firmware.activeFipFile;
        emmc = cfg.emmc.enable;
        externalStorage = cfg.externalStorage.enable;
      }
    );
  };
}
