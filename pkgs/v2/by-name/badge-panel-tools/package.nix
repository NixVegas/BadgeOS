# Session tools for the touch desktop.
{
  lib,
  writeShellApplication,
  symlinkJoin,
  coreutils,
  gawk,
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
  ];
  meta.description = "Panel information for the touch desktop";
  meta.platforms = lib.platforms.linux;
}
