# crispy-doom through badge-game, with the video settings in badge-doom-defaults.cfg.
{
  lib,
  writeShellApplication,
  coreutils,
  gnugrep,
  badge-game,
  crispy-doom,
}:
writeShellApplication {
  name = "badge-doom";

  runtimeInputs = [
    coreutils
    gnugrep
    badge-game
    crispy-doom
  ];

  runtimeEnv = {
    BADGE_DOOM_DEFAULTS = "${./badge-doom-defaults.cfg}";
    # The 640x360 mode scans out XRGB8888. With the session's BGR24, SDL converts
    # every frame in its generic blitter, a fifth of the CPU.
    SDL_VIDEO_WAYLAND_SHM_FORMAT = "SDL_PIXELFORMAT_XRGB8888";
    # crispy-doom redraws the whole window, pillarboxes included, every frame.
    SDL_VIDEO_WAYLAND_FRAMEBUFFER_NO_COPY = "1";
  };

  text = builtins.readFile ./badge-doom.sh;

  meta = {
    description = "crispy-doom in the badge's video settings, restoring the desktop output mode when it exits";
    mainProgram = "badge-doom";
    platforms = lib.platforms.linux;
  };
}
