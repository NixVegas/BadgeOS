# RAUC A/B updates.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Without an eMMC the SD's slots are RAUC's own (medium suffix 1, see storage.nix) and
  # it boots without rauc.external.
  emmc = config.hardware.sg2k.emmc.enable;
  medium = if emmc then "0" else "1";
  keyring = pkgs.nix-badge-rauc-dev-keyring;
  envMirror = pkgs.nix-badge-env-mirror;
  postInstallHandler = pkgs.writeShellScript "nix-badge-rauc-post-install" ''
    ${lib.getExe envMirror} || echo "nix-badge: env mirror failed after the install" >&2
    exit 0
  '';
  # rauc-mark-good skips SD boots (rauc.external); this re-arms the SD's own attempt
  # counter instead.
  markGoodSd = pkgs.writeShellApplication {
    name = "nix-badge-mark-good-sd";
    runtimeInputs = [
      pkgs.ubootTools
      pkgs.coreutils
      pkgs.gnused
    ];
    text = ''
      slot=$(tr ' ' '\n' < /proc/cmdline | sed -n 's/^rauc\.slot=//p' | head -1)
      case "$slot" in
        A|B) ;;
        *) echo "nix-badge-mark-good-sd: no usable rauc.slot= on the command line ('$slot'); nothing to mark"; exit 0 ;;
      esac
      cur=$(fw_printenv -c /etc/fw_env-sd.config -n "BOOT_''${slot}_LEFT" 2>/dev/null || true)
      if [ "$cur" = 3 ]; then
        echo "nix-badge-mark-good-sd: SD slot $slot already has BOOT_''${slot}_LEFT=3"
        exit 0
      fi
      fw_setenv -c /etc/fw_env-sd.config "BOOT_''${slot}_LEFT" 3
      echo "nix-badge-mark-good-sd: SD boot of slot $slot is good: BOOT_''${slot}_LEFT ''${cur:-unset} reset to 3"
    '';
  };
in
{
  options.hardware.sg2k.rauc = {
    compatible = lib.mkOption {
      type = lib.types.str;
      default = "sg2k/${config.hardware.sg2k.board}";
      defaultText = lib.literalExpression ''"sg2k/''${config.hardware.sg2k.board}"'';
      description = "RAUC's compatible string. The system refuses bundles built for another one.";
    };

    trustDevKeyring = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Trust the development RAUC key when hardware.sg2k.fitKeyCert is null. Its
        private half is committed to the repository, so anyone can sign bundles this
        system accepts. For test systems only.
      '';
    };
  };

  config = lib.mkIf config.hardware.sg2k.enable {
    assertions = [
      {
        assertion = config.hardware.sg2k.fitKeyCert != null || config.hardware.sg2k.rauc.trustDevKeyring;
        message = "RAUC needs a key to trust: set hardware.sg2k.fitKeyCert, or hardware.sg2k.rauc.trustDevKeyring for a test system";
      }
    ];

    services.rauc = {
      enable = true;
      client.enable = true; # installs RAUC's D-Bus policy; rauc.service needs it
      mark-good.enable = true;
      compatible = config.hardware.sg2k.rauc.compatible;
      bootloader = "uboot";
      dataDir = "/var/lib/rauc"; # /var is a USERDATA bind: survives updates
      slots = {
        fip = lib.mkIf emmc [
          {
            enable = true;
            device = "/dev/fip";
            type = "raw";
          }
        ];
        # Booted from this medium, this is the mounted /boot, which the install hook
        # writes in place; RAUC's mount check only misses that by comparing device names
        # literally.
        boot = [
          {
            enable = true;
            device = "/dev/boot${medium}";
            type = "vfat";
            settings.allow-mounted = true;
          }
        ];
        nix = [
          {
            enable = true;
            device = "/dev/nixA${medium}";
            type = "raw";
            settings.bootname = "A";
          }
          {
            enable = true;
            device = "/dev/nixB${medium}";
            type = "raw";
            settings.bootname = "B";
          }
        ];
      };
      settings.handlers.post-install = lib.mkIf emmc "${postInstallHandler}";
      # With a data card in use the eMMC is read-only to this system.
      settings.handlers.pre-install = lib.mkIf config.hardware.sg2k.externalStorage.enable (
        lib.getExe pkgs.nix-badge-rauc-pre-install
      );
      settings.keyring = {
        # Bundles are signed with the fitKeyCert key; the dev keyring only on request.
        path =
          if config.hardware.sg2k.fitKeyCert != null then
            "${config.hardware.sg2k.fitKeyCert}"
          else
            "${keyring}/cert.pem";
        use-bundle-signing-time = true;
        check-purpose = "codesign";
      };
    };
    systemd.services.rauc-mark-good.unitConfig.ConditionKernelCommandLine = [
      "|rauc.slot"
      "!rauc.external"
    ];
    systemd.services.nix-badge-mark-good-sd = lib.mkIf emmc {
      description = "Reset the boot attempt counter";
      after = [ "multi-user.target" ];
      wantedBy = [ "multi-user.target" ];
      unitConfig.ConditionKernelCommandLine = "rauc.external";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe markGoodSd;
      };
    };
    # RAUC's uboot backend shells out to fw_printenv/fw_setenv
    systemd.services.rauc.path = [
      pkgs.ubootTools
    ]
    ++ lib.optional emmc envMirror
    ++ [
      pkgs.gnutar
      pkgs.util-linux
    ];
    systemd.services.rauc-mark-good.path = [ pkgs.ubootTools ];
    systemd.services.nix-badge-env-mirror = lib.mkIf emmc {
      description = "Mirror the eMMC U-Boot env";
      after = [
        "rauc-mark-good.service"
        "multi-user.target"
      ];
      wants = [ "rauc-mark-good.service" ];
      wantedBy = [ "multi-user.target" ];
      unitConfig.ConditionPathExists = "/dev/uboot0";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe envMirror;
      };
    };

    environment.systemPackages =
      lib.optionals emmc [
        envMirror
        pkgs.nix-badge-emmc-init
      ]
      # fw_printenv and fw_setenv, on the env below.
      ++ [ pkgs.ubootTools ];

    # fw_env.config is the env RAUC manages: the eMMC's (boot area 2) when there is one,
    # else the SD's UBOOT partition. Beside an eMMC, fw_env-sd.config is the SD's, for
    # nix-badge-mark-good-sd.
    environment.etc."fw_env.config".text =
      let
        dev = "/dev/uboot${if emmc then "0" else "1"}";
      in
      ''
        ${dev} 0x0 0x20000 0x20000
        ${dev} 0x20000 0x20000 0x20000
      '';
    environment.etc."fw_env-sd.config" = lib.mkIf emmc {
      text = ''
        /dev/uboot1 0x0 0x20000 0x20000
        /dev/uboot1 0x20000 0x20000 0x20000
      '';
    };
  };
}
