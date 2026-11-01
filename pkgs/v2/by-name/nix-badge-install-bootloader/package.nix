# nix-badge-install-bootloader { core, secureBoot, recoveryFip, activeFip, fipPath, emmc,
# externalStorage ? false }: the deploy-rs bootloader installer, which
# switch-to-configuration runs with the new toplevel as $1. The script is
# install-bootloader.nix.
{
  lib,
  pkgs,
  writeShellScript,
}:
args:
writeShellScript "install-sg2k-bootloader" (
  import ./install-bootloader.nix ({ inherit pkgs lib; } // args)
)
