# RAUC's pre-install handler: no installs while a data card is in use.
{
  lib,
  writeShellApplication,
  callPackage,
  gawk,
}:
writeShellApplication {
  name = "nix-badge-rauc-pre-install";
  runtimeInputs = [ gawk ];
  text = builtins.readFile ./pre-install.sh;
  passthru.tests.refuse = callPackage ./test.nix { };
  meta = {
    description = "Refuse RAUC installs while a data card is in use";
    mainProgram = "nix-badge-rauc-pre-install";
    platforms = lib.platforms.linux;
  };
}
