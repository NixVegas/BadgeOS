# Selected explicitly by duo-s-riscv-pinstripe-<builder>; ordinary images omit it.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  kernel = config.boot.kernelPackages.kernel;
  driver = import ../../pkgs/video/sophgo-dsi { inherit pkgs kernel; };
in
{
  assertions = [
    {
      assertion = pkgs.stdenv.hostPlatform.system == "riscv64-linux";
      message = "The display test image is RISC-V only.";
    }
  ];
  hardware.deviceTree.package = lib.mkOverride 40 (
    import ../../pkgs/firmware/duos-riscv-dtb.nix {
      inherit pkgs kernel;
      pinstripe = true;
    }
  );
  boot.kernelPatches = lib.mkMerge [
    (lib.mkBefore [
      {
        name = "sg2000-display";
        patch = ../../pkgs/kernel/patches/sg2000-display.patch;
      }
    ])
    [
      {
        name = "sg2000-display-config";
        patch = null;
        structuredExtraConfig = with lib.kernel; {
          DRM = lib.mkForce yes;
          DRM_MIPI_DSI = lib.mkForce yes;
          DRM_LONTIUM_LT8912B = lib.mkForce module;
          DRM_DISPLAY_CONNECTOR = lib.mkForce module;
          REGULATOR_FIXED_VOLTAGE = lib.mkForce yes;
        };
      }
    ]
  ];
  # A pipeline held after a failed stop must not turn into a timed reboot.
  systemd.settings.Manager.RuntimeWatchdogSec = lib.mkForce "0";
  systemd.settings.Manager.RebootWatchdogSec = lib.mkForce "0";
  boot.kernelParams = lib.mkAfter [ "panic=0" ];
  boot.extraModulePackages = [ driver ];
  # The host binds idle; nothing touches the display until a manual start.
  boot.kernelModules = [ "sophgo-dsi" ];
  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "mainline-pinstripe";
      runtimeInputs = [ pkgs.coreutils ];
      text = builtins.readFile ../../tools/display/mainline-pinstripe.sh;
    })
  ];
  system.build.pinstripeDriver = driver;
}
