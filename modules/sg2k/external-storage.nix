# Data cards (hardware.sg2k.externalStorage). On an eMMC boot stage 0 mounts a data card's
# EXT_USERDATA over the eMMC's USERDATA, read-only underneath (nix-badge-stage0). This side
# points the Nix daemon at the store stage 0 stacked, names the card's partitions, mounts
# its BOOT for deploys, keeps the eMMC's USERDATA writers off while a card is in use, and
# says so at login.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hardware.sg2k;
  inUse = "/.lower-userdata";
in
{
  config = lib.mkIf (cfg.enable && cfg.externalStorage.enable) {
    # Stage 0 looks for a card only when the booted FIT carries this.
    boot.kernelParams = [ "nixbadge.datacard=1" ];

    # /run/nix-badge/store.conf, included by the daemon's NIX_CONFIG (storage.nix), and
    # /run/nix-badge/storage.
    systemd.services.nix-badge-storage-mode = {
      description = "Record the storage mode stage 0 set up";
      wantedBy = [
        "multi-user.target"
        "nix-daemon.service"
      ];
      before = [ "nix-daemon.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe pkgs.nix-badge-storage-mode;
      };
    };

    # An SD's partitions by name on an eMMC boot.
    services.udev.extraRules = ''
      SUBSYSTEM=="block", IMPORT{cmdline}="nixbadge.bootmedium"
      SUBSYSTEM=="block", ENV{nixbadge.bootmedium}=="0", ENV{DEVTYPE}=="partition", ENV{PARTNAME}=="BOOT",         ATTRS{type}=="SD", SYMLINK+="cardboot"
      SUBSYSTEM=="block", ENV{nixbadge.bootmedium}=="0", ENV{DEVTYPE}=="partition", ENV{PARTNAME}=="EXT_USERDATA", ATTRS{type}=="SD", SYMLINK+="carduserdata"
    '';

    # The card's BOOT, where deploys put the FIT in case 3; mounted when it appears.
    systemd.mounts = [
      {
        what = "/dev/cardboot";
        where = "/boot-card";
        type = "vfat";
        options = "noatime,umask=0077";
        wantedBy = [ "dev-cardboot.device" ];
        unitConfig.ConditionPathIsMountPoint = inUse;
      }
    ];

    # When stage 0 reset the card's Nix layer for a slot, that slot's FIT on the card
    # would boot a generation that is gone: drop it once the card's BOOT is mounted.
    systemd.services.nix-badge-card-boot-reset = {
      description = "Drop the data card's boot images for slots whose Nix layer was reset";
      wantedBy = [ "boot\\x2dcard.mount" ];
      after = [ "boot\\x2dcard.mount" ];
      unitConfig.ConditionPathExists = "/.userdata/.nixbadge-card-boot-reset";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe pkgs.nix-badge-card-boot-reset;
      };
    };

    environment.interactiveShellInit = ''
      if [[ -r /run/nix-badge/storage ]]; then
        read -r nb_mode nb_dev < /run/nix-badge/storage
        if [[ $nb_mode == card ]]; then
          echo "Data card in use: writes go to $nb_dev; the eMMC is read-only."
        fi
        unset nb_mode nb_dev
      fi
    '';

    # Nothing grows the eMMC's USERDATA (read-only) or the card's partition table. The
    # swap file stays: /.userdata/swap is on the card.
    systemd.services.growpart.unitConfig.ConditionPathIsMountPoint = "!${inUse}";
    systemd.services."systemd-growfs@\\x2euserdata" = {
      overrideStrategy = "asDropin";
      unitConfig.ConditionPathIsMountPoint = "!${inUse}";
    };
  };
}
