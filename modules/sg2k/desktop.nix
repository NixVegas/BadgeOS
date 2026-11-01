# The `desktop` boot specialisation: Sway on HDMI, with the USB port as a host.
{
  config,
  lib,
  ...
}:
let
  cfg = config.badge;
in
{
  options.badge.desktop.enable = lib.mkEnableOption "desktop boot specialisation" // {
    default = config.hardware.sg2k.hdmi.enable;
    defaultText = lib.literalExpression "config.hardware.sg2k.hdmi.enable";
  };

  config = lib.mkMerge [
    (lib.mkIf config.hardware.sg2k.enable {
      assertions = [
        {
          assertion = cfg.desktop.enable -> config.hardware.sg2k.hdmi.enable;
          message = "badge.desktop.enable needs hardware.sg2k.hdmi.enable";
        }
      ];
    })

    (lib.mkIf (config.hardware.sg2k.enable && cfg.desktop.enable && !cfg.isSpecialisation) {
      specialisation.desktop.configuration = lib.mkMerge [
        {
          badge.isSpecialisation = true;
          system.nixos.variant_id = "desktop";
        }

        {
          # A keyboard and mouse on the USB-C port, whatever the base system pins.
          hardware.sg2k.usb.role = lib.mkForce "host";

          badge.graphics.enable = true;
          badge.graphics.autostartQuake = false;
          badge.graphics.demo = true;
          hardware.sg2k.display.autoLoadDrm = true;
          hardware.sg2k.memory.cmaMiB = 128;

          # The desktop is on HDMI instead.
          badge.oled.enable = lib.mkForce false;

          # The desktop is a client on the wired network.
          badge.router.enable = lib.mkForce false;
          badge.ipxe.enable = lib.mkForce false;
        }
      ];
    })
  ];
}
