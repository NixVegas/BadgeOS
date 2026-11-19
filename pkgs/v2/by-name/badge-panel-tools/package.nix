# Session tools for the touch desktop.
{
  lib,
  writeShellApplication,
  symlinkJoin,
  coreutils,
  gawk,
  systemd,
  networkmanager,
  bluez,
}:
let
  command =
    name: text: runtimeInputs: runtimeEnv:
    writeShellApplication {
      inherit
        name
        text
        runtimeInputs
        runtimeEnv
        ;
    };
  bluetooth =
    name: text: inputs:
    command name text (
      [
        systemd
        bluez
        coreutils
      ]
      ++ inputs
    ) { };
  connect = bluetooth "badge-panel-bluetooth-connect" (builtins.readFile ./bluetooth-connect.sh) [ ];
in
symlinkJoin {
  name = "badge-panel-tools";
  paths = [
    (command "badge-panel-info" (builtins.readFile ./info.sh) [ coreutils gawk ] { })
    (command "badge-panel-wifi-status" (builtins.readFile ./wifi-status.sh) [ networkmanager ] { })
    (command "badge-panel-wifi-join" (builtins.readFile ./wifi-join.sh) [
      networkmanager
      coreutils
    ] { })
    (command "badge-panel-wifi-disable" ''
      # The radio may have been enabled outside this unit.
      nmcli radio wifi off
      systemctl --no-ask-password stop nix-badge-wifi.service
    '' [ systemd networkmanager ] { })
    (bluetooth "badge-panel-bluetooth-status" (builtins.readFile ./bluetooth-status.sh) [ ])
    (bluetooth "badge-panel-bluetooth-disable" ''
      systemctl --no-ask-password stop badge-panel-bluetooth.service
    '' [ ])
    (bluetooth "badge-panel-bluetooth-devices" (builtins.readFile ./bluetooth-devices.sh) [ connect ])
    connect
  ];
  meta.description = "Panel information, settings and radio controls";
  meta.platforms = lib.platforms.linux;
}
