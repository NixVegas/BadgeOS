# The boot medium: GPT + hybrid MBR with BOOT, UBOOT, NIX_A, NIX_B and USERDATA. The root
# is the NIX verity squashfs; stage-0 overlays USERDATA (read-only root, noexec state
# binds) and the daemon runs local-overlay-store.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  emmc = config.hardware.sg2k.emmc.enable;
in
{
  config = lib.mkIf config.hardware.sg2k.enable {
    # U-Boot expands ${...} at boot. The FIT profile line adds init=, rauc.slot=, the boot
    # medium and the factory-reset flag itself.
    boot.kernelParams = [
      "root=/dev/dm-0"
      "rootfstype=squashfs"
      "ro"
      "dm-mod.waitfor=PARTUUID=\${nixroot}"
      "rootwait"
      "systemd.setenv=NIXBADGE_BOOTMEDIUM=\${bootmedium}"
    ];

    # What stage-0 mounted, declared so systemd sees matching, already-active units.
    # Root is the verity squashfs, read-only for good; state lives in noexec binds from
    # USERDATA (symlinks into the store still execute: the check is on the target's fs);
    # /bin and /usr are volatile, activation recreates their two symlinks every boot.
    fileSystems =
      let
        bind = name: {
          device = "/.userdata/${name}";
          fsType = "none";
          neededForBoot = true;
          options = [
            "bind"
            "nosuid"
            "nodev"
            "noexec"
          ];
        };
        volatile = {
          device = "tmpfs";
          fsType = "tmpfs";
          neededForBoot = true;
          options = [
            "mode=0755"
            "nosuid"
            "nodev"
            "noexec"
          ];
        };
      in
      {
        "/" = {
          device = "/dev/dm-0";
          fsType = "squashfs";
          options = [ "ro" ];
        };
        "/.userdata" = {
          # The booted medium's own USERDATA (udev handle below); by-partlabel is
          # ambiguous once the eMMC has one too.
          device = "/dev/userdata";
          fsType = "ext4";
          neededForBoot = true;
          options = [
            "noatime"
            "nosuid"
            "nodev"
            "x-systemd.growfs"
            "x-systemd.device-timeout=10min"
          ];
        };
        "/etc" = bind "etc";
        "/var" = bind "var";
        "/tmp" = bind "tmp";
        "/home" = bind "home";
        "/root" = bind "root";
        "/nix/var" = (bind "nix/var") // {
          options = [
            "bind"
            "nosuid"
            "nodev"
          ];
        }; # exec: Nix's default build dir is /nix/var/nix/builds
        "/bin" = volatile;
        "/usr" = volatile;
        "/lib" = volatile; # /lib: tmpfiles' stub-ld link
        "/boot" = {
          device = "/dev/boot"; # the booted medium's BOOT (udev handle)
          fsType = "vfat";
          options = [
            "nofail"
            "umask=0077"
            "x-systemd.device-timeout=10min"
          ];
        };
      };
    # /run and /dev/shm are stage 2's tmpfs mounts (boot.specialFileSystems); noexec too.
    # /run/wrappers and /run/user/* are separate mounts with their own options, and
    # /run/current-system is a symlink into the store, so nothing legitimate runs from /run.
    boot.specialFileSystems."/run".options = [ "noexec" ];
    boot.specialFileSystems."/dev/shm".options = [ "noexec" ];

    # Swap on USERDATA, made after the first-boot grow so fallocate has room. The size is
    # nix-badge-userdata-swap's (256 MiB on the eMMC's own USERDATA, 512 MiB on an SD
    # card's); this one only makes NixOS generate the unit.
    swapDevices = [
      {
        device = "/.userdata/swap";
        size = 512;
      }
    ];
    systemd.services."mkswap-x2euserdata-swap" = {
      after = [
        "growpart.service"
        "systemd-growfs@\\x2euserdata.service"
      ];
      wants = [
        "growpart.service"
        "systemd-growfs@\\x2euserdata.service"
      ];
      serviceConfig.ExecStart = lib.mkForce (lib.getExe pkgs.nix-badge-userdata-swap);
    };

    # Grows USERDATA once (the stock growpart would target the squashfs root). Same unit
    # shape as nixos/modules/system/boot/grow-partition.nix, retargeted at /.userdata.
    systemd.services.growpart = {
      description = "Grow USERDATA to the end of the card (once)";
      wantedBy = [ "local-fs.target" ];
      after = [ "\\x2euserdata.mount" ];
      before = [
        "systemd-growfs@\\x2euserdata.service"
        "shutdown.target"
      ];
      conflicts = [ "shutdown.target" ];
      unitConfig = {
        DefaultDependencies = false;
        ConditionPathExists = "!/var/lib/nix-badge/growpart.done";
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe pkgs.nix-badge-grow-userdata;
      };
    };

    # stage 2 tries `mount -o remount,rw /` (initrd-less path; no errexit, so the
    # squashfs refusing it is one log line). This guarantees / is read-only at the end
    # of every activation, including on-device switches, whatever the root is.
    system.activationScripts.nix-badge-ro-root = lib.stringAfter [ "binsh" "usrbinenv" "etc" ] ''
      ${pkgs.util-linux}/bin/mount -o remount,ro / 2>/dev/null || true
    '';

    # The daemon serves the overlay store: lower = the squashfs (rooted, read-only),
    # upper = the userdata layer stage-0 mounted. check-mount compares with mountinfo.
    # Every client goes through the daemon (a non-root one cannot open the root-owned
    # store), and only nix-daemon gets the overlay URL, through its NIX_CONFIG.
    nix.settings = {
      store = "daemon";
      experimental-features = [
        "local-overlay-store"
        "read-only-local-store"
      ];
    };
    # systemd expands % specifiers in Environment=, and an unresolvable one silently
    # drops the whole assignment. With data cards, nix-badge-storage-mode writes the store
    # line for what stage 0 mounted (external-storage.nix); a missing file leaves this one.
    systemd.services.nix-daemon.environment.NIX_CONFIG = lib.replaceStrings [ "%" ] [ "%%" ] (
      "store = local-overlay://?lower-store=local%3Froot%3D%2Fnix%2F.ro-store%26read-only%3Dtrue&upper-layer=/.userdata/nix/upper"
      + lib.optionalString config.hardware.sg2k.externalStorage.enable "\n!include /run/nix-badge/store.conf"
    );

    # Static handles by role + medium (0 = eMMC, 1 = SD) and unsuffixed "mine" links
    # driven by the cmdline parameter; force_ro cleared on the eMMC boot areas.
    # services.udev.extraRules lands in 99-local.rules, which sorts before systemd's
    # 99-systemd.rules, so these SYMLINKs are in DEVLINKS by the time systemd tags the
    # device: /dev/userdata and /dev/boot become device-unit aliases the fileSystems
    # above bind to.
    services.udev.extraRules =
      lib.optionalString emmc ''
        SUBSYSTEM=="block", KERNEL=="mmcblk[0-9]boot0", ATTRS{type}=="MMC", ATTR{force_ro}="0", SYMLINK+="fip"
        SUBSYSTEM=="block", KERNEL=="mmcblk[0-9]boot1", ATTRS{type}=="MMC", ATTR{force_ro}="0", SYMLINK+="uboot0"
        SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", ENV{PARTNAME}=="BOOT",     ATTRS{type}=="MMC", SYMLINK+="boot0"
        SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", ENV{PARTNAME}=="NIX_A",    ATTRS{type}=="MMC", SYMLINK+="nixA0"
        SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", ENV{PARTNAME}=="NIX_B",    ATTRS{type}=="MMC", SYMLINK+="nixB0"
        SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", ENV{PARTNAME}=="USERDATA", ATTRS{type}=="MMC", SYMLINK+="userdata0"
      ''
      + ''
        SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", ENV{PARTNAME}=="BOOT",     ATTRS{type}=="SD",  SYMLINK+="boot1"
        SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", ENV{PARTNAME}=="UBOOT",    ATTRS{type}=="SD",  SYMLINK+="uboot1"
        SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", ENV{PARTNAME}=="NIX_A",    ATTRS{type}=="SD",  SYMLINK+="nixA1"
        SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", ENV{PARTNAME}=="NIX_B",    ATTRS{type}=="SD",  SYMLINK+="nixB1"
        SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", ENV{PARTNAME}=="USERDATA", ATTRS{type}=="SD",  SYMLINK+="userdata1"
        SUBSYSTEM=="block", IMPORT{cmdline}="nixbadge.bootmedium"
      ''
      + lib.optionalString emmc ''
        SUBSYSTEM=="block", ENV{nixbadge.bootmedium}=="0", KERNEL=="mmcblk[0-9]boot1", ATTRS{type}=="MMC", SYMLINK+="uboot"
        SUBSYSTEM=="block", ENV{nixbadge.bootmedium}=="0", ENV{PARTNAME}=="BOOT",     ATTRS{type}=="MMC", SYMLINK+="boot"
        SUBSYSTEM=="block", ENV{nixbadge.bootmedium}=="0", ENV{PARTNAME}=="NIX_A",    ATTRS{type}=="MMC", SYMLINK+="nixA"
        SUBSYSTEM=="block", ENV{nixbadge.bootmedium}=="0", ENV{PARTNAME}=="NIX_B",    ATTRS{type}=="MMC", SYMLINK+="nixB"
        SUBSYSTEM=="block", ENV{nixbadge.bootmedium}=="0", ENV{PARTNAME}=="USERDATA", ATTRS{type}=="MMC", SYMLINK+="userdata"
      ''
      + ''
        SUBSYSTEM=="block", ENV{nixbadge.bootmedium}=="1", ENV{PARTNAME}=="UBOOT",    ATTRS{type}=="SD",  SYMLINK+="uboot"
        SUBSYSTEM=="block", ENV{nixbadge.bootmedium}=="1", ENV{PARTNAME}=="BOOT",     ATTRS{type}=="SD",  SYMLINK+="boot"
        SUBSYSTEM=="block", ENV{nixbadge.bootmedium}=="1", ENV{PARTNAME}=="NIX_A",    ATTRS{type}=="SD",  SYMLINK+="nixA"
        SUBSYSTEM=="block", ENV{nixbadge.bootmedium}=="1", ENV{PARTNAME}=="NIX_B",    ATTRS{type}=="SD",  SYMLINK+="nixB"
        SUBSYSTEM=="block", ENV{nixbadge.bootmedium}=="1", ENV{PARTNAME}=="USERDATA", ATTRS{type}=="SD",  SYMLINK+="userdata"
      '';
  };
}
