# Netboot on the router's LAN: a PXE ROM gets iPXE over TFTP for its firmware, iPXE gets
# the menu over HTTP, and the menu boots the Nix Vegas installer. nginx serves the netboot
# tree under /boot and this manual at /.
{
  config,
  lib,
  pkgs,
  # The flake's: the installer the badge serves, and the manual built for /.
  badgeNetboot,
  badgeManual,
  ...
}:
let
  cfg = config.badge.ipxe;
  inherit (config.badge.lan) address interface;
  root = pkgs.nix-badge-netboot-root { inherit (cfg) netboot banner badapple; };
in
{
  options.badge.ipxe = {
    enable = lib.mkEnableOption "netbooting the Nix Vegas installer from the badge" // {
      default = config.badge.router.enable;
      defaultText = lib.literalExpression "config.badge.router.enable";
    };

    netboot = lib.mkOption {
      type = lib.types.package;
      default = badgeNetboot;
      defaultText = lib.literalMD "the Nix Vegas installer, built for x86_64-linux";
      description = ''
        What is netbooted: a directory with bzImage, initrd and netboot.ipxe, which loads
        them by relative path, and the x86_64 iPXE binaries ipxe.efi and undionly.kpxe.
      '';
    };

    banner = lib.mkOption {
      type = lib.types.path;
      default = ../installer/motd.txt;
      defaultText = lib.literalExpression "../installer/motd.txt";
      description = "The text iPXE shows before the menu.";
    };

    badapple = lib.mkOption {
      type = lib.types.package;
      default = pkgs.nix-badge-netboot-badapple;
      defaultText = lib.literalExpression "pkgs.nix-badge-netboot-badapple";
      description = "The iPXE script the menu offers to play before booting.";
    };

    manual = lib.mkOption {
      type = lib.types.package;
      default = badgeManual;
      defaultText = lib.literalMD "this manual, built to be served at /";
      description = "The site nginx serves at /.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.badge.router.enable;
        message = "badge.ipxe needs badge.router: it serves the router's LAN.";
      }
    ];

    services.dnsmasq.settings = {
      enable-tftp = true;
      tftp-root = "${root}/tftp,${interface}";
      dhcp-match = [
        # iPXE says so with its own options.
        "set:ipxe,175"
        "set:efi64,option:client-arch,7"
        "set:efi64,option:client-arch,8"
        "set:efi64,option:client-arch,9"
        "set:bios,option:client-arch,0"
      ];
      dhcp-userclass = "set:ipxe,iPXE";
      dhcp-vendorclass = "set:httpclient,HTTPClient";
      dhcp-boot = [
        "tag:bios,tag:!ipxe,undionly.kpxe"
        "tag:efi64,tag:!ipxe,ipxe.efi"
        "tag:httpclient,tag:!ipxe,http://${address}/boot/ipxe.efi"
        "tag:ipxe,http://${address}/boot/menu.ipxe"
      ];
      # UEFI HTTP boot takes only an offer that names it.
      dhcp-option-force = [ "tag:httpclient,60,HTTPClient" ];
    };

    services.nginx = {
      enable = true;
      recommendedOptimisation = true;
      virtualHosts.badge = {
        default = true;
        root = cfg.manual;
        locations."/boot/".alias = "${root}/boot/";
      };
    };

    networking.firewall.interfaces.${interface} = {
      allowedUDPPorts = [ 69 ];
      allowedTCPPorts = [ 80 ];
    };
  };
}
