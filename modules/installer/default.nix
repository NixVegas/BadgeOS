# The Nix Vegas installer the badge netboots: NixOS netboot-minimal with the event's
# defaults, slimmed to fit the badge's store.
{ lib, modulesPath, ... }:
{
  imports = [
    (modulesPath + "/installer/netboot/netboot-minimal.nix")
    ./nix-vegas-defaults.nix
    ./slim.nix
    ./netboot-dir.nix
    ./badge-cache.nix
  ];

  # nix-vegas-defaults.nix sets only the legacy nixpkgs.system.
  nixpkgs.hostPlatform = "x86_64-linux";

  # A netbooted installer keeps no state and never imports a root pool.
  system.stateVersion = lib.trivial.release;
  boot.zfs.forceImportRoot = false;
}
