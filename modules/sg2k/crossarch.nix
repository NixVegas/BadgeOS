# binfmt_misc for the other core's architecture, so deploy-rs can activate that core's
# system (activation runs the target system's own binaries).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  otherCore =
    lib.optional pkgs.stdenv.hostPlatform.isAarch64 "riscv64-linux"
    ++ lib.optional pkgs.stdenv.hostPlatform.isRiscV64 "aarch64-linux";

  # qemu-user for the one target, without ~33 unused emulators (338 MiB).
  emulatorFor =
    target: qemuArch:
    "${pkgs.qemu-user.override { hostCpuTargets = [ target ]; }}/bin/qemu-${qemuArch}";
in
{
  config = lib.mkIf (config.hardware.sg2k.enable && lib.length config.hardware.sg2k.cores > 1) {
    boot.binfmt.emulatedSystems = otherCore;

    # The static qemu segfaults at startup (static-PIE self-relocation).
    boot.binfmt.preferStaticEmulators = false;

    # Builds belong on the dev host, not under qemu here.
    boot.binfmt.addEmulatedSystemsToNixSandbox = false;

    # Overrides the module's mkDefault, so its all-targets qemu is never built.
    boot.binfmt.registrations = lib.mkMerge [
      (lib.mkIf pkgs.stdenv.hostPlatform.isAarch64 {
        "riscv64-linux".interpreter = emulatorFor "riscv64-linux-user" "riscv64";
      })
      (lib.mkIf pkgs.stdenv.hostPlatform.isRiscV64 {
        "aarch64-linux".interpreter = emulatorFor "aarch64-linux-user" "aarch64";
      })
    ];
  };
}
