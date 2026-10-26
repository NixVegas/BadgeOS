# HDMI output on both cores: the SG2000 MIPI DSI host driver
# (pkgs/video/sophgo-dsi) and the console. See docs/hdmi.md.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.nixbadge.hdmi;
in
{
  options.nixbadge.hdmi.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Load the SG2000 DSI host driver and put the consoles on HDMI.";
  };

  config = lib.mkIf cfg.enable {
    boot.extraModulePackages = [
      (import ../../pkgs/video/sophgo-dsi {
        inherit pkgs;
        kernel = config.boot.kernelPackages.kernel;
      })
    ];
    boot.kernelModules = [ "sophgo-dsi" ];
    # All consoles on fb1, the HDMI framebuffer (the Sharp panel is fb0): fbcon
    # takes the console over when HDMI registers and creates it upright there;
    # rotate:0 overrides base.nix's rotate:2, which is for the panel.
    boot.kernelParams = lib.mkAfter [ "fbcon=map:1,rotate:0" ];
  };
}
