# Collects garbage when the store's filesystem runs low on space.
{
  lib,
  writeShellApplication,
  callPackage,
  coreutils,
}:
writeShellApplication {
  name = "nix-badge-cache-gc";
  # nix-store is the system's, from the unit's PATH.
  runtimeInputs = [ coreutils ];
  text = builtins.readFile ./cache-gc.sh;
  passthru.tests.gc = callPackage ./test.nix { };
  meta = {
    description = "Collect garbage when the store's filesystem runs low on space";
    mainProgram = "nix-badge-cache-gc";
    platforms = lib.platforms.linux;
  };
}
