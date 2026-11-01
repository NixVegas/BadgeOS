# The desktop profile on both cores, by evaluation only: the base system has no
# compositor, and the `desktop` specialisation runs sway at 1280x720 with the badge's
# SDL setup and apps. Each failure message names its check.
{
  pkgs,
  systems,
}:
let
  inherit (pkgs) lib;

  checkCore =
    core: sys:
    let
      base = sys.config;
      desktop = base.specialisation.desktop.configuration;
      swayText = desktop.environment.etc."sway/config".source.text;
      swayEnv = desktop.programs.sway.extraSessionCommands;
      demoExec = builtins.match ".*\n[ \t]*exec [^\n]*badge-demo.*" swayText;
      quakeExec = builtins.match ".*\nexec [^\n]*badge-quake3.*" swayText;
      utils = import "${pkgs.path}/nixos/lib/utils.nix" {
        inherit lib pkgs;
        config = desktop;
      };
      hdmiDeviceUnit = "${utils.escapeSystemdPath desktop.hardware.sg2k.display.drmDevice}.device";
      failures =
        lib.optional base.badge.graphics.enable "base: graphics is enabled"
        ++ lib.optional base.services.greetd.enable "base: greetd is enabled"
        ++ lib.optional (base.environment.etc ? "sway/config") "base: ships a sway config"
        ++ lib.optional (!desktop.badge.graphics.enable) "desktop: graphics is off"
        ++ lib.optional (!desktop.services.greetd.enable) "desktop: greetd is off"
        ++ lib.optional (
          desktop.badge.graphics.outputMode != "1280x720"
        ) "desktop: does not default to native 1280x720"
        ++ lib.optional (
          !lib.hasInfix "output HDMI-A-1 mode 1280x720" swayText
        ) "desktop: sway config does not set the output mode to 1280x720"
        ++ lib.optional (lib.hasInfix "native_scanout" desktop.boot.extraModprobeConfig) "desktop: sets soph_drm's removed native_scanout parameter"
        ++ lib.optional (
          !lib.hasInfix "force_720p=1" desktop.boot.extraModprobeConfig
        ) "desktop: the LT8912B is not forced to a 720p line"
        ++ lib.optional (demoExec != null) "desktop: sway config launches badge-demo"
        ++ lib.optional (
          !lib.any (p: lib.getName p == "badge-demo") desktop.environment.systemPackages
        ) "desktop: badge-demo is not installed"
        ++ lib.optional (quakeExec != null) "desktop: sway config also execs Quake"
        ++ lib.optional (
          builtins.match "(.*\n)?[ \t]*export WLR_LIBINPUT_NO_DEVICES=1\n.*" swayEnv == null
          || lib.hasInfix "unset WLR_LIBINPUT_NO_DEVICES" swayEnv
        ) "desktop: sway exits when libinput starts with no initialized input devices"
        ++ lib.optional (
          builtins.match "(.*\n)?[ \t]*export SDL_FRAMEBUFFER_ACCELERATION=0\n.*" swayEnv == null
        ) "desktop: SDL window surfaces still go through a GL texture (SDL_FRAMEBUFFER_ACCELERATION)"
        ++ lib.optional (
          builtins.match "(.*\n)?[ \t]*export SDL_VIDEO_WAYLAND_SHM_FORMAT=SDL_PIXELFORMAT_BGR24\n.*" swayEnv
          == null
        ) "desktop: SDL window framebuffers are not BGR24 (SDL_VIDEO_WAYLAND_SHM_FORMAT)"
        ++ lib.optional (
          !lib.any (p: lib.getName p == "badge-graphics-check") desktop.environment.systemPackages
        ) "desktop: badge-graphics-check is not installed"
        ++
          lib.optional
            (builtins.match "(.*\n)?[ \t]*export SDL_VIDEO_WAYLAND_MODE_SWITCH=1\n.*" swayEnv == null)
            "desktop: SDL emulates fullscreen modes instead of switching the output (SDL_VIDEO_WAYLAND_MODE_SWITCH)"
        ++ lib.optional (
          !lib.hasInfix "bindsym $mod+Shift+m exec swaymsg output HDMI-A-1 mode 1280x720\n" swayText
        ) "desktop: no $mod+Shift+m binding puts the output back in 1280x720"
        ++ lib.optional (
          !lib.any (p: lib.getName p == "badge-doom") desktop.environment.systemPackages
        ) "desktop: badge-doom is not installed"
        ++ lib.optional (
          (core == "arm")
          != lib.any (p: lib.getName p == "badge-coda-cube") desktop.environment.systemPackages
        ) "desktop: badge-coda-cube is ${if core == "arm" then "not installed" else "installed"}"
        ++ lib.optional (
          (core == "arm") != lib.any (p: lib.getName p == "badge-coda-cube") desktop.systemd.packages
        ) "desktop: the badge-coda-cube@ unit is ${if core == "arm" then "missing" else "there"}"
        ++ lib.optional (
          (desktop.systemd.services.greetd.unitConfig.ConditionPathExists or "")
          != desktop.hardware.sg2k.display.drmDevice
        ) "desktop: greetd does not wait for the HDMI device"
        ++ lib.optional (
          !lib.elem hdmiDeviceUnit desktop.systemd.services.greetd.wantedBy
        ) "desktop: greetd is not started by ${hdmiDeviceUnit}"
        ++ lib.optional (
          !lib.hasInfix ''ENV{DEVTYPE}=="drm_minor", TAG+="systemd"'' desktop.services.udev.extraRules
        ) "desktop: the DRM cards are not tagged for systemd, so ${hdmiDeviceUnit} never exists";
    in
    map (f: "${core}: ${f}") failures;

  failures = lib.concatLists (lib.mapAttrsToList checkCore systems);
in
if failures != [ ] then
  throw "test-desktop-profile:\n  ${lib.concatStringsSep "\n  " failures}"
else
  pkgs.runCommand "test-desktop-profile" { } ''
    src=${../pkgs/v2/by-name/nix-fixes-this/demo.c}
    # The quit handling must sit in the default build, not only behind SMOKE_NOQUIT.
    sed -n '/#ifndef SMOKE_NOQUIT/,/#else/p' "$src" > quit.c
    grep -q 'SDLK_ESCAPE' quit.c || { echo "nix-fixes-this does not quit on ESC" >&2; exit 1; }
    grep -q 'SDL_EVENT_QUIT' quit.c || { echo "nix-fixes-this does not quit on SDL_EVENT_QUIT" >&2; exit 1; }
    touch $out
  ''
