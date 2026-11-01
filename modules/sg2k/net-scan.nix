# On-demand WiFi + Bluetooth scan feed for the OLED scan screens.
{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.hardware.sg2k;
  bluetooth = cfg.wifi.bluetooth != "none";
  wlanIface = config.badge.oled.wlanInterface;
  netScan = pkgs.nix-badge-net-scan.override { withBluetooth = bluetooth; };
in
{
  config = lib.mkIf (cfg.enable && config.badge.oled.enable && cfg.wifi.enable) {
    systemd.tmpfiles.rules = [ "d /run/nix-badge 0755 root root -" ];

    system.build.netScanScript = netScan;

    # Root, for `iw scan`.
    systemd.services.nix-badge-net-scan = {
      description = "nix-badge OLED WiFi/BT scan feed (writes /run/nix-badge/{wifi,bt}-scan)";
      # A request during boot waits for it to finish.
      after = lib.optional bluetooth "bluetooth.target" ++ [ "multi-user.target" ];
      wants = lib.optional bluetooth "bluetooth.target";
      serviceConfig = {
        Type = "oneshot";
        # Backstop for an AIC8800 `iw scan` that never returns.
        TimeoutStartSec = "45s";
        ExecStart = "${lib.getExe netScan} ${wlanIface}";
      };
    };

    # The oled daemon rewrites scan-wanted at most every 20 s while a `wantsScan`
    # screen is up. The path unit stops watching while the scan runs, so a request
    # made then is dropped rather than queued.
    systemd.paths.nix-badge-net-scan = {
      description = "Run the nix-badge WiFi/BT scan when an OLED screen asks for one";
      wantedBy = [ "paths.target" ];
      pathConfig = {
        PathChanged = "/run/nix-badge/scan-wanted";
        Unit = "nix-badge-net-scan.service";
      };
    };
  };
}
