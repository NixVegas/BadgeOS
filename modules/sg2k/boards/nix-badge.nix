# The NixVegas badge: a Milk-V Duo Module 01 (SG2000) on the NixVegas carrier.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkDefault;
in
{
  config = lib.mkIf (config.hardware.sg2k.enable && config.hardware.sg2k.board == "nix-badge") {
    hardware.sg2k = {
      soc = mkDefault "sg2000";
      cores = mkDefault (import ./table.nix).nix-badge.cores;
      memory.sizeMiB = mkDefault 512;
      dtb.name = mkDefault "sophgo/sg2000-nix-badge.dtb";
      dtb.package = mkDefault (
        pkgs.sg2k-dtb.override {
          board = "nix-badge";
          inherit (config.hardware.sg2k) core;
        }
      );
      firmware.fips = mkDefault (
        pkgs.buildPackages.nix-badge-fips {
          secureUboot = config.hardware.sg2k.secureBoot;
          fitKeyCert = config.hardware.sg2k.fitKeyCert;
        }
      );

      emmc.enable = mkDefault true;
      ethernet.enable = mkDefault true;
      wifi.enable = mkDefault true;
      wifi.bluetooth = mkDefault "sdio";
      hdmi.enable = mkDefault true;
      ledRing.enable = mkDefault true;
      oled.enable = mkDefault true;
      sharpPanel.enable = mkDefault true;
      coreSelect.enable = mkDefault true;

      display.drmDevice = mkDefault "/dev/dri/badge-hdmi";
      hdmi.audio = mkDefault true;
      # The SG2000 -> LT8912B path shears ~1.3 px/row at the exact mode width; +1 on the
      # bridge active-width register aligns it (bench-measured).
      hdmi.hactiveOffset = mkDefault 1;
      usb.gadget.product = mkDefault "Milk-V Duo S badge (NCM)";
    };

    # 24 WS2812 LEDs on SPI3 MOSI (header pin 19), and the 64-row OLED.
    badge.bling.count = mkDefault 24;
    badge.oled.height = mkDefault 64;

    # The badge routes for its wired ports out over WiFi.
    badge.router.enable = mkDefault (
      config.hardware.sg2k.ethernet.enable && config.hardware.sg2k.wifi.enable
    );
  };
}
