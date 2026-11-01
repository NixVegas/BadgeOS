# Turns the SD card a badge booted from into a data card for its eMMC system, in place.
{
  lib,
  writeShellApplication,
  callPackage,
  coreutils,
  findutils,
  gnugrep,
  gnused,
  gptfdisk,
  util-linux,
}:
writeShellApplication {
  name = "nix-badge-make-data-card";
  runtimeInputs = [
    coreutils
    findutils
    gnugrep
    gnused
    gptfdisk
    util-linux
  ];
  text = builtins.readFile ./make-data-card.sh;
  passthru.tests.convert = callPackage ./test.nix { };
  meta = {
    description = "Turn the SD card a badge booted from into a data card for its eMMC system";
    mainProgram = "nix-badge-make-data-card";
    platforms = lib.platforms.linux;
  };
}
