# The "video" profile: a folder of H.264 clips on HDMI, advanced with the USER
# button, as its own boot-menu specialisation.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.badge;
  nix-badge-video = pkgs.nix-badge-video.override {
    videoDir = cfg.video.directory;
  };
in
{
  options.badge.video = {
    enable =
      lib.mkEnableOption ''
        the `video` boot specialisation: H.264 clips on HDMI via the vendor VDEC/VO
        path, advanced with the USER button''
      // {
        default = config.hardware.sg2k.hdmi.enable;
        defaultText = lib.literalExpression "config.hardware.sg2k.hdmi.enable";
      };

    directory = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/nix-badge-video";
      description = ''
        Folder scanned for H.264 Annex-B elementary streams (*.264 / *.h264),
        played in sorted order. Convert with, e.g.:
          ffmpeg -i in.mp4 -an -c:v libx264 -bsf:v h264_mp4toannexb -f h264 out.264
      '';
    };

    fps = lib.mkOption {
      type = lib.types.int;
      default = 60;
      description = ''
        Rate, in frames/sec, at which clips are fed to the decoder.
      '';
    };

    longPressMs = lib.mkOption {
      type = lib.types.int;
      default = 600;
      description = ''
        USER-button hold, in milliseconds, at or above which a press counts as
        "previous" instead of "next".
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf config.hardware.sg2k.enable {
      assertions = [
        {
          assertion =
            cfg.video.enable -> config.hardware.sg2k.hdmi.enable && config.hardware.sg2k.display.enable;
          message = "badge.video.enable needs hardware.sg2k.hdmi.enable and hardware.sg2k.display.enable";
        }
      ];
    })

    (lib.mkIf (config.hardware.sg2k.enable && cfg.video.enable && !cfg.isSpecialisation) {
      specialisation.video.configuration = lib.mkMerge [
        {
          badge.isSpecialisation = true;
          system.nixos.variant_id = "video";
        }

        {
          # The vendor display stack, but not the KMS driver: the VO path and soph_drm
          # can't both own the DISP.
          hardware.sg2k.display.autoLoad = true;
          hardware.sg2k.display.autoLoadDrm = lib.mkForce false;

          # Decode and VO buffers need the big pool.
          hardware.sg2k.memory.cmaMiB = 128;

          badge.graphics.enable = lib.mkForce false;

          # nix-badge-video programs the LT8912B itself.
          boot.blacklistedKernelModules = [ "lontium_lt8912b" ];

          # The OLED/LED daemon owns the USER button; this profile needs it.
          badge.oled.enable = lib.mkForce false;

          environment.systemPackages = [ nix-badge-video ];

          systemd.tmpfiles.rules = [ "d ${cfg.video.directory} 0755 root root -" ];

          systemd.services.nix-badge-video = {
            description = "H.264 clip player on HDMI, USER button = next/prev";
            wantedBy = [ "multi-user.target" ];
            after = [ "soph-display-load.service" ];
            wants = [ "soph-display-load.service" ];
            # The bring-up script calls soph-display-load-display.
            path = [ config.system.path ];
            serviceConfig = {
              Type = "simple";
              ExecStart = "${nix-badge-video}/bin/nix-badge-video ${cfg.video.directory}";
              Environment = [
                "NIX_BADGE_VIDEO_LONG_MS=${toString cfg.video.longPressMs}"
                "BLVO_FPS=${toString cfg.video.fps}"
              ];

              SyslogIdentifier = "nix-badge-video";

              # The vendor VO can log once per frame.
              LogRateLimitIntervalSec = 30;
              LogRateLimitBurst = 200;

              CPUSchedulingPolicy = "fifo";
              CPUSchedulingPriority = 10;

              # Clip reads must not queue behind a background writer.
              IOSchedulingClass = "realtime";
              IOSchedulingPriority = 2;

              # The bring-up writes the mipi_tx module parameters.
              User = "root";
              Restart = "on-failure";
              RestartSec = 5;
              StartLimitBurst = 3;
            };
          };
        }
      ];
    })
  ];
}
