# Boot profiles: the specialisations desktop.nix and video.nix add, each marked so that it
# adds none of its own.
{ lib, ... }:
{
  options.badge.isSpecialisation = lib.mkOption {
    type = lib.types.bool;
    default = false;
    internal = true;
    visible = false;
    description = "True inside a badge specialisation; suppresses nested ones.";
  };
}
