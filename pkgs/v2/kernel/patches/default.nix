# The badge kernel's patches and config, in order: boot.kernelPatches entries for every
# board and core (modules/sg2k/kernel.nix).
{ lib }:
let
  ap = ./armbian;
in
[
  {
    name = "enable-spidev-for-leds";
    patch = null;
    # The WS2812 ring (SPI3, by DMA) and the OLED (I2C1). riscv's defconfig lacks
    # SPI_DW_DMA, which leaves spi-dw on PIO without a warning.
    structuredExtraConfig = with lib.kernel; {
      SPI = yes;
      SPI_DESIGNWARE = yes;
      SPI_DW_MMIO = yes;
      SPI_DW_DMA = yes;
      SPI_SPIDEV = yes;
      I2C = yes;
      I2C_CHARDEV = yes;
      I2C_DESIGNWARE_CORE = yes;
      I2C_DESIGNWARE_PLATFORM = yes;
    };
  }
  {
    # Coherent DMA from the cma= pool; stmmac's rings fail under fragmentation
    # without it.
    name = "enable-cma-for-coherent-dma";
    patch = null;
    structuredExtraConfig = with lib.kernel; {
      CMA = yes;
      DMA_CMA = yes;
    };
  }
  {
    # dw-axi-dmac logs "apb_regs not initialized" on every dmamux transfer.
    name = "dw-axi-dmac-apb-regs-quiet";
    patch = ./dw-axi-dmac-apb-regs-quiet.patch;
  }
  {
    name = "dw-axi-dmac-desc-put-null-guard";
    patch = ./dw-axi-dmac-desc-put-null-guard.patch;
  }
  {
    name = "spi-dw-ser-bit0";
    patch = ./spi-dw-ser-bit0.patch;
  }
  {
    name = "sharp-memory-partial-flush";
    patch = ./sharp-memory-partial-flush.patch;
  }
  {
    name = "enable-sharp-memory-drm";
    patch = null;
    structuredExtraConfig = with lib.kernel; {
      DRM = yes;
      TINYDRM_SHARP_MEMORY = yes;
      FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER = lib.mkForce no;
    };
  }
  {
    # The boot-time DAMON stats kdamond burns ~1.2% of the core for nothing.
    name = "no-damon-stat-by-default";
    patch = null;
    structuredExtraConfig.DAMON_STAT_ENABLED_DEFAULT = lib.kernel.no;
  }
  {
    # The cv18xx pad-rail voltage switch for the SD and eMMC hosts (dwcmshc); the wifi
    # node uses sdhci-cv181x's own.
    name = "cv18xx-sdio-voltage-switch";
    patch = ./cv18xx-vsw.patch;
  }
  {
    # The cv18xx host cannot deliver async SDIO interrupts.
    name = "mmc-no-async-sdio-irq";
    patch = ./mmc-no-async-irq.patch;
  }
  {
    name = "sophgo-saradc-completion-race";
    patch = ./sophgo-saradc-completion-race.patch;
  }
  # dw_wdt is the only restart handler that resets this SoC (PSCI SYSTEM_RESET
  # never returns from bl31), so build it in and run it first.
  {
    name = "enable-dw-wdt-reboot";
    patch = null;
    structuredExtraConfig = with lib.kernel; {
      WATCHDOG = yes;
      WATCHDOG_CORE = yes;
      DW_WATCHDOG = yes;
    };
  }
  {
    name = "dw-wdt-restart-before-psci";
    patch = ./dw-wdt-restart-before-psci.patch;
  }
  # Without a reset controller SPI3 stays half-reset (garbled ring, dead Sharp panel).
  {
    name = "enable-reset-simple";
    patch = null;
    structuredExtraConfig = with lib.kernel; {
      RESET_CONTROLLER = yes;
      RESET_SIMPLE = yes;
    };
  }
  # Armbian's sophgo-sg200x series (armbian/build#10326, rebased onto 7.3): bindings, then drivers.
  {
    name = "sophgo-thermal-binding";
    patch = "${ap}/0007-dt-bindings-thermal-sophgo-cv1800-thermal-Add-Sophgo.patch";
  }
  {
    name = "sophgo-mdio-mux-binding";
    patch = "${ap}/0010-dt-bindings-net-Add-Sophgo-CV1800-MDIO-multiplexer.patch";
  }
  {
    name = "sophgo-pwm-binding";
    patch = "${ap}/0019-dt-bindings-pwm-sophgo-add-pwm-for-Sophgo-CV1800-ser.patch";
  }
  {
    name = "sophgo-c906l-binding";
    patch = "${ap}/0021-dt-bindings-remoteproc-Add-C906L-rproc-for-Sophgo-CV.patch";
  }
  {
    name = "sophgo-efuse-binding";
    patch = "${ap}/0027-dt-bindings-nvmem-Add-sophgo-efuses.patch";
  }

  {
    name = "sophgo-cv1800-thermal";
    patch = "${ap}/0008-thermal-cv1800-Add-cv1800-thermal-driver-support.patch";
  }
  {
    name = "sophgo-cv1800-mdio-mux";
    patch = "${ap}/0012-net-mdio-mux-Add-MDIO-mux-driver-for-Sophgo-CV1800-S.patch";
  }
  {
    name = "sophgo-cv1800-pwm";
    patch = "${ap}/0022-pwm-sophgo-add-pwm-support-for-Sophgo-CV1800-SoC.patch";
  }
  {
    name = "sophgo-c906l-remoteproc";
    patch = "${ap}/0023-drivers-remoteproc-Add-C906L-controller-for-Sophgo-C.patch";
  }
  # After 0023: it fixes the file 0023 creates.
  {
    name = "sophgo-c906l-remoteproc-probe-fix";
    patch = "${ap}/0037-drivers-remoteproc-fix-C906L-probe-function.patch";
  }
  {
    name = "sophgo-efuse-driver";
    patch = "${ap}/0028-nvmem-Add-Sophgo-eFuse-driver-DRIVER-ONLY.patch";
  }

  # Lets the I2S pads take a pin state, so the HDMI audio card can probe.
  {
    name = "sophgo-pinctrl-audio-pads";
    patch = ./sophgo-pinctrl-audio-pads.patch;
  }
  {
    name = "lt8912b-hactive-offset";
    patch = ./lt8912b-hactive-offset.patch;
  }
  {
    name = "lt8912b-hdmi-audio";
    patch = ./lt8912b-hdmi-audio.patch;
  }
  {
    name = "hynitron-cstxxx-firmware-probe";
    patch = ./hynitron-cstxxx-firmware-probe.patch;
  }
  {
    # The LicheeRV Nano's DSI panel touchscreen (hardware.sg2k.dsiPanel).
    name = "enable-hynitron-touchscreen";
    patch = null;
    structuredExtraConfig = with lib.kernel; {
      INPUT_TOUCHSCREEN = yes;
      TOUCHSCREEN_HYNITRON_CSTXXX = module;
    };
  }
  {
    name = "sophgo-soc-features-config";
    patch = null;
    structuredExtraConfig = with lib.kernel; {
      # /dev/mem reaches neither RAM nor a register a driver claimed: media buffers
      # are mapped through /dev/soph-ion, and booting with iomem=relaxed by hand
      # opens claimed registers to nix-badge mmio.
      STRICT_DEVMEM = lib.mkForce yes;
      IO_STRICT_DEVMEM = lib.mkForce yes;

      # 32 fewer nodes for udev to walk at boot.
      LEGACY_PTYS = lib.mkForce no;

      # Built in, so dw_spi does not defer until they autoload minutes into boot.
      DW_AXI_DMAC = lib.mkForce yes;
      SOPHGO_CV1800B_DMAMUX = lib.mkForce yes;

      # MMC_BLOCK can be no more built-in than RPMB (`RPMB || !RPMB`).
      RPMB = lib.mkForce yes;
      MMC_BLOCK = lib.mkForce yes;
      # Else the SD pads are never muxed.
      PINCTRL_SOPHGO_CV1800B = lib.mkForce yes;

      # The squashfs root and stage-0's overlays mount before any module can load.
      SQUASHFS = lib.mkForce yes;
      SQUASHFS_ZSTD = lib.mkForce yes;
      SQUASHFS_XZ = lib.mkForce yes;
      OVERLAY_FS = lib.mkForce yes;
      # dm-init assembles the verity root from the command line. BLK_DEV_DM can be
      # no more built-in than DAX, which the ACPI_NFIT -> LIBNVDIMM chain selects as
      # m, so cut that chain at its root.
      ACPI_NFIT = lib.mkForce no;
      LIBNVDIMM = lib.mkForce no;
      BLK_DEV_DM = lib.mkForce yes;
      DM_INIT = lib.mkForce yes;
      DM_VERITY = lib.mkForce yes;
      # verity's hash; =y in the base config, but unpinned there.
      CRYPTO_SHA256 = lib.mkForce yes;

      # The Armbian drivers above.
      CV1800_THERMAL = module;
      PWM_CV1800 = module;
      SOPHGO_CV1800B_C906L = module;
      NVMEM_SOPHGO_EFUSE = module;
      # Already =y through another selector.
      MDIO_BUS_MUX = yes;
      MDIO_BUS_MUX_SOPHGO_CV1800B = module;

      # The CDC-NCM gadget (usb-gadget.nix).
      CONFIGFS_FS = yes;
      USB_CONFIGFS = module;
      USB_CONFIGFS_NCM = yes;

      # ramoops (0x90000000, in the DTS), built in so the dumper is registered
      # before a panic.
      PSTORE_CONSOLE = yes;
      PSTORE_PMSG = yes;
      PSTORE_RAM = yes;

      # HDMI audio over I2S2 -> LT8912B. SND_SOC is y on riscv64, so it is not forced.
      SND_SOC_CV1800B_TDM = module;
      SND_SIMPLE_CARD = module;
      SND_SOC_SPDIF = module;
    };
  }
]
