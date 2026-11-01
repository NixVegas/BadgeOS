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
    inherit (cfg) outputMode;
    sway = config.programs.sway.package;
  };

  # ioquake3 tuned for llvmpipe on one in-order core. Keep the depth test (early-Z)
  # and mipmaps on.
  badge-quake3 = pkgs.writeShellScriptBin "badge-quake3" ''
    set -e
    export LIBGL_ALWAYS_SOFTWARE=1
    export GALLIUM_DRIVER="''${GALLIUM_DRIVER:-llvmpipe}"
    export SDL_VIDEODRIVER="''${SDL_VIDEODRIVER:-wayland}"

    # Rasterise inline: one worker thread on one CPU costs 32%.
    export LP_NUM_THREADS="''${LP_NUM_THREADS:-0}"

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

  # "Nix Fixes This", a 640x360 CPU-rendered demoscene prod with a chiptune.
  badge-demo-bin = pkgs.nix-fixes-this;
  badge-demo = pkgs.writeShellScriptBin "badge-demo" ''
    export SDL_VIDEODRIVER="''${SDL_VIDEODRIVER:-wayland}"
    export SDL_AUDIODRIVER="''${SDL_AUDIODRIVER:-alsa}"
    exec ${badge-demo-bin}/bin/nix-fixes-this "$@"
  '';
in
{
  options.badge.graphics = {
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
        (pkgs.badge-doom.override { inherit badge-game; })
        badge-game
      ]
      ++ lib.optionals (cfg.demo || cfg.autostartDemo) [ badge-demo ];
  };
}
