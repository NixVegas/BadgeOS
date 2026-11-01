# The installer without what the badge can't carry: firmware for WiFi chips and GPUs only,
# no channel, no ModemManager and no nixpkgs source.
{ lib, pkgs, ... }:
let
  firmware = pkgs.runCommand "linux-firmware-netboot" { } ''
    bash ${./firmware.sh} ${pkgs.linux-firmware}/lib/firmware $out/lib/firmware
  '';
in
{
  hardware.enableAllFirmware = lib.mkForce false;
  hardware.enableRedistributableFirmware = lib.mkForce false;
  hardware.firmware = [
    firmware
    pkgs.wireless-regdb
  ];
  system.installer.channel.enable = false;
  networking.modemmanager.enable = false;
  nixpkgs.flake.source = lib.mkForce null;
}
