# The DSI panel and touchscreen a LicheeRV Nano can carry: the vendor display stack and
# the panel's bring-up.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hardware.sg2k;
in
{
  config = lib.mkIf (cfg.enable && cfg.dsiPanel.enable) {
    assertions = [
      {
        # soph_drm at boot would program the badge's 720p link over the panel's.
        assertion = cfg.display.enable && cfg.display.autoLoad && !cfg.display.autoLoadDrm;
        message = "hardware.sg2k.dsiPanel.enable needs hardware.sg2k.display with autoLoad and without autoLoadDrm";
      }
    ];

    hardware.sg2k.display.enable = lib.mkDefault true;
    hardware.sg2k.display.drmDevice = lib.mkDefault "/dev/dri/badge-panel";

    # Sway on the panel, turned to the carrier's landscape, with touch on it.
    badge.graphics = lib.mkIf config.badge.graphics.enable {
      outputName = lib.mkDefault "DSI-1";
      outputMode = lib.mkDefault "native";
      extraConfig = ''
        output ${config.badge.graphics.outputName} transform 90
        input type:touch map_to_output ${config.badge.graphics.outputName}
      '';
    };

    boot.extraModprobeConfig = ''
      options cv181x_mipi_tx disp_working_bank=1
      # The panel's CST340 runs its firmware but does not answer the ROM handshake.
      options hynitron_cstxxx firmware_probe=1
    '';

    systemd.services.st7701-panel-init = {
      description = "Bring up the DSI panel";
      wantedBy = [ "multi-user.target" ];
      # A restart would re-initialise the link under soph_drm.
      restartIfChanged = false;
      requires = [ "soph-display-load.service" ];
      after = [ "soph-display-load.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe pkgs.st7701-panel-init;
        ExecStartPost = lib.optional config.badge.graphics.enable "${pkgs.kmod}/bin/modprobe soph_drm";
      };
    };
  };
}
