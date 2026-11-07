# Board facts and capability flags. A board file under boards/ sets them; the feature
# modules read the flags, never the board name.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkEnableOption mkOption types;
  cfg = config.hardware.sg2k;
in
{
  options.hardware.sg2k = {
    enable = mkEnableOption "SG200x board support";

    board = mkOption {
      type = types.enum [
        "nix-badge"
        "licheerv-nano"
      ];
      default = "nix-badge";
      description = ''
        The board this system runs on.
      '';
    };

    soc = mkOption {
      type = types.enum [
        "sg2000"
        "sg2002"
      ];
      description = "The SoC on the board.";
    };

    cores = mkOption {
      type = types.listOf (
        types.enum [
          "arm"
          "riscv"
        ]
      );
      description = "The cores the board can boot.";
    };

    core = mkOption {
      type = types.enum [
        "arm"
        "riscv"
      ];
      default = if pkgs.stdenv.hostPlatform.isAarch64 then "arm" else "riscv";
      defaultText = lib.literalExpression ''if pkgs.stdenv.hostPlatform.isAarch64 then "arm" else "riscv"'';
      readOnly = true;
      internal = true;
      description = "The core this system boots on, from the host platform.";
    };

    memory.sizeMiB = mkOption {
      type = types.ints.positive;
      description = "DRAM size in MiB.";
    };

    memory.cmaMiB = mkOption {
      type = types.int;
      # The desktop and video profiles raise it to 128.
      default = 16;
      description = ''
        Size of the CMA reservation (the cma= kernel parameter), in MiB. gmac0's
        descriptor rings and the VIP video-buffer pool (one 11.25 MB request) share it.
      '';
    };

    dtb.name = mkOption {
      type = types.str;
      description = "The board DTB, relative to the kernel's dtbs directory.";
    };

    dtb.package = mkOption {
      type = types.package;
      internal = true;
      description = "This core's board DTB package, before it is built against the kernel.";
    };

    emmc.enable = mkEnableOption "the on-board eMMC";
    externalStorage.enable = mkOption {
      type = types.bool;
      default = config.hardware.sg2k.emmc.enable;
      defaultText = lib.literalExpression "config.hardware.sg2k.emmc.enable";
      description = ''
        Data cards: booted from the eMMC with an SD card whose GPT has a partition named
        EXT_USERDATA (ext4), the card takes every write and the eMMC's USERDATA is read
        through it, read-only. A FAT32 partition named BOOT on the card lets the badge be
        deployed to with the card in.
      '';
    };
    ethernet.enable = mkEnableOption "the on-board Ethernet";

    wifi = {
      enable = mkEnableOption "the on-board AIC8800 WiFi";
      bluetooth = mkOption {
        type = types.enum [
          "none"
          "sdio"
          "uart"
        ];
        default = "none";
        description = "How the WiFi chip's Bluetooth is attached, if at all.";
      };
      firmware = mkOption {
        type = types.str;
        default = "aic8800D80";
        example = "aic8800";
        description = "The WiFi chip's firmware set: a directory of the vendor tree's SDIO firmware.";
      };
    };

    hdmi = {
      enable = mkEnableOption "HDMI output through the LT8912B bridge";

      audio = mkOption {
        type = types.bool;
        default = false;
        description = "HDMI mode with I2S audio on the LT8912B (its hdmi_audio parameter).";
      };

      hactiveOffset = mkOption {
        type = types.int;
        default = 0;
        description = ''
          Pixels added to the LT8912B bridge's programmed active width (the
          lontium_lt8912b hactive_offset parameter, from a kernel.nix patch). Some DSI
          sources shear ~1 px/row at the exact width; 0 is upstream behaviour. Tunable
          live at /sys/module/lontium_lt8912b/parameters/hactive_offset.
        '';
      };
    };
    ledRing.enable = mkEnableOption "the WS2812 LED ring on SPI3";
    oled.enable = mkEnableOption "the I2C OLED";
    sharpPanel.enable = mkEnableOption "the Sharp memory panel as the system console";
    dsiPanel.enable = mkEnableOption "the ST7701 DSI panel and CST340 touchscreen of the MaixCAM, a LicheeRV Nano on a carrier";
    coreSelect.enable = mkEnableOption "switching the boot core from Linux";
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.elem cfg.core cfg.cores;
        message = "hardware.sg2k: core ${cfg.core} is not one of the board's cores (${lib.concatStringsSep ", " cfg.cores})";
      }
      {
        assertion = cfg.coreSelect.enable -> lib.length cfg.cores > 1;
        message = "hardware.sg2k.coreSelect.enable needs a board with more than one core";
      }
      {
        assertion = cfg.wifi.bluetooth != "none" -> cfg.wifi.enable;
        message = "hardware.sg2k.wifi.bluetooth needs hardware.sg2k.wifi.enable";
      }
      {
        # The desktop profile's 128 MiB pool is a quarter of the badge's 512 MiB.
        assertion = cfg.memory.cmaMiB * 4 <= cfg.memory.sizeMiB;
        message = "hardware.sg2k.memory.cmaMiB (${toString cfg.memory.cmaMiB}) is more than a quarter of hardware.sg2k.memory.sizeMiB (${toString cfg.memory.sizeMiB})";
      }
      {
        assertion = cfg.hdmi.audio -> cfg.hdmi.enable;
        message = "hardware.sg2k.hdmi.audio needs hardware.sg2k.hdmi.enable";
      }
    ];
  };
}
