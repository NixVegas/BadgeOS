# The on-demand radio services: the shared driver stack and its two consumers.
{
  lib,
  writeShellApplication,
  symlinkJoin,
  coreutils,
  systemd,
  kmod,
  networkmanager,
  iproute2,
  bluez,
}:
let
  command =
    name: file: runtimeInputs:
    writeShellApplication {
      inherit name runtimeInputs;
      text = builtins.readFile file;
    };
in
symlinkJoin {
  name = "nix-badge-panel-radio";
  paths = [
    (command "nix-badge-panel-radio-stack" ./stack.sh [
      kmod
      networkmanager
    ])
    (command "nix-badge-panel-radio-wifi" ./wifi.sh [
      systemd
      networkmanager
      coreutils
      iproute2
    ])
    (command "nix-badge-panel-radio-bluetooth" ./bluetooth.sh [
      systemd
      bluez
    ])
  ];
  meta.description = "On-demand shared radio services";
  meta.platforms = lib.platforms.linux;
}
