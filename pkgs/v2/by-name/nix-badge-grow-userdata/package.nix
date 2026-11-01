# Grows USERDATA to the end of its disk once, on a card's first boot.
{
  lib,
  writeShellApplication,
  callPackage,
  coreutils,
  gnused,
  gptfdisk,
  util-linux,
}:
writeShellApplication {
  name = "nix-badge-grow-userdata";
  runtimeInputs = [
    coreutils
    gnused
    gptfdisk
    util-linux
  ];
  text = builtins.readFile ./grow-userdata.sh;
  passthru.tests.grow = callPackage ./test.nix { };
  meta = {
    description = "Grow the USERDATA partition to the end of its disk, keeping the hybrid MBR";
    mainProgram = "nix-badge-grow-userdata";
    platforms = lib.platforms.linux;
  };
}
