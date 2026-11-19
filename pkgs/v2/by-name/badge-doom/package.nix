# crispy-doom through badge-game, with the video settings in badge-doom-defaults.cfg.
{
  lib,
  writeShellApplication,
  coreutils,
  gnugrep,
  jq,
  badge-game,
  crispy-doom,
  # For swaymsg. The badge passes its session's sway, config.programs.sway.package.
  sway,
  # badge.graphics.outputMode is "native": fullscreen at the desktop's size, with
  # no 640x360 mode to switch to.
  nativeMode ? false,
  # The touch controls, in a window as large as the output outputName.
  withTouch ? false,
  outputName ? "HDMI-A-1",
}:
writeShellApplication {
  name = "badge-doom";

  runtimeInputs = [
    coreutils
    gnugrep
    badge-game
    crispy-doom
  ]
  ++ lib.optionals withTouch [
    sway
    jq
  ];

  runtimeEnv = {
    BADGE_DOOM_DEFAULTS = "${./badge-doom-defaults.cfg}";
    # The 640x360 mode scans out XRGB8888. With the session's BGR24, SDL converts
    # every frame in its generic blitter, a fifth of the CPU.
    SDL_VIDEO_WAYLAND_SHM_FORMAT = "SDL_PIXELFORMAT_XRGB8888";
    # crispy-doom redraws the whole window, pillarboxes included, every frame.
    SDL_VIDEO_WAYLAND_FRAMEBUFFER_NO_COPY = "1";
  }
  // lib.optionalAttrs nativeMode {
    BADGE_DOOM_DEFAULTS = "${./native-defaults.cfg}";
  }
  // lib.optionalAttrs withTouch {
    BADGE_DOOM_DEFAULTS = "${./panel-defaults.cfg}";
    BADGE_DOOM_KEYS = "${./keys.cfg}";
    BADGE_DOOM_OUTPUT = outputName;
    BADGE_PANEL_TOUCH = "1";
    SDL_VIDEODRIVER = "wayland";
    SDL_APP_ID = "badge-doom";
    SDL_VIDEO_WAYLAND_WMCLASS = "badge-doom";
    SDL_VIDEO_WAYLAND_SHM_FORMAT = "SDL_PIXELFORMAT_BGR24";
    SDL_VIDEO_WAYLAND_FRAMEBUFFER_NO_COPY = "0";
    SDL_FRAMEBUFFER_ACCELERATION = "0";
    SDL_RENDER_DRIVER = "software";
  };

  text = builtins.readFile ./badge-doom.sh;

  meta = {
    description = "crispy-doom in the badge's video settings, restoring the desktop output mode when it exits";
    mainProgram = "badge-doom";
    platforms = lib.platforms.linux;
  };
}
