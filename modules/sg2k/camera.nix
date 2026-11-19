# GC4653 capture hardware and on-demand vendor driver loading.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hardware.sg2k;
  graphics = config.badge.graphics;
  camera = pkgs.badge-camera;
  # The vendor drivers bind the nodes as soon as they load; load them only on request,
  # after the VIP stack they share clocks and the system block with.
  modules = [
    "cvi_mipi_rx"
    "cv181x_vi"
    # The sensor's exposure and gain registers are written by the vi driver through a
    # callback that only this module registers (vip_sys_register_cmm_cb in
    # interdrv/snsr_i2c). Without it every write the ISP asks for is dropped and the
    # sensor keeps the exposure its power-on table set.
    "snsr_i2c"
  ];
in
{
  options.hardware.sg2k.camera = {
    enable = lib.mkEnableOption "the GC4653 camera on the panel carrier's MIPI CSI connector";
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.enable && cfg.camera.enable) {
      # Capture needs more than the rotation default; an explicit user value still wins.
      hardware.sg2k.memory.cmaMiB = lib.mkOverride 950 64;
      assertions = [
        {
          assertion = cfg.dsiPanel.enable && cfg.display.enable;
          message = "hardware.sg2k.camera.enable needs the panel carrier's VIP display stack";
        }
      ];

      boot.blacklistedKernelModules = modules;
      # The receiver clocks its MAC from VIP_SYS_2, which it reparents to FPLL for any
      # other limit; at 594 it keeps DISPPLL, the parent the running display has.
      boot.extraModprobeConfig = ''
        options cvi_mipi_rx max_mac_clk=594
      '';
      # The sensor driver programs the GC4653 through i2c-dev, on the bus it shares with
      # the touchscreen.
      boot.kernelModules = [ "i2c-dev" ];

      # Pulled in by the camera on first use rather than at boot.
      systemd.services.badge-camera-load = {
        description = "Camera receiver and ISP drivers";
        requires = [ "soph-display-load.service" ];
        after = [ "soph-display-load.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          TimeoutStartSec = 60;
          ExecStart = map (m: "${pkgs.kmod}/bin/modprobe ${m}") modules;
        };
      };
    })
    (lib.mkIf (cfg.enable && graphics.enable && graphics.touchBar.enable && cfg.camera.enable) {
      # The camera as root for its devices, dropping to the session user before sway.
      # Its buffer pool outlives a killed process, so it is freed before and after.
      systemd.services."badge-camera@" = {
        description = "Camera on %i's sway session";
        requires = [ "badge-camera-load.service" ];
        after = [ "badge-camera-load.service" ];
        serviceConfig = {
          Type = "notify";
          TimeoutStartSec = graphics.touchBar.limits.start;
          ExecStartPre = "-${lib.getExe camera} --cleanup";
          ExecStart = "${camera}/libexec/badge-camera/session %i";
          ExecStopPost = "-${lib.getExe camera} --cleanup";
          NoNewPrivileges = true;
          # Tearing the vendor pipeline down takes up to 22 s: CVI_ISP_Run's
          # thread only returns once the ISP has finished with the frame in hand. Killed
          # before that, the camera leaves its buffer pool behind for the next start.
          TimeoutStopSec = graphics.touchBar.limits.stop;
        };
      };

      badge.graphics.touchBar.apps.camera = {
        label = "Scan QR";
        group = "Tools";
        unit = "badge-camera@badge.service";
        system = true;
      };
    })
  ];
}
