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
  cfg = config.hardware.sg2k;
  software = cfg.coreSelect.backend == "software";
  helper = pkgs.nix-badge-core-reboot.override { firmware = cfg.firmware.activeFipFile; };
in
{
  config = lib.mkIf (config.hardware.sg2k.enable && config.hardware.sg2k.coreSelect.enable) {
    systemd.services.nix-badge-bootswap = lib.mkIf (cfg.coreSelect.backend == "latch") {
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

    # The software backend: a request file on the SD's BOOT for the firmware, then a reboot.
    assertions = lib.mkIf software [
      {
        assertion = lib.elem "arm" cfg.cores && lib.elem "riscv" cfg.cores;
        message = "hardware.sg2k.coreSelect.backend \"software\" needs both core payloads in hardware.sg2k.cores";
      }
      {
        assertion = !cfg.firmware.secureBoot;
        message = "hardware.sg2k.coreSelect.backend \"software\" needs unsigned boot firmware";
      }
      {
        assertion = cfg.firmware.fipPath == "/boot/fip.bin";
        message = "hardware.sg2k.coreSelect.backend \"software\" needs the SD firmware at /boot/fip.bin in hardware.sg2k.firmware.fipPath";
      }
    ];
    environment.systemPackages = lib.mkIf software [ helper ];
    systemd.services."badge-core-reboot@" = lib.mkIf software {
      description = "Reboot into the selected CPU core";
      unitConfig.RequiresMountsFor = [ "/boot" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe helper} reboot %i";
        TimeoutStartSec = 25;
        UMask = "0077";
      };
    };
  };
}
