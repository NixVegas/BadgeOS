# nix-badge-install, and a login hint for it on SD boots, on boards with an eMMC to install
# to. A root service records the board identity eFuses for the hint: the nvmem device is
# root-only.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  nixBadge = pkgs.nix-badge-noeval;
  installer = pkgs.nix-badge-install.override { nix-badge = nixBadge; };
  stateFile = "/run/nix-badge-board-id";
in
{
  config = lib.mkIf (config.hardware.sg2k.enable && config.hardware.sg2k.emmc.enable) {
    environment.systemPackages = [ installer ];

    systemd.services.nix-badge-board-id = {
      description = "Record the board identity eFuses for the login hint";
      wantedBy = [ "multi-user.target" ];
      unitConfig.ConditionKernelCommandLine = "nixbadge.bootmedium=1";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "nix-badge-board-id-record" ''
          ${lib.getExe' nixBadge "nix-badge"} board-id > ${stateFile}.tmp
          ${lib.getExe' pkgs.coreutils "mv"} -f ${stateFile}.tmp ${stateFile}
        '';
      };
    };

    environment.interactiveShellInit = ''
      case " $(< /proc/cmdline) " in
        *' nixbadge.bootmedium=1 '*)
          if [[ -r ${stateFile} && $(< ${stateFile}) == *$'\n'"provisioned: yes"* ]]; then
            echo "Booted from the SD card: run sudo nix-badge-install to install to the eMMC."
          else
            echo "Booted from the SD card: run sudo nix-badge-install to fuse the serial and install to the eMMC."
          fi
          ;;
      esac
    '';
  };
}
