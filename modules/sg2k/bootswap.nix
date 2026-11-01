# Holding BOOT for 3 s latches the other core and reboots (with the board's core
# switch on AUTO).
{
  lib,
  pkgs,
  config,
  ...
}:
let
  nixBadge = pkgs.nix-badge-noeval;
in
{
  config = lib.mkIf (config.hardware.sg2k.enable && config.hardware.sg2k.coreSelect.enable) {
    systemd.services.nix-badge-bootswap = {
      description = "nix-badge boot-core swap on BOOT-button hold";
      wantedBy = [ "multi-user.target" ];
      # systemctl, for a clean reboot.
      path = [ config.systemd.package ];
      serviceConfig = {
        ExecStart = "${nixBadge}/bin/nix-badge bootswap";
        Restart = "on-failure";
        RestartSec = 2;
      };
    };
  };
}
