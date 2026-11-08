# Sway on the LicheeRV Nano's DSI panel, by evaluation: the panel's output and touch in the
# sway config, soph_drm loaded after the panel, greetd waiting for its card.
{
  pkgs,
  # nixosConfigurations.licheerv-nano-riscv-*
  sys,
}:
let
  inherit (pkgs) lib;
  desktop =
    (sys.extendModules {
      modules = [
        {
          hardware.sg2k.dsiPanel.enable = true;
          badge.graphics.enable = true;
        }
      ];
    }).config;
  swayText = desktop.environment.etc."sway/config".source.text;
  has = lib.hasInfix;
  failures =
    lib.optional (!has "output DSI-1 position 0 0\n" swayText) "sway config does not place DSI-1"
    ++ lib.optional (has "output DSI-1 mode" swayText) "sway config sets a mode on DSI-1"
    ++ lib.optional (has "HDMI-A-1" swayText) "sway config mentions HDMI-A-1"
    ++ lib.optional (!has "output DSI-1 transform 90\n" swayText) "sway config does not turn DSI-1"
    ++ lib.optional (
      !has "input type:touch map_to_output DSI-1\n" swayText
    ) "sway config does not map touch to DSI-1"
    ++ lib.optional desktop.hardware.sg2k.display.autoLoadDrm "soph_drm loads before the panel is up"
    ++ lib.optional (
      !lib.any (has "modprobe soph_drm") desktop.systemd.services.st7701-panel-init.serviceConfig.ExecStartPost
    ) "st7701-panel-init does not load soph_drm"
    ++ lib.optional (
      desktop.systemd.services.greetd.unitConfig.ConditionPathExists or "" != "/dev/dri/badge-panel"
    ) "greetd does not wait for the panel's card"
    ++ lib.optional (
      !has ''SUBSYSTEM=="drm", KERNEL=="card[0-9]*", DRIVERS=="soph-drm", SYMLINK+="dri/badge-panel"'' desktop.services.udev.extraRules
    ) "no udev rule names the panel's card"
    ++ map (a: "assertion: ${a.message}") (lib.filter (a: !a.assertion) desktop.assertions);
in
if failures == [ ] then
  pkgs.runCommand "desktop-dsi-panel" { } "touch $out"
else
  throw ("desktop-dsi-panel:\n  " + lib.concatStringsSep "\n  " failures)
