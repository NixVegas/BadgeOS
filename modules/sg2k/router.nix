# The badge as a router: the wired ports that aren't the uplink are bridged as the badge's
# network (badge.lan, lan0), which is NATed out of the uplink. The badge offers itself as
# gateway and DNS server only while the uplink has a default route.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.badge.router;
  lan = config.badge.lan;
  bridge = lan.interface;

  uplink = cfg.interfaces.${cfg.upstream};
  ports =
    lib.filter (p: p != cfg.upstream && (p != "usb" || config.hardware.sg2k.usb.gadget.enable))
      [
        "ethernet"
        "usb"
      ];
  portIfs = map (p: cfg.interfaces.${p}) ports;

  optsFile = "/run/nix-badge/router/dhcp-opts";
  gateway = "${lib.getExe pkgs.nix-badge-router-gateway} ${uplink} ${lan.address} ${optsFile}";
  dispatch = pkgs.writeShellScript "nix-badge-router-dispatch" ''
    ROUTER_GATEWAY_SYSTEMCTL=${config.systemd.package}/bin/systemctl exec ${lib.getExe pkgs.nix-badge-router-gateway} --reload ${uplink} ${lan.address} ${optsFile}
  '';

  hasPort = {
    wifi = config.hardware.sg2k.wifi.enable;
    ethernet = config.hardware.sg2k.ethernet.enable;
    usb = config.hardware.sg2k.usb.gadget.enable;
  };

  interfaceOption =
    name: default:
    lib.mkOption {
      type = lib.types.str;
      inherit default;
      description = "The ${name} interface. For tests and other boards.";
    };
in
{
  options.badge.router = {
    enable = lib.mkEnableOption "the badge as a router for whatever is on its wired ports";

    upstream = lib.mkOption {
      type = lib.types.enum [
        "wifi"
        "ethernet"
        "usb"
      ];
      default = "wifi";
      description = ''
        The uplink: the port the badge takes its default route from and NATs out of. The
        other wired ports are bridged as the badge's own network, lan0.
      '';
    };

    interfaces = {
      wifi = interfaceOption "WiFi" "wlan0";
      ethernet = interfaceOption "Ethernet" "eth0";
      usb = interfaceOption "USB network" "usb0";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = lib.optional config.hardware.sg2k.enable {
      assertion = hasPort.${cfg.upstream};
      message = "badge.router.upstream is \"${cfg.upstream}\", but this configuration has no ${cfg.upstream} port.";
    };

    # The bridge and its ports belong to systemd-networkd, so the badge's own network comes
    # up without NetworkManager or D-Bus, and a re-plugged port rejoins it; NetworkManager
    # keeps the uplink.
    systemd.network = {
      enable = true;
      wait-online.enable = false;
      netdevs."40-${bridge}" = {
        netdevConfig = {
          Name = bridge;
          Kind = "bridge";
        };
        # A PXE ROM gives up long before STP would forward.
        bridgeConfig.STP = false;
      };
      networks."40-${bridge}" = {
        matchConfig.Name = bridge;
        address = [ "${lan.address}/${toString lan.prefixLength}" ];
        networkConfig = {
          ConfigureWithoutCarrier = true;
          LinkLocalAddressing = "no";
          IPv6AcceptRA = false;
        };
        linkConfig.RequiredForOnline = "no";
      };
      # An empty Name= would match every link.
      networks."41-${bridge}-ports" = lib.mkIf (portIfs != [ ]) {
        matchConfig.Name = lib.concatStringsSep " " portIfs;
        networkConfig.Bridge = bridge;
        linkConfig.RequiredForOnline = "no";
      };
    };
    # networkd brings systemd-resolved by default; NetworkManager keeps resolv.conf.
    services.resolved.enable = lib.mkOverride 900 false;

    networking.networkmanager = {
      enable = true;
      unmanaged = map (i: "interface-name:${i}") ([ bridge ] ++ portIfs);
      # NetworkManager's own udev rule leaves gadget devices unmanaged.
      settings = lib.mkIf (cfg.upstream == "usb") {
        "device-badge-usb" = {
          match-device = "interface-name:${cfg.interfaces.usb}";
          managed = 1;
        };
      };
    };
    # A link into the store: dispatcherScripts copies scripts into /etc, which is noexec
    # on the badge.
    environment.etc."NetworkManager/dispatcher.d/50-nix-badge-router".source = dispatch;

    # lan.nix serves DHCP and DNS on the bridge; whether it offers the badge as gateway
    # comes from this file. The dispatcher keeps it current; preStart covers events from
    # before dnsmasq ran.
    services.dnsmasq.settings.dhcp-optsfile = lib.mkIf config.services.dnsmasq.enable optsFile;
    systemd.services.dnsmasq = lib.mkIf config.services.dnsmasq.enable {
      preStart = lib.mkAfter gateway;
    };
    systemd.tmpfiles.rules = [ "d /run/nix-badge/router 0755 root root -" ];

    networking.nftables.enable = true;
    networking.firewall.filterForward = true;
    networking.nat = {
      enable = true;
      internalInterfaces = [ bridge ];
      externalInterface = uplink;
    };

    # The login prompt shows the bridge's and the uplink's addresses.
    services.getty.helpLine = lib.mkIf config.hardware.sg2k.enable (
      lib.mkAfter "\n${bridge}: \\4{${bridge}}   ${uplink}: \\4{${uplink}}"
    );
  };
}
