# System settings shared by both cores: identity, network, users, consoles, Nix.
{
  pkgs,
  lib,
  config,
  badgeVersion,
  ...
}:
let
  prettyName = "BadgeOS ${badgeVersion} (NixOS ${config.system.nixos.release})";
in
{
  config = lib.mkIf config.hardware.sg2k.enable {
    # BadgeOS on top of NixOS, whose release, version and revision stay as they are.
    system.nixos = {
      distroName = "BadgeOS";
      distroId = "badgeos";
      vendorName = "Nix Vegas";
      vendorId = "nixvegas";
      # NixOS sets these for itself only.
      extraOSReleaseArgs = {
        PRETTY_NAME = prettyName;
        HOME_URL = "https://nix.vegas/";
        VENDOR_URL = "https://nix.vegas/";
        DOCUMENTATION_URL = "https://badge.nix.vegas/";
        BUG_REPORT_URL = "https://github.com/NixVegas/BadgeOS/issues";
        ANSI_COLOR = "0;38;2;126;186;228";
      };
      extraLSBReleaseArgs.DISTRIB_DESCRIPTION = prettyName;
    };
    system.image = {
      id = "badgeos";
      version = badgeVersion;
    };
    services.getty.greetingLine = "<<< BadgeOS ${badgeVersion} on NixOS ${config.system.nixos.label} (\\m) - \\l >>>";

    networking.networkmanager = {
      enable = true;
      wifi.backend = "wpa_supplicant";
    };
    networking.useDHCP = false;

    # Avoid mixing up ARP between interfaces.
    boot.kernel.sysctl."net.ipv4.conf.all.arp_ignore" = 1;
    boot.kernel.sysctl."net.ipv4.conf.all.arp_announce" = 2;

    # Keys only: a new key goes in over the serial console.
    services.openssh = {
      enable = true;
      settings = {
        PermitRootLogin = "no";
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
      };
    };

    users.users.badge = {
      isNormalUser = true;
      uid = 1000;
      extraGroups = [
        "wheel"
        "dialout"
        "gpio"
        "networkmanager"
      ];
      openssh.authorizedKeys.keys = [ ];
      initialPassword = "nixbadge";
    };

    # For the emergency shell (sulogin) on serial; root still can't ssh.
    users.users.root.initialPassword = "nixbadge";

    security.sudo.wheelNeedsPassword = false;

    users.groups.gpio = { };
    services.udev.extraRules = ''
      SUBSYSTEM=="gpio", KERNEL=="gpiochip*", GROUP="gpio", MODE="0660"
    '';

    nix.settings = {
      extra-experimental-features = [
        "nix-command"
        "flakes"
      ];
      trusted-users = [ "@wheel" ];
      # cache.nixos.lv says priority 50, cache.nixos.org 40; this keeps them in this order.
      substituters = [ "https://cache.nixos.lv?priority=30" ];
      extra-trusted-public-keys = [ (lib.fileContents ../keys/citadel.build.dc.nixos.lv-1.pub) ];
    };

    zramSwap = {
      enable = true;
      algorithm = "zstd";
      memoryPercent = 150;
    };

    # No coredumps. It slows things down.
    systemd.coredump.enable = false;
    boot.kernel.sysctl."kernel.core_pattern" = "/dev/null";

    environment.systemPackages = with pkgs; [
      htop
      tmux
      gitMinimal
      i2c-tools
      usbutils
      libgpiod
      perf
    ];

    # Keep the closure small, this is going on an SD card.
    documentation.enable = lib.mkDefault false;
    documentation.nixos.enable = lib.mkDefault false;

    # Spleen 6x12 on the Sharp panel's console (66x20), set before fbcon binds.
    console = lib.mkIf config.hardware.sg2k.sharpPanel.enable {
      font = "${pkgs.spleen}/share/consolefonts/spleen-6x12.psfu";
      earlySetup = true;
    };

    systemd.services."serial-getty@ttyS0" = {
      enable = true;
      serviceConfig = {
        Restart = "always";
        RestartSec = 0;
      };
    };
    systemd.services."getty@tty1" = lib.mkIf config.hardware.sg2k.sharpPanel.enable {
      enable = true;
    };
    # router.nix shows lan0 and the uplink instead.
    services.getty.helpLine = lib.mkIf (!config.badge.router.enable) (
      lib.mkAfter "\neth0: \\4{eth0}   wlan0: \\4{wlan0}"
    );

    systemd.settings.Manager.RebootWatchdogSec = "20s";
    systemd.settings.Manager.RuntimeWatchdogSec = "0";

    boot.loader.grub.enable = lib.mkForce false;
    boot.initrd.enable = lib.mkForce false;

    system.stateVersion = "26.05";
  };
}
