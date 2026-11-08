# The Sipeed LicheeRV Nano (SG2002, 256 MiB): SD card, Ethernet, the AIC8800D80 WiFi.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkDefault;
  cfg = config.hardware.sg2k;
in
{
  config = lib.mkIf (cfg.enable && cfg.board == "licheerv-nano") {
    hardware.sg2k = {
      soc = mkDefault "sg2002";
      cores = mkDefault (import ./table.nix).licheerv-nano.cores;
      memory.sizeMiB = mkDefault 256;
      dtb.name = mkDefault "sophgo/sg2002-licheerv-nano.dtb";
      dtb.package = mkDefault (
        pkgs.sg2k-dtb.override {
          board = "licheerv-nano";
          inherit (cfg) core;
          dtsFragments =
            lib.optional (!cfg.wifi.enable) "licheerv-nano-no-wifi.dtsi"
            ++ lib.optional (!cfg.ethernet.enable) "licheerv-nano-no-ethernet.dtsi"
            ++ lib.optional cfg.dsiPanel.enable "licheerv-nano-dsi-panel.dtsi";
        }
      );
      firmware.fips = mkDefault (
        pkgs.buildPackages.sg2k-fips-licheerv-nano.override { touchPads = cfg.dsiPanel.enable; }
      );

      ethernet.enable = mkDefault true;
      wifi.enable = mkDefault true;
      wifi.bluetooth = mkDefault "none";
      usb.gadget.product = mkDefault "LicheeRV Nano (NCM)";
    };
  };
}
