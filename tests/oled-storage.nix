# The boot-info screen says when a data card is in use (scope.storage is "card <device>",
# from nix-badge-storage-mode) and looks as before otherwise, on both panel heights.
{ pkgs }:
let
  inherit (pkgs) lib;
  # The screen reads the arch from builtins.currentSystem, which a check cannot.
  screen = scopedImport {
    builtins = builtins // {
      currentSystem = "aarch64-linux";
    };
  } ../pkgs/v2/by-name/nix-badge-bling-content/screens/bootinfo.nix;
  render =
    height: extra:
    (screen (
      {
        t = 0;
        width = 128;
        inherit height;
        nixosVersion = "26.05.20261025.1f607aa";
        kernelVersion = "6.18.44";
      }
      // extra
    )).bitmap;
  failures =
    lib.concatMap
      (
        h:
        lib.optional (
          render h { storage = "card /dev/mmcblk0p2"; } == render h { storage = "emmc"; }
        ) "${toString h}px: a data card does not show"
        ++ lib.optional (
          render h { storage = "emmc"; } != render h { }
        ) "${toString h}px: the eMMC changes the screen"
        ++ lib.optional (
          render h { storage = "sd"; } != render h { }
        ) "${toString h}px: the SD changes the screen"
      )
      [
        32
        64
      ];
in
if failures == [ ] then
  pkgs.runCommand "oled-storage" { } "touch $out"
else
  throw ("oled-storage:\n  " + lib.concatStringsSep "\n  " failures)
