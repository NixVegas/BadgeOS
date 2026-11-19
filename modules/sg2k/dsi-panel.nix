# The ST7701 DSI panel and CST340 touchscreen: vendor display startup.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hardware.sg2k;
  graphics = config.badge.graphics;
in
{
  config = lib.mkIf (cfg.enable && cfg.dsiPanel.enable) {
    assertions = [
      {
        assertion = cfg.display.enable && cfg.display.autoLoad;
        message = "hardware.sg2k.dsiPanel.enable needs hardware.sg2k.display with autoLoad";
      }
    ];

    hardware.sg2k.display.enable = lib.mkDefault true;
    hardware.sg2k.display.autoLoadDrm = lib.mkForce false;
    hardware.sg2k.display.drmDevice = lib.mkDefault "/dev/dri/badge-panel";
    hardware.sg2k.memory.stripModuleSymbols = lib.mkDefault true;

    badge.graphics = lib.mkIf graphics.enable {
      outputName = lib.mkDefault "DSI-1";
      outputMode = lib.mkDefault "native";
    };

    boot.extraModprobeConfig = ''
      options cv181x_mipi_tx disp_working_bank=1
      # The panel's CST340 runs its firmware but does not answer the ROM handshake.
      options hynitron_cstxxx firmware_probe=1
    '';

    systemd.services.greetd.after = lib.mkIf graphics.enable [
      "st7701-panel-init.service"
    ];

    systemd.services.st7701-panel-init = {
      description = "Bring up the DSI panel";
      wantedBy = [ "multi-user.target" ];
      restartIfChanged = false;
      requires = [ "soph-display-load.service" ];
      after = [ "soph-display-load.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe pkgs.st7701-panel-init;
        ExecStartPost = lib.optionals graphics.enable (
          [ "${pkgs.kmod}/bin/modprobe soph_drm" ]
          ++ lib.optional (cfg.display.drmDevice != "") (
            lib.getExe
              (pkgs.st7701-panel-init.override {
                drmDevice = cfg.display.drmDevice;
              }).displayLink
          )
        );
      };
    };
  };
}
