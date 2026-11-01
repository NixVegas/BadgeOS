# dnsmasq's gateway and DNS options for the router's LAN, from the uplink's routes: run by
# NetworkManager's dispatcher and before dnsmasq starts.
{
  lib,
  writeShellApplication,
  callPackage,
  iproute2,
  coreutils,
  gawk,
}:
writeShellApplication {
  name = "nix-badge-router-gateway";
  runtimeInputs = [
    iproute2
    coreutils
    gawk
  ];
  text = builtins.readFile ./router-gateway.sh;
  passthru.tests.gateway = callPackage ./test.nix { };
  meta = {
    description = "Offer the badge as the LAN's gateway only while its uplink is up";
    mainProgram = "nix-badge-router-gateway";
    platforms = lib.platforms.linux;
  };
}
