# Makes the swap file on USERDATA, without ever leaving a partial one behind.
{
  lib,
  writeShellApplication,
  callPackage,
  coreutils,
  gawk,
  util-linux,
}:
writeShellApplication {
  name = "nix-badge-userdata-swap";
  runtimeInputs = [
    coreutils
    gawk
    util-linux
  ];
  text = builtins.readFile ./userdata-swap.sh;
  passthru.tests.swap = callPackage ./test.nix { };
  meta = {
    description = "Make the swap file on USERDATA, leaving nothing behind if there is no room";
    mainProgram = "nix-badge-userdata-swap";
    platforms = lib.platforms.linux;
  };
}
