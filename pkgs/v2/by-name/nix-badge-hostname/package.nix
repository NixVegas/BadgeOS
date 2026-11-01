# Sets the hostname at boot: the configured name, with the fused serial's number appended
# once DEVICE_ID is burned.
{
  lib,
  writeShellApplication,
  callPackage,
  coreutils,
  nix-badge-noeval,
}:
writeShellApplication {
  name = "nix-badge-hostname";
  runtimeInputs = [
    nix-badge-noeval
    coreutils
  ];
  text = builtins.readFile ./hostname.sh;
  passthru.tests.serial = callPackage ./test.nix { };
  meta = {
    description = "Set the hostname from the configured name and the fused serial";
    mainProgram = "nix-badge-hostname";
    platforms = lib.platforms.linux;
  };
}
