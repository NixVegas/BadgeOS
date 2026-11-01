# The Armbian sophgo-sg200x patches (rebased onto 7.3) that touch arch/*/boot/dts, applied to kernel.src
# for the board DTBs, in apply order. The driver patches live in ../default.nix.
[
  # 0002, 0004, 0005, 0006 and 0015 dropped: linux 7.3 ships the Milk-V Duo S board
  # .dts on both arches and riscv sg2000.dtsi (512 MiB, USB host) itself.
  ./0009-riscv-dts-sophgo-add-cv180x-thermal-sensor-dts-node.patch
  ./0011-riscv-dts-sophgo-add-thermal-zones-for-cv180x.patch
  ./0013-riscv-dts-sophgo-add-timer-dt-node-for-CV1800.patch
  ./0014-riscv64-dts-sophgo-use-mdio-mux-driver-for-Sophgo-CV.patch
  ./0016-riscv64-dts-sophgo-add-watchdog-timer-node-for-Sophg.patch
  ./0017-riscv64-dts-sophgo-enable-cv180x-watchdog-timer-for-.patch
  ./0018-riscv64-dts-sophgo-enable-uart4-for-sg2000-milkv-duo.patch
  ./0020-riscv-dts-sophgo-enable-all-peripherals-for-sg2000.patch
  # 0026 (cv180x DMA-mux compatible) is upstream as of 7.2.8.
  ./0028-nvmem-Add-Sophgo-eFuse-driver.patch
  ./0029-riscv-dts-sophgo-enable-efuse-for-sg2000-milkv-duo-s.patch
  ./0030-riscv-dts-sophgo-dts-nodes-for-i2s-tdm-modules.patch
  ./0031-riscv-dts-sophgo-add-cv1800-PWM-device-nodes.patch
  ./0032-riscv-dts-sophgo-enable-PWM-chips-for-sg2000-milkv-d.patch
  ./0033-riscv-dts-sophgo-enable-I2S-devices-for-sg2000-milkv.patch
  ./0034-riscv-dts-sophgo-add-mailbox-node-for-cv180x.patch
  ./0035-riscv-dts-sophgo-add-remoteproc-nodes-for-sg2000.patch
  ./0036-riscv-dts-sophgo-add-board-support-for-Milk-V-Duo-25.patch
  ./0038-riscv-dts-sophgo-cv180x-use-SOC_PERIPHERAL_IRQ-for-d.patch
  ./0039-arm64-dts-sophgo-enable-Milk-V-Duo-S-peripherals-in-.patch
  ./0040-riscv-dts-sophgo-put-the-Milk-V-Duo-S-USB-port-in-ho.patch
  ./0041-arm64-dts-sophgo-put-the-Milk-V-Duo-S-USB-port-in-ho.patch
  # 0042, 0043, 0054 and 0055 dropped: the 7.3 board .dts muxes the eMMC and microSD
  # pads itself (emmc_cfg, sdhci0_cfg).
  ./0044-riscv-dts-sophgo-disable-the-unused-Milk-V-Duo-S-cop.patch
  ./0045-arm64-dts-sophgo-disable-the-unused-Milk-V-Duo-S-cop.patch
  ./0046-riscv-dts-sophgo-note-that-Milk-V-Duo-S-uart2-pads-a.patch
  ./0047-arm64-dts-sophgo-note-that-Milk-V-Duo-S-uart2-pads-a.patch
  ./0048-riscv-dts-sophgo-add-a-Milk-V-Duo-S-C906L-overlay.patch
  ./0049-arm64-dts-sophgo-add-a-Milk-V-Duo-S-C906L-overlay.patch
  ./0050-riscv-dts-sophgo-add-a-Milk-V-Duo-S-USB-device-mode-.patch
  ./0051-arm64-dts-sophgo-add-a-Milk-V-Duo-S-USB-device-mode-.patch
  ./0052-riscv-dts-sophgo-add-Milk-V-Duo-S-pin-header-overlay.patch
  ./0053-arm64-dts-sophgo-add-Milk-V-Duo-S-pin-header-overlay.patch
  ./0056-riscv-dts-sophgo-reserve-a-ramoops-region-on-the-Mil.patch
  ./0057-arm64-dts-sophgo-reserve-a-ramoops-region-on-the-Mil.patch
]
