# Badge #1, fused to SCS=02: its fip is TPM-signed and encrypted through the autopen
# daemon. The overlays go in through nixpkgs.overlays so cross buildPackages splice.
{ inputs, ... }:
{
  nixpkgs.overlays = [
    inputs.autopen.overlays.default
    inputs.nixpkcs.overlays.default
  ];

  hardware.sg2k.firmware.secureBoot = true;
  hardware.sg2k.firmware.encryptedBoot = true;

  # Deployed over its Ethernet, so that is its uplink.
  badge.router.upstream = "ethernet";
}
