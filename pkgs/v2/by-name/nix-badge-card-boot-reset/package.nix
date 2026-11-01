# Drops a data card's boot images for the slots whose Nix layer stage 0 reset.
{
  lib,
  writeShellApplication,
  callPackage,
  coreutils,
}:
writeShellApplication {
  name = "nix-badge-card-boot-reset";
  runtimeInputs = [ coreutils ];
  text = builtins.readFile ./card-boot-reset.sh;
  passthru.tests.reset = callPackage ./test.nix { };
  meta = {
    description = "Drop a data card's boot images for slots whose Nix layer was reset";
    mainProgram = "nix-badge-card-boot-reset";
    platforms = lib.platforms.linux;
  };
}
