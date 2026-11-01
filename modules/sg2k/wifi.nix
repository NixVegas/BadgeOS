# The AIC8800D80 WiFi and Bluetooth on SDIO: the vendor driver, carried forward to
# mainline by the radxa-pkg/aic8800 fork.
{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.hardware.sg2k;
  bluetooth = cfg.wifi.bluetooth != "none";

  firmware = pkgs.aic8800-firmware.override { variants = [ cfg.wifi.firmware ]; };

  # The vendor SDHCI host for the wifi SDIO node (mmc@4320000); SD and eMMC stay on
  # mainline dwcmshc.
  sdhci = pkgs.sdhci-cv181x.override {
    kernel = config.boot.kernelPackages.kernel;
  };

  driver = pkgs.aic8800.override {
    kernel = config.boot.kernelPackages.kernel;
    fwPath = "/run/current-system/firmware/aic8800_fw/SDIO/${cfg.wifi.firmware}";
    # In-band SDIO interrupts; the poll path faults on live RX.
    usePoll = false;

    # BT over SDIO (hci0), from the combo firmware wifi already loads.
    bluetooth = cfg.wifi.bluetooth == "sdio";
  };
in
{
  config = lib.mkIf (cfg.enable && cfg.wifi.enable) {
    environment.systemPackages = [ pkgs.iw ] ++ lib.optional bluetooth pkgs.bluez;

    hardware.bluetooth.enable = bluetooth;
    hardware.bluetooth.powerOnBoot = true;
    networking.networkmanager.wifi.scanRandMacAddress = false;

    hardware.firmware = [ firmware ];
    boot.extraModulePackages = [
      driver
      sdhci
    ];
    boot.kernelModules = [
      "aic8800_bsp"
      "aic8800_fdrv"
      "sdhci-cv181x"
    ];

    # aic8800_bsp needs symbols from sdhci-cv181x. aicwf_dbg_level=1 is errors only: the
    # vendor default floods the console.
    boot.extraModprobeConfig = ''
      softdep aic8800_bsp pre: sdhci-cv181x
      options aic8800_fdrv aicwf_dbg_level=1
    '';

    # The driver randomises the MAC on every boot and has no option to turn that off.
    services.udev.extraRules = ''
      SUBSYSTEM=="net", ACTION=="add", ENV{ID_NET_DRIVER}=="aicwf_sdio", RUN+="${lib.getExe pkgs.nix-badge-stable-mac} $name"
    '';
  };
}
