{
  lib,
  writeShellApplication,
  callPackage,
  coreutils,
  diffutils,
  util-linux,
  systemd,
  firmware ? null,
}:
writeShellApplication {
  name = "nix-badge-core-reboot";
  runtimeInputs = [
    coreutils
    diffutils
    util-linux
    systemd
  ];
  runtimeEnv.CORE_REBOOT_FIRMWARE = toString firmware;
  text = builtins.readFile ./core-reboot.sh;
  passthru.tests.reboot = callPackage ./test.nix { };
  meta = {
    description = "Request a guarded core switch on SD and reboot";
    platforms = lib.platforms.linux;
    mainProgram = "nix-badge-core-reboot";
  };
}
