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
  dbus,
  withAudio ? true,
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
    command name text
      (
        [
          systemd
          bluez
          coreutils
        ]
        ++ inputs
      )
      {
        BADGE_BLUETOOTH_AUDIO = if withAudio then "1" else "0";
      };
  audioDevice =
    bluetooth "badge-panel-bluetooth-audio-device" (builtins.readFile ./bluetooth-audio-device.sh)
      [ ];
  audioState =
    bluetooth "badge-panel-bluetooth-audio-state" (builtins.readFile ./bluetooth-audio-state.sh)
      [ audioDevice ];
  connect = bluetooth "badge-panel-bluetooth-connect" (builtins.readFile ./bluetooth-connect.sh) [
    audioDevice
    audioState
  ];
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
      if [[ $BADGE_BLUETOOTH_AUDIO == 1 ]]; then
        systemctl --user stop badge-panel-bluetooth-audio-watch.service pipewire.socket pipewire-pulse.socket
      fi
    '' [ ])
    (bluetooth "badge-panel-bluetooth-devices" (builtins.readFile ./bluetooth-devices.sh) [ connect ])
    (bluetooth "badge-panel-bluetooth-audio-watch" (builtins.readFile ./bluetooth-audio-watch.sh) [
      audioState
      dbus
    ])
    audioDevice
    audioState
    connect
  ];
  meta.description = "Panel information, settings and radio controls";
  meta.platforms = lib.platforms.linux;
}
