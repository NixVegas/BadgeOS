# What stage 0 mounted (the eMMC, the SD or a data card over the eMMC), for the Nix
# daemon's store and anything that shows the mode.
{
  lib,
  writeShellApplication,
  callPackage,
  coreutils,
  gawk,
  gnused,
  nix-badge-stage0,
}:
writeShellApplication {
  name = "nix-badge-storage-mode";
  runtimeInputs = [
    coreutils
    gawk
    gnused
  ];
  # tier2.sh: the data card's store URL, as stage 0 mounts it
  text = builtins.readFile nix-badge-stage0.passthru.tier2 + builtins.readFile ./storage-mode.sh;
  passthru.tests.mode = callPackage ./test.nix { };
  meta = {
    description = "Record the storage mode stage 0 set up and the Nix daemon's store for it";
    mainProgram = "nix-badge-storage-mode";
    platforms = lib.platforms.linux;
  };
}
