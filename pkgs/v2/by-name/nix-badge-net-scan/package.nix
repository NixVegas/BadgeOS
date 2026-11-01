# The WiFi and Bluetooth scan feed for the OLED's scan screens, run on demand.
{
  lib,
  writeShellApplication,
  callPackage,
  coreutils,
  gawk,
  iw,
  bluez,
  withBluetooth ? true,
}:
writeShellApplication {
  name = "nix-badge-net-scan";
  runtimeInputs = [
    coreutils
    gawk
    iw
  ]
  ++ lib.optional withBluetooth bluez;
  runtimeEnv = lib.optionalAttrs withBluetooth { NET_SCAN_BLUETOOTH = "1"; };
  # No errexit: a half that fails must still leave its file.
  bashOptions = [ "nounset" ];
  text = builtins.readFile ./net-scan.sh;
  passthru.tests.scan = callPackage ./test.nix { };
  meta = {
    description = "Write the WiFi and Bluetooth scan results the OLED shows";
    mainProgram = "nix-badge-net-scan";
    platforms = lib.platforms.linux;
  };
}
