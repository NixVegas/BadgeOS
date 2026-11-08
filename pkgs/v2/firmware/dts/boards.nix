# Per board: the DTB's file name, the top DTS for each core, the USB host fragment,
# and every file those include. A board's DTB build sees only its `files`.
{
  nix-badge = {
    dtb = "sg2000-nix-badge.dtb";
    top = {
      arm = "sg2000-nix-badge.dts";
      riscv = "sg2000-nix-badge-riscv.dts";
    };
    usbHost = "nix-badge-usb-host.dtsi";
    files = [
      "sg2000-nix-badge.dts"
      "sg2000-nix-badge-riscv.dts"
      "sg2000-module-01.dtsi"
      "sg200x-vip.dtsi"
      "nix-badge.dtsi"
      "sg200x-riscv.dtsi"
      "lt8912b-bridge.dtsi"
      "nix-badge-usb-host.dtsi"
    ];
  };

  licheerv-nano = {
    dtb = "sg2002-licheerv-nano.dtb";
    top = {
      arm = "sg2002-licheerv-nano-arm.dts";
      riscv = "sg2002-licheerv-nano.dts";
    };
    usbHost = "licheerv-nano-usb-host.dtsi";
    files = [
      "sg2002-licheerv-nano.dts"
      "sg2002-licheerv-nano-arm.dts"
      "licheerv-nano.dtsi"
      "sg2002-arm.dtsi"
      "sg200x-riscv.dtsi"
      "licheerv-nano-usb-host.dtsi"
      "licheerv-nano-no-wifi.dtsi"
      "licheerv-nano-no-ethernet.dtsi"
      "licheerv-nano-dsi-panel.dtsi"
      "sg200x-vip.dtsi"
    ];
  };
}
