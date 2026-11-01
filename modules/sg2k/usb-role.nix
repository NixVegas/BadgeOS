# The USB-C port's role, host or device. dr_mode is read once at probe, so a role is a
# DTB ("otg" soft-locks: USB_DATA_HOST and USB_VBUS_EN share a net), and the gadget runs
# only as a device.
{
  config,
  lib,
  ...
}:
let
  cfg = config.hardware.sg2k.usb;
in
{
  imports = [
    (lib.mkChangedOptionModule [ "hardware" "sg2k" "usb" "hostMode" ] [ "hardware" "sg2k" "usb" "role" ]
      (config: if config.hardware.sg2k.usb.hostMode then "host" else "device")
    )
    (lib.mkRemovedOptionModule [
      "hardware"
      "sg2k"
      "usb"
      "specialise"
    ] "The other USB role is no longer a specialisation; set hardware.sg2k.usb.role.")
  ];

  options.hardware.sg2k.usb.role = lib.mkOption {
    type = lib.types.enum [
      "host"
      "device"
    ];
    default = "device";
    description = ''
      The USB-C port's role. As a device the badge is a USB network adapter (the
      gadget); as a host it powers the port and a keyboard, mouse or hub enumerates. The
      desktop profile is a host.

      As a host the badge is not reachable over usb0; deploy over Ethernet or WiFi.
    '';
  };

  config = lib.mkIf config.hardware.sg2k.enable {
    # The board DTB for this core in this role, built against the kernel. Forced over
    # the DTBs NixOS would take from the kernel.
    hardware.deviceTree.package = lib.mkForce (
      config.hardware.sg2k.dtb.package.override {
        kernel = config.boot.kernelPackages.kernel;
        usbHost = cfg.role == "host";
      }
    );

    hardware.sg2k.usb.gadget.enable = lib.mkIf (cfg.role == "host") false;
  };
}
