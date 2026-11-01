# The badge's own network: its address, and DHCP and DNS (dnsmasq) for what is on it. With
# the router on, that is the router's bridge; with it off, the USB gadget link to one host.
{
  lib,
  config,
  ...
}:
let
  cfg = config.badge.lan;
  routed = config.badge.router.enable;
  # The USB link alone comes and goes with the host at the other end.
  onUsb = !routed;
  served =
    cfg.enable
    && (cfg.dhcp || cfg.dns)
    && (routed || (config.hardware.sg2k.enable && config.hardware.sg2k.usb.gadget.enable));
  device = "sys-subsystem-net-devices-${cfg.interface}.device";

  renamed =
    name:
    lib.mkRenamedOptionModule
      [ "hardware" "sg2k" "usb" "gadget" "hostNetwork" name ]
      [
        "badge"
        "lan"
        name
      ];
in
{
  imports = map renamed [
    "enable"
    "address"
    "prefixLength"
    "poolStart"
    "poolEnd"
    "dhcp"
    "dns"
    "offerGateway"
  ];

  options.badge.lan = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Give the badge its address on its own network and serve what is on it: the
        router's LAN, or with the router off the computer on the USB port. The router
        needs it on.
      '';
    };
    interface = lib.mkOption {
      type = lib.types.str;
      default = if routed then "lan0" else config.badge.router.interfaces.usb;
      defaultText = lib.literalExpression ''
        if config.badge.router.enable then "lan0" else config.badge.router.interfaces.usb
      '';
      description = "The badge's network: the bridge the router makes, or the USB link.";
    };
    address = lib.mkOption {
      type = lib.types.str;
      default = "10.55.0.1";
      description = "The badge's address on its network.";
    };
    prefixLength = lib.mkOption {
      type = lib.types.int;
      default = 24;
      description = "The prefix length of the badge's network.";
    };
    poolStart = lib.mkOption {
      type = lib.types.str;
      default = "10.55.0.100";
      description = "The first address DHCP hands out.";
    };
    poolEnd = lib.mkOption {
      type = lib.types.str;
      default = "10.55.0.200";
      description = "The last address DHCP hands out.";
    };
    dhcp = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Serve DHCP on the badge's network.";
    };
    dns = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Serve DNS on the badge's network.";
    };
    offerGateway = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        On the USB link, hand the badge out as the host's default route (the DHCP router
        option). Off by default: a workstation applying it would route through the badge,
        which does not NAT there. The router offers itself while its uplink is up.
      '';
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = routed -> cfg.enable;
          message = "badge.lan.enable is off, but badge.router serves its LAN through badge.lan.";
        }
      ];
    }
    (lib.mkIf served {
      services.dnsmasq = {
        enable = true;
        resolveLocalQueries = false;
        settings = {
          inherit (cfg) interface;
          # port 0 turns DNS off.
          port = if cfg.dns then 53 else 0;
          # The router's offer of itself follows its uplink, so its leases are short.
          dhcp-range = lib.optionals cfg.dhcp [
            "${cfg.poolStart},${cfg.poolEnd},${if routed then "2m" else "24h"}"
          ];
          dhcp-authoritative = cfg.dhcp;
        }
        // (
          if onUsb then
            {
              bind-interfaces = true;
              # An empty router option unless asked: the badge does not NAT.
              dhcp-option = lib.optionals cfg.dhcp [
                (if cfg.offerGateway then "option:router,${cfg.address}" else "option:router")
              ];
            }
          else
            {
              # The bridge comes and goes with systemd-networkd.
              bind-dynamic = true;
            }
        );
      };

      systemd.services.dnsmasq = lib.mkIf onUsb {
        wantedBy = lib.mkForce [ device ];
        bindsTo = [ device ];
        after = [
          device
          "nix-badge-usb-gadget.service"
        ];
      };

      networking.firewall.interfaces.${cfg.interface} = {
        allowedUDPPorts = lib.optional cfg.dhcp 67 ++ lib.optional cfg.dns 53;
        allowedTCPPorts = lib.optional cfg.dns 53;
      };
    })
  ];
}
