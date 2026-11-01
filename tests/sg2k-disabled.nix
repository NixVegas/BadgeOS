# Importing the BSP without hardware.sg2k.enable leaves a plain NixOS system: none of its
# services, kernel, device tree, udev rules or kernel parameters. Each failure message
# names its check.
{
  pkgs,
  system,
  mkSystem,
}:
let
  inherit (pkgs) lib;

  sys = mkSystem [
    {
      nixpkgs.hostPlatform = "aarch64-linux";
      nixpkgs.buildPlatform = system;
      boot.loader.grub.enable = false;
      fileSystems."/" = {
        device = "none";
        fsType = "tmpfs";
      };
      system.stateVersion = "26.05";
    }
  ];
  inherit (sys) config;

  ours = name: lib.hasPrefix "nix-badge" name || lib.hasPrefix "soph-" name;

  failures =
    lib.optional (
      !(builtins.tryEval config.system.build.toplevel.drvPath).success
    ) "the toplevel does not evaluate"
    ++ map (n: "service ${n} is defined") (lib.filter ours (lib.attrNames config.systemd.services))
    ++ lib.optional (
      config.boot.kernelPackages.kernel.version != pkgs.linuxPackages.kernel.version
    ) "the kernel is not nixpkgs' default"
    ++ lib.optional (
      config.hardware.deviceTree.name != null
    ) "hardware.deviceTree.name names a board DTB"
    ++ lib.optional (config.services.rauc.enable or false) "RAUC is enabled"
    ++ lib.optional (
      lib.hasInfix "nix-badge" config.services.udev.extraRules
      || lib.hasInfix "sophgo" config.services.udev.extraRules
    ) "the udev rules carry BSP rules"
    ++ lib.optional (lib.any (
      p: lib.hasPrefix "cma=" p || p == "clk_ignore_unused"
    ) config.boot.kernelParams) "the kernel parameters carry BSP parameters"
    ++ map (a: "assertion failed: ${a.message}") (lib.filter (a: !a.assertion) config.assertions)
    ++ map (w: "warning: ${w}") config.warnings;
in
if failures == [ ] then
  pkgs.runCommand "test-sg2k-disabled" { } "touch $out"
else
  throw ("sg2k-disabled:\n  " + lib.concatStringsSep "\n  " failures)
