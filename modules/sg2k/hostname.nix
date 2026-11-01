# The hostname: networking.hostName (the board's name unless set), with the fused serial's
# number appended once DEVICE_ID is burned (SG1-0001 gives nix-badge-01).
# nix-badge-hostname writes it at boot.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  config = lib.mkIf config.hardware.sg2k.enable {
    networking.hostName = lib.mkDefault config.hardware.sg2k.board;

    # nix-badge-hostname writes /etc/hostname, so NixOS must not.
    environment.etc.hostname.enable = false;

    # NixOS points hostnamed at the store copy; it has to read the written file.
    systemd.services.systemd-hostnamed.environment.SYSTEMD_ETC_HOSTNAME = lib.mkForce "/etc/hostname";
    systemd.services.nix-badge-hostname = {
      description = "Set the hostname from the fused serial";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-modules-load.service" ];
      before = [
        "systemd-hostnamed.service"
        "network-pre.target"
      ];
      wants = [ "network-pre.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = "${lib.getExe pkgs.nix-badge-hostname} ${lib.escapeShellArg config.networking.hostName}";
    };
  };
}
