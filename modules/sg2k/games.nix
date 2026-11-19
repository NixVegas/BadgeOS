# The games and the demo on the badge's sway: ioquake3 with the Quake III demo data,
# Crispy DOOM with Freedoom, and "Nix Fixes This".
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.badge.graphics;
  touch = cfg.touchBar.enable;

  # The demo's pak0 for assets plus the 1.32 point release, whose QVMs ioquake3
  # accepts. The directory must be literally baseq3.
  quakeData = pkgs.runCommand "quake3-baseq3-demo-plus-pointrelease" { } ''
    mkdir -p $out/baseq3
    cp ${pkgs.quake3demodata}/baseq3/pak0.pk3 $out/baseq3/pak0.pk3
    for p in ${pkgs.quake3pointrelease}/baseq3/*.pk3; do
      cp "$p" "$out/baseq3/$(basename "$p")"
    done
  '';

  # Only the WADs: the freedoom package carries build-host launcher scripts.
  freedoomWads = pkgs.buildPackages.runCommand "freedoom-wads" { } ''
    mkdir -p $out/share/games/doom
    cp ${pkgs.buildPackages.freedoom}/share/games/doom/*.wad $out/share/games/doom/
  '';

  # Runs a game and puts the output back in the desktop mode however it ends.
  badge-game = pkgs.badge-game.override {
    inherit (cfg) outputMode outputName;
    sway = config.programs.sway.package;
  };

  # Crispy DOOM with touch controls under the bar, and at the desktop's size in a
  # native mode.
  badge-doom = pkgs.badge-doom.override {
    inherit badge-game;
    inherit (cfg) outputName;
    sway = config.programs.sway.package;
    nativeMode = cfg.outputMode == "native";
    withTouch = touch;
  };

  # A native mode has no 640x360 to switch to: the picture is the output's size.
  quakeSize = lib.optionalString (cfg.outputMode == "native") ''
    read -r Q3_W Q3_H < <(${config.programs.sway.package}/bin/swaymsg -rt get_outputs |
      ${lib.getExe pkgs.jq} -r --arg name ${lib.escapeShellArg cfg.outputName} \
        '.[] | select(.name == $name) | .rect | "\(.width) \(.height)"')
  '';

  # The touch controls: their settings, and the native game code they run with, in
  # a home path of their own.
  quakeTouch = lib.optionalString touch ''
    export BADGE_PANEL_TOUCH=1 SDL_APP_ID=badge-quake SDL_VIDEO_WAYLAND_WMCLASS=badge-quake
    export Q3_SOUND=''${Q3_SOUND:-1}
    dir=''${XDG_DATA_HOME:-$HOME/.local/share}/badge-panel-quake
    ${pkgs.coreutils}/bin/mkdir -p "$dir/baseq3"
    ${pkgs.coreutils}/bin/install -m644 ${../../pkgs/v2/patches/ioquake3/panel.cfg} "$dir/baseq3/autoexec.cfg"
    ${pkgs.coreutils}/bin/ln -sf ${pkgs.ioquake3}/share/ioquake3/baseq3/*.so "$dir/baseq3/"
    set -- +set fs_homepath "$dir" +map q3dm1 "$@"
  '';

  # ioquake3 tuned for llvmpipe on one in-order core. Keep the depth test (early-Z)
  # and mipmaps on.
  badge-quake3 = pkgs.writeShellScriptBin "badge-quake3" ''
    set -e
    export LIBGL_ALWAYS_SOFTWARE=1
    export GALLIUM_DRIVER="''${GALLIUM_DRIVER:-llvmpipe}"
    export SDL_VIDEODRIVER="''${SDL_VIDEODRIVER:-wayland}"

    # Rasterise inline: one worker thread on one CPU costs 32%.
    export LP_NUM_THREADS="''${LP_NUM_THREADS:-0}"
    ${quakeSize}${quakeTouch}

    # A persistent JIT cache: the first frame takes ~2.5 s cold, ~0.14 s warm.
    export MESA_SHADER_CACHE_DIR="''${MESA_SHADER_CACHE_DIR:-$HOME/.cache/mesa_shader_cache}"
    ${pkgs.coreutils}/bin/mkdir -p "$MESA_SHADER_CACHE_DIR"

    exec ${badge-game}/bin/badge-game ${pkgs.ioquake3}/bin/ioquake3 \
      +set fs_basepath ${quakeData} \
      +set com_hunkMegs ''${Q3_HUNK:-${toString cfg.quakeHunkMiB}} \
      `# A ceiling: llvmpipe draws 5-6 fps at 640x360.` \
      +set com_maxfps ''${Q3_MAXFPS:-30} \
      +set cl_renderer opengl1 \
      +set r_mode -1 \
      +set r_customwidth ''${Q3_W:-${toString cfg.quakeWidth}} \
      +set r_customheight ''${Q3_H:-${toString cfg.quakeHeight}} \
      +set r_fullscreen ''${Q3_FS:-1} \
      `# Real 16bpp textures in llvmpipe: half the fetch bandwidth.` \
      +set r_texturebits 16 \
      +set r_vertexLight 1 \
      +set r_picmip ''${Q3_PICMIP:-4} \
      +set r_subdivisions 20 \
      +set r_lodbias 2 \
      +set r_fastsky 1 \
      +set r_dynamiclight 0 \
      +set r_detailtextures 0 \
      +set r_textureMode GL_LINEAR_MIPMAP_NEAREST \
      +set r_overBrightBits 0 \
      +set r_stencilbits 0 \
      +set r_swapInterval 0 \
      +set cg_shadows 0 \
      +set cg_marks 0 \
      +set cg_brassTime 0 \
      +set cg_gibs 0 \
      +set s_initsound ''${Q3_SOUND:-0} \
      "$@"
  '';

  # "Nix Fixes This", a 640x360 CPU-rendered demoscene prod with a chiptune. With a
  # demoSize it renders into a window of that size.
  demoSize = map lib.toInt (lib.splitString "x" cfg.demoSize);
  badge-demo-bin = pkgs.nix-fixes-this.override (
    lib.optionalAttrs (cfg.demoSize != null) {
      windowed = true;
      width = lib.elemAt demoSize 0;
      height = lib.elemAt demoSize 1;
    }
  );
  badge-demo = pkgs.writeShellScriptBin "badge-demo" ''
    export SDL_VIDEODRIVER="''${SDL_VIDEODRIVER:-wayland}"
    export SDL_AUDIODRIVER="''${SDL_AUDIODRIVER:-alsa}"
    exec ${badge-demo-bin}/bin/nix-fixes-this "$@"
  '';
in
{
  options.badge.graphics = {
    cube = lib.mkEnableOption "the CODA980 cube and its launch service" // {
      default = pkgs.stdenv.hostPlatform.isAarch64 || touch;
      defaultText = lib.literalExpression "pkgs.stdenv.hostPlatform.isAarch64 || config.badge.graphics.touchBar.enable";
    };

    autostartQuake = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Launch ioquake3 from the sway config.";
    };

    demo = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''Install the "Nix Fixes This" demoscene prod (badge-demo).'';
    };

    demoSize = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "[1-9][0-9]*x[1-9][0-9]*");
      default = null;
      example = "552x320";
      description = "Size of the demo's window, or null for the fullscreen 1280x720 demo.";
    };

    autostartDemo = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Launch badge-demo from the sway config (and install it); ESC in the prod
        quits back to sway.
      '';
    };

    quake = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install ioquake3 and the Quake III demo data.";
    };

    quakeWidth = lib.mkOption {
      type = lib.types.int;
      default = 640;
      description = ''
        ioquake3 render width (r_customwidth). At 640x360 SDL switches the output to
        its GOP-doubled 640x360 mode, three times as fast as 1280x720.
      '';
    };

    quakeHeight = lib.mkOption {
      type = lib.types.int;
      default = 360;
      description = "ioquake3 render height (r_customheight). See quakeWidth.";
    };

    quakeHunkMiB = lib.mkOption {
      type = lib.types.int;
      default = 64;
      description = ''
        ioquake3's up-front hunk allocation (com_hunkMegs), in MiB. Upstream
        defaults to 128; this board has 351 MB of RAM in total.
      '';
    };
  };

  config = lib.mkIf (config.hardware.sg2k.enable && cfg.enable) {
    # id's shareware data: redistributable, not free.
    nixpkgs.config.allowUnfreePredicate =
      p:
      builtins.elem (lib.getName p) [
        "quake3-demodata"
        "quake3-pointrelease"
      ];

    programs.sway.extraSessionCommands = ''
      export DOOMWADDIR="${freedoomWads}/share/games/doom"
    '';

    badge.graphics.autostart =
      lib.optional cfg.autostartQuake "${badge-quake3}/bin/badge-quake3"
      ++ lib.optional cfg.autostartDemo "${badge-demo}/bin/badge-demo";

    environment.systemPackages =
      lib.optionals cfg.quake [
        badge-quake3
        pkgs.ioquake3
        pkgs.quake3demodata
        pkgs.quake3pointrelease
        pkgs.crispy-doom
        badge-doom
        badge-game
      ]
      ++ lib.optionals (cfg.demo || cfg.autostartDemo) [ badge-demo ];

    badge.graphics.demo = lib.mkIf touch (lib.mkDefault true);

    badge.graphics.touchBar.apps = lib.mkIf touch {
      doom = lib.mkIf cfg.quake {
        label = "Doom";
        group = "Games";
        command = lib.getExe badge-doom;
        hideBar = true;
      };
      quake = lib.mkIf cfg.quake {
        label = "Quake";
        group = "Games";
        command = lib.getExe badge-quake3;
        hideBar = true;
      };
      demo = lib.mkIf (cfg.demo || cfg.autostartDemo) {
        label = "Nix Fixes This";
        group = "Demos";
        command = lib.getExe badge-demo;
      };
      cube = lib.mkIf cfg.cube {
        label = "Cube";
        group = "Demos";
        unit = "badge-coda-cube@badge.service";
        system = true;
        appId = "coda-cube";
      };
    };

    # The bar waits for the first picture.
    systemd.services."badge-coda-cube@" = lib.mkIf (touch && cfg.cube) {
      overrideStrategy = "asDropin";
      serviceConfig = {
        Type = "notify";
        TimeoutStartSec = cfg.touchBar.limits.start;
        TimeoutStopSec = cfg.touchBar.limits.stop;
      };
    };

    systemd.user.services = lib.mkIf touch {
      badge-app-doom = lib.mkIf cfg.quake {
        environment.DOOMWADDIR = "${freedoomWads}/share/games/doom";
        serviceConfig.NoNewPrivileges = true;
      };
      badge-app-quake = lib.mkIf cfg.quake { serviceConfig.NoNewPrivileges = true; };
      badge-app-demo = lib.mkIf (cfg.demo || cfg.autostartDemo) {
        environment = {
          SDL_APP_ID = "badge-demo";
          # SDL's own choice, not the launcher's ALSA: sound follows the session's server.
          SDL_AUDIODRIVER = "pipewire,pulseaudio,alsa";
        };
      };
    };
  };
}
