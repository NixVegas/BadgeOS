# A stable MAC address for the AIC8800's WiFi, whose driver randomises it on every boot:
# run by udev when the interface appears.
{
  lib,
  writeShellApplication,
  callPackage,
  coreutils,
  iproute2,
  leaveDown ? false,
}:
writeShellApplication {
  name = "nix-badge-stable-mac";
  runtimeInputs = [
    coreutils
    iproute2
  ];
  text = builtins.readFile ./stable-mac.sh;
  derivationArgs = lib.optionalAttrs leaveDown {
    preCheck = ''
      substituteInPlace "$target" \
        --replace-fail '"$ip" link set dev "$iface" up 2>/dev/null || true' ""
    '';
  };
  passthru.tests.mac = callPackage ./test.nix { };
  meta = {
    description = "Give the WiFi interface a MAC address derived from the machine-id";
    mainProgram = "nix-badge-stable-mac";
    platforms = lib.platforms.linux;
  };
}
