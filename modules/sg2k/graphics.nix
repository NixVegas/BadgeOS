# Sway on HDMI, software-rendered: there is no 3D GPU, so wlroots uses pixman and GL
# clients get llvmpipe.
{
  config,
  pkgs,
  lib,
  utils,
  ...
}:
let
  cfg = config.badge.graphics;
  sg2k = config.hardware.sg2k;

  # A minimal sway config for a board with no keyboard, no GPU and one core.
  swayConfig = pkgs.writeText "badge-sway.config" ''
    # soph_drm's HDMI output, in outputMode.
    output ${cfg.outputName} position 0 0
    ${lib.optionalString (cfg.outputMode != "native") "output ${cfg.outputName} mode ${cfg.outputMode}"}
    output ${cfg.outputName} bg #101015 solid_color

    # No title bars or gaps: the CPU draws every pixel.
    default_border none
    titlebar_padding 1
    hide_edge_borders both

    seat * hide_cursor 3000

    ${lib.concatMapStrings (c: "exec ${c}\n") cfg.autostart}

    # Enough to get out of it if a keyboard IS attached.
    set $mod Mod4
    bindsym $mod+Return exec ${pkgs.foot}/bin/foot
    bindsym $mod+Shift+q kill
    bindsym $mod+Shift+e exec swaymsg exit
    ${
      lib.optionalString (cfg.outputMode != "native") ''
        # Back to the desktop mode, for an app that died with the output switched.
        bindsym $mod+Shift+m exec swaymsg output ${cfg.outputName} mode ${cfg.outputMode}''
    }${lib.optionalString (cfg.extraConfig != "") "\n\n${cfg.extraConfig}"}
  '';
in
{
  options.badge.graphics = {
    enable = lib.mkEnableOption "Sway on DRM/KMS, software-rendered";

    outputName = lib.mkOption {
      type = lib.types.str;
      default = "HDMI-A-1";
      description = "soph_drm's output, as sway names it.";
    };

    outputMode = lib.mkOption {
      type = lib.types.enum [
        "1280x720"
        "640x360"
        "native"
      ];
      default = "1280x720";
      description = ''
        The mode sway sets on the HDMI output; both drive the same 1280x720p60 line.
        "1280x720": the DISP video layer scans the compositor's RGB888 buffer 1:1.
        "640x360": the DISP GOP doubles an XRGB8888 buffer, for a quarter of the
        pixels to render and a third of the scanout bandwidth.
        "native": no mode line; the output's preferred mode, for a panel.
      '';
    };

    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Lines appended to the sway config.";
    };

    autostart = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "/run/current-system/sw/bin/badge-demo" ];
      description = "Commands the sway config starts (`exec`), in order.";
    };
  };

  config = lib.mkIf (config.hardware.sg2k.enable && cfg.enable) {
    # Mesa and SDL3 trimmed, then the pkgs/patches package patches.
    nixpkgs.overlays = [
      (import ../../pkgs/v2/overlays/graphics.nix)
      (import ../../pkgs/v2/patches/overlay.nix { })
    ];

    hardware.graphics.enable = true;

    # For sway outside a logind session (over ssh).
    services.seatd.enable = true;
    users.users.badge.extraGroups = [
      "video"
      "input"
      "seat"
      "render"
    ];

    # graphical-desktop's default: ~660 MiB of screen reader nobody runs.
    services.speechd.enable = false;

    programs.sway = {
      enable = true;
      xwayland.enable = false;
      wrapperFeatures.base = true;
      wrapperFeatures.gtk = false;
      extraPackages = [ pkgs.foot ];
      extraSessionCommands = ''
        export WLR_RENDERER=pixman
        export WLR_RENDERER_ALLOW_SOFTWARE=1
        export LIBSEAT_BACKEND=seatd
        ${lib.optionalString (sg2k.display.drmDevice != "") ''
          export WLR_DRM_DEVICES="${sg2k.display.drmDevice}"
        ''}
        # wlroots exits when libinput starts with no devices.
        export WLR_LIBINPUT_NO_DEVICES=1
        # Software SDL windows present through wl_shm (pkgs/patches/sdl3), in the
        # BGR24 the 1280x720 mode scans out.
        export SDL_FRAMEBUFFER_ACCELERATION=0
        export SDL_VIDEO_WAYLAND_SHM_FORMAT=SDL_PIXELFORMAT_BGR24
        export SDL_VIDEO_WAYLAND_MODE_SWITCH=1
      '';
    };

    # The system default, so a bare `sway` uses it; it skips the module's config.d.
    environment.etc."sway/config".source = lib.mkForce swayConfig;

    # Autologin: greetd runs sway as badge in a logind session on tty1.
    services.greetd = {
      enable = true;
      settings.default_session = {
        # greetd's session PATH lacks the basics sway's helpers expect.
        command = "${pkgs.writeShellScript "badge-sway-session" ''
          export PATH="${
            lib.makeBinPath [
              pkgs.coreutils
              pkgs.util-linux
            ]
          }:$PATH"
          exec ${config.programs.sway.package}/bin/sway
        ''}";
        user = "badge";
      };
    };

    # drmDevice exists only once udev has processed the card (minutes on the C906), so
    # greetd starts from its device unit (display.nix tags the cards).
    systemd.services.greetd = lib.mkMerge [
      {
        after = [ "soph-display-load.service" ];
        wants = [ "soph-display-load.service" ];
      }
      (lib.mkIf (sg2k.display.drmDevice != "") {
        after = [ "${utils.escapeSystemdPath sg2k.display.drmDevice}.device" ];
        wantedBy = [ "${utils.escapeSystemdPath sg2k.display.drmDevice}.device" ];
        unitConfig.ConditionPathExists = sg2k.display.drmDevice;
      })
    ];

    environment.systemPackages = [
      pkgs.seatd
      pkgs.libdrm.bin # modetest
      pkgs.wayland-utils # wayland-info
      pkgs.badge-graphics-check # SDL window framebuffer colour bars
      pkgs.badge-kms-check # soph_drm checks, with the compositor stopped
    ]
    # coda-cube needs the A53.
    ++ lib.optionals pkgs.stdenv.hostPlatform.isAarch64 [ pkgs.badge-coda-cube ];

    systemd.packages = lib.optionals pkgs.stdenv.hostPlatform.isAarch64 [ pkgs.badge-coda-cube ];

    # foot has no built-in font; without one it exits at startup.
    fonts.packages = [ pkgs.dejavu_fonts ];
  };
}
