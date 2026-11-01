# The WS2812 LED ring on SPI3, through spidev. `nix-badge bling set` writes
# /etc/nix-badge/leds.conf, and the service reloads all of it but device and csHigh.
{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.badge.bling;

  deviceUnit = "${utils.escapeSystemdPath cfg.device}.device";

  # No Nix C API: the ring evaluates through fix, and the C API's static link is slow.
  pkg = pkgs.nix-badge-noeval;

  configFile = pkgs.writeText "nix-badge-leds.conf" ''
    device = ${cfg.device}
    count = ${toString cfg.count}
    speed_hz = ${toString cfg.speedHz}
    bits = ${toString cfg.bits}
    cs_high = ${if cfg.csHigh then "1" else "0"}
    brightness = ${toString cfg.brightness}
    fps = ${toString cfg.fps}
    ${lib.optionalString (cfg.blob != null) "blob = ${cfg.blob}"}
    ${lib.optionalString (cfg.evalPattern != null) "eval = ${cfg.evalPattern}"}
  '';
in
{
  options.badge.bling = {
    enable = lib.mkEnableOption "the badge WS2812 LED ring" // {
      default = config.hardware.sg2k.ledRing.enable;
      defaultText = lib.literalExpression "config.hardware.sg2k.ledRing.enable";
    };

    count = lib.mkOption {
      type = lib.types.ints.positive;
      description = "Number of WS2812 LEDs on the ring.";
    };

    blob = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        A baked "BLED" RGB-frame blob to play on the ring (see nix-badge-bling-content's
        leds.nix). With neither this nor `evalPattern`, the ring shows a dim blue fill.
      '';
    };

    evalPattern = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        A pure-Nix LED pattern, `scope: { bitmap = [ 0xRRGGBB ... ]; nextMs; }`,
        evaluated every frame. Takes precedence over `blob`.
      '';
    };

    backend = lib.mkOption {
      type = lib.types.enum [
        "fix"
        "nix"
      ];
      default = "fix";
      description = ''
        The evaluator for `evalPattern`: "fix" (embedded) or "nix" (the Nix C API,
        aarch64 only; elsewhere it falls back to fix).
      '';
    };

    device = lib.mkOption {
      type = lib.types.str;
      default = "/dev/spidev3.0";
      description = "spidev node for the SPI3 controller.";
    };

    bits = lib.mkOption {
      type = lib.types.enum [
        3
        4
        8
      ];
      default = 8;
      description = ''
        SPI bits sent for each WS2812 bit: 8 (0 -> 10000000, 1 -> 11111100), 4
        (1000, 1110) or 3 (100, 110; flips bits at random on this badge's LEDs).
      '';
    };

    csHigh = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Ask spidev for SPI_CS_HIGH. Keep this true: the LED ring only takes data while
        chip select is high (LED_DIN = CS AND SDO). The device tree's GPIO chip select
        already sets that polarity, so this option is only for overriding it.
      '';
    };

    speedHz = lib.mkOption {
      type = lib.types.ints.positive;
      default = 6400000;
      description = ''
        SPI clock in Hz; with `bits` it sets the LED bit time. The driver rounds it
        to an even divisor of ssi_clk, and the service logs the timing it got. The
        badge's XL-1615/XL-2020 LEDs want a T1H of 0.9 to 1.0 us.
      '';
    };

    brightness = lib.mkOption {
      type = lib.types.ints.between 0 255;
      default = 64;
      description = "Global brightness, applied by scaling the colour channels.";
    };

    fps = lib.mkOption {
      type = lib.types.ints.between 1 200;
      default = 30;
      description = "Animation frames per second.";
    };
  };

  config = lib.mkIf (config.hardware.sg2k.enable && cfg.enable) {
    environment.systemPackages = [ pkg ];

    # spidev is not tagged for systemd by default, so it would have no .device unit.
    services.udev.extraRules = ''
      KERNEL=="${lib.removePrefix "/dev/" cfg.device}", TAG+="systemd", ENV{SYSTEMD_WANTS}+="nix-badge-bling.service"
    '';

    # The node exists early, but its .device unit waits for udev's coldplug backlog
    # (about a minute on one core); process this one device first.
    systemd.services.nix-badge-spidev-announce = {
      description = "Announce ${cfg.device} to systemd ahead of the coldplug backlog";
      wantedBy = [ "sysinit.target" ];
      after = [ "systemd-udevd.service" ];
      before = [ "systemd-udev-trigger.service" ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # "-": only a speedup, so a failure is not an error.
        ExecStart = "-${config.systemd.package}/bin/udevadm trigger --action=add --sysname-match=${lib.removePrefix "/dev/" cfg.device}";
      };
    };

    systemd.services.nix-badge-bling = {
      description = "nix-badge WS2812 LED ring";
      wantedBy = [ "sysinit.target" ];

      # nix-badge does not wait for the node itself.
      after = [ deviceUnit ];
      bindsTo = [ deviceUnit ];

      unitConfig = {
        DefaultDependencies = false;
        IgnoreOnIsolate = true;
        SurviveFinalKillSignal = true;
      };
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkg}/bin/nix-badge bling run --config ${configFile} --backend ${cfg.backend}";
        # Exits 0 without the spidev node; a long RestartSec keeps an OOM kill from
        # respinning tightly.
        Restart = "on-failure";
        RestartSec = 20;
        # Cap the fix Engine to its own cgroup.
        MemoryMax = "96M";
        MemorySwapMax = "128M";
      };
    };
  };
}
