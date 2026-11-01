# Optional OLED panel driver.
{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.badge.oled;
  nixBadge = pkgs.nix-badge.override {
    nixDynamic = cfg.dynamicNix;
  };
in
{
  options.badge.oled = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.hardware.sg2k.oled.enable;
      defaultText = lib.literalExpression "config.hardware.sg2k.oled.enable";
      description = ''
        Run the oled engine on the optional SAO OLED. Without it the WS2812 ring
        still animates.
      '';
    };
    width = lib.mkOption {
      type = lib.types.ints.positive;
      default = 128;
      description = "OLED width in pixels (128 for the SSD1306).";
    };
    height = lib.mkOption {
      type = lib.types.enum [
        32
        64
      ];
      default = 32;
      description = "OLED height in pixels (32 or 64 rows).";
    };
    button = lib.mkOption {
      type = lib.types.str;
      default = "user-btn";
      description = ''
        Device-tree gpio-line-name of the button: a short press cycles the LED
        pattern, a long one the OLED screen. Without such a line the engine runs on
        SIGUSR1/2 alone. btn-boot-n belongs to bootswap.
      '';
    };
    backend = lib.mkOption {
      type = lib.types.enum [
        "fix"
        "nix"
      ];
      default = "fix";
      description = ''
        The evaluator for the eval screens: "fix" (embedded) or "nix" (the Nix C API,
        aarch64 only; elsewhere it falls back to fix). A >5 s button hold flips it
        and saves the choice to /etc/nix-badge/oled.backend, which wins over this.
      '';
    };
    blingDir = lib.mkOption {
      type = lib.types.str;
      default = "/etc/nix-badge/bling.d";
      description = ''
        Directory of pure-Nix LED patterns (*.nix, in name order) that a short press
        cycles through, by writing the next one into leds.conf.
      '';
    };
    dynamicNix = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Link the engine's Nix C API dynamically: seconds instead of a ~15-minute
        static link, for a bigger closure.
      '';
    };
    controller = lib.mkOption {
      type = lib.types.enum [
        "auto"
        "ssd1306"
        "sh1106"
      ];
      default = "auto";
      description = ''
        Which controller drives the panel. "auto" detects automatically.
      '';
    };
    gcBudgetMb = lib.mkOption {
      type = lib.types.ints.positive;
      default = 32;
      description = ''
        The fix Engine's GC collection line, in MiB: the heap-reserved size at which
        an allocation triggers a collection.
      '';
    };
    evalScreens = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      description = ''
        Pure-Nix OLED screens, `scope: { bitmap = [ <int> ... ]; nextMs; }` (4 page
        bytes per int, little-endian), compiled into one shared fix Engine. A long
        press or SIGUSR2 cycles them; a screen that fails to compile is skipped.
      '';
      example = lib.literalExpression ''
        [
          "''${pkgs.bling-badapple-live}/badapple-live.nix"
        ]
      '';
    };
    ethInterface = lib.mkOption {
      type = lib.types.str;
      default = "eth0";
      example = "end0";
      description = ''
        The wired interface whose IPv4 address the `net` screen shows (passed as
        `--eth-iface`).
      '';
    };
    wlanInterface = lib.mkOption {
      type = lib.types.str;
      default = "wlan0";
      example = "wlp1s0";
      description = ''
        The wireless interface whose IPv4 address the `net` screen shows (passed
        as `--wlan-iface`).
      '';
    };
    evalDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        A directory of *.nix screens, read at run time in name order. They may
        `import <nix-badge/lib/...>` (nix-badge=/etc/nix-badge).
      '';
    };
  };

  config = lib.mkIf (config.hardware.sg2k.enable && cfg.enable) {
    systemd.services.nix-badge-oled = {
      description = "nix-badge OLED engine";
      wantedBy = [ "sysinit.target" ];
      after = [
        "local-fs.target"
        "nix-badge-content.service"
      ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        # Root: the I2C bus, the SARADC, the button and leds.conf.
        ExecStart = lib.concatStringsSep " " (
          [
            "${nixBadge}/bin/nix-badge oled"
            "--oled-width ${toString cfg.width}"
            "--oled-height ${toString cfg.height}"
            "--button ${cfg.button}"
            "--backend ${cfg.backend}"
            "--gc-budget-mb ${toString cfg.gcBudgetMb}"
            "--oled-controller ${cfg.controller}"
            "--bling-dir ${cfg.blingDir}"
            "--eth-iface ${cfg.ethInterface}"
            "--wlan-iface ${cfg.wlanInterface}"
          ]
          ++ map (p: "--eval-screen ${p}") cfg.evalScreens
          ++ lib.optional (cfg.evalDir != null) "--eval-dir ${cfg.evalDir}"
        );
        # Exits 0 when the panel is absent.
        Restart = "on-failure";
        RestartSec = 20;
        # Cap the fix Engine to its own cgroup.
        MemoryMax = "220M";
        MemorySwapMax = "512M";
        CPUWeight = 1;
      };
    };
  };
}
