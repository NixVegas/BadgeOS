# Session tools for the touch desktop.
{
  lib,
  writeShellApplication,
  symlinkJoin,
  coreutils,
  gawk,
  systemd,
  networkmanager,
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
  ];
  meta.description = "Panel information, settings and radio controls";
  meta.platforms = lib.platforms.linux;
}
