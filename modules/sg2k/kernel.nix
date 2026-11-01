{
  lib,
  pkgs,
  config,
  ...
}:
{
  config = lib.mkIf config.hardware.sg2k.enable {
    boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_latest;
    boot.kernelPatches =
      import ../../pkgs/v2/kernel/patches { inherit lib; }
      # There is no initrd, so the SD and console pads need their pin controller built
      # in. arm64's defconfig builds in only the SG2000's; riscv's builds in both.
      ++ lib.optional (config.hardware.sg2k.soc == "sg2002" && pkgs.stdenv.hostPlatform.isAarch64) {
        name = "sg2002-pinctrl";
        patch = null;
        structuredExtraConfig.PINCTRL_SOPHGO_SG2002 = lib.kernel.yes;
      };

    boot.kernelParams = [
      "panic=10"
    ]
    # The last console= (serial) is /dev/console; tty1 is the Sharp panel's, mounted
    # upside down.
    ++ lib.optional config.hardware.sg2k.sharpPanel.enable "console=tty1"
    ++ [
      "console=ttyS0,115200"
      "earlycon"
    ]
    ++ lib.optional config.hardware.sg2k.sharpPanel.enable "fbcon=rotate:2"
    ++ [
      # The VIP display block boots with a clock the clk framework would gate, after
      # which any MMIO to it deadlocks the AXI interconnect.
      "clk_ignore_unused"
      "pd_ignore_unused"

      "cma=${toString config.hardware.sg2k.memory.cmaMiB}M"
    ];

    boot.kernelModules = [
      # i2c-dev: the SAO OLED on /dev/i2c-1; the eFuse nvmem: read by nix-badge-hostname.
      "i2c-dev"
      "nvmem_sophgo_efuse"
    ];

    # The board DTB for this core, compiled from the kernel's DTS sources in the USB role
    # (usb-role.nix).
    hardware.deviceTree = {
      enable = true;
      name = config.hardware.sg2k.dtb.name;
    };
  };
}
