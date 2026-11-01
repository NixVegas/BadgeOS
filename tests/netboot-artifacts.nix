# The installer the badge netboots: the slimmed Nix Vegas configuration (WiFi and GPU
# firmware only, the badge as its first substituter), and the served directory, whose
# closure must not hold the installer system or the nixpkgs source.
{
  pkgs,
  netbootSystem,
  nixpkgsSource,
}:
let
  inherit (pkgs) lib;
  cfg = netbootSystem.config;
  netboot = cfg.system.build.badgeNetboot;
  toplevel = builtins.unsafeDiscardStringContext cfg.system.build.toplevel.outPath;
  defaults = cfg.environment.etc."nixos/nix-vegas-defaults.nix".text;
  citadelKey = "citadel.build.dc.nixos.lv-1:UZbkvFcWZr/VP7cvNPLRpcMTCvaYw7X5XQDzA+nPVxY=";
  closure = pkgs.closureInfo { rootPaths = [ netboot ]; };

  failures =
    lib.optional (cfg.nixpkgs.flake.source != null) "the installer carries the nixpkgs source"
    ++ lib.optional cfg.system.installer.channel.enable "the installer has a channel"
    ++ lib.optional cfg.networking.modemmanager.enable "ModemManager is on"
    ++ lib.optional (
      cfg.hardware.enableAllFirmware || cfg.hardware.enableRedistributableFirmware
    ) "all firmware is in"
    ++ lib.optional (cfg.nixpkgs.hostPlatform.system != "x86_64-linux") "not x86_64-linux"
    ++ lib.optional (
      !lib.hasInfix "ESCAPE YOUR FATE" (builtins.readFile cfg.users.motdFile)
    ) "not the Nix Vegas motd"
    ++ lib.optional (
      !(cfg.environment.etc ? "nixos/flake.nix" && cfg.environment.etc ? "nixos/flake.lock")
    ) "no /etc/nixos flake"
    # The flake's ./configuration.nix is the one nixos-generate-config writes on the laptop.
    ++ lib.optional (builtins.pathExists ../modules/installer/configuration.nix) "the installer has a configuration.nix stub"
    ++ lib.optional (
      cfg.nix.settings.substituters != [
        "http://10.55.0.1"
        "https://cache.nixos.org/"
      ]
    ) "not the badge, then the default substituters (${toString cfg.nix.settings.substituters})"
    ++ lib.optional (
      !lib.elem citadelKey (cfg.nix.settings.extra-trusted-public-keys or [ ])
    ) "citadel's key isn't trusted"
    ++ lib.optional (lib.hasInfix "10.55.0.1" defaults) "/etc/nixos/nix-vegas-defaults.nix names the badge"
    ++ lib.optional (
      !lib.hasInfix citadelKey defaults
    ) "/etc/nixos/nix-vegas-defaults.nix doesn't trust citadel's key";
in
if failures != [ ] then
  throw ("netboot-artifacts:\n  " + lib.concatStringsSep "\n  " failures)
else
  pkgs.runCommand "netboot-artifacts" { } ''
    fail() { echo "FAIL: $*"; exit 1; }
    d=${netboot}
    for f in bzImage initrd netboot.ipxe ipxe.efi undionly.kpxe; do [ -e "$d/$f" ] || fail "no $f"; done
    for f in netboot.ipxe ipxe.efi undionly.kpxe; do [ -f "$d/$f" ] && [ ! -L "$d/$f" ] || fail "$f is not a regular file"; done
    grep -Eqx 'kernel bzImage init=/nix/store/[a-z0-9]{32}-nixos-system-nixvegas-[^ ]+/init initrd=initrd .*console=ttyS0,115200n8.* \$\{cmdline\}' $d/netboot.ipxe || fail "kernel line"
    grep -qx 'initrd initrd' $d/netboot.ipxe && grep -qx boot $d/netboot.ipxe || fail "initrd/boot lines"
    ! grep -qF '${toplevel}' ${closure}/store-paths || fail "the installer system is in the closure"
    ! grep -qF '${builtins.unsafeDiscardStringContext nixpkgsSource}' ${closure}/store-paths || fail "the nixpkgs source is in the closure"
    [ "$(stat -L -c %s $d/initrd)" -le $((800 * 1048576)) ] || fail "initrd is over 800 MiB"
    # WiFi and GPU firmware, so a laptop gets a network and a screen; NVIDIA's (100 MiB
    # compressed) doesn't fit the badge's store slot
    fw=${cfg.system.build.toplevel}/firmware
    for f in intel/iwlwifi i915 xe amdgpu radeon; do [ -e "$fw/$f" ] || fail "no $f firmware"; done
    [ ! -e "$fw/nvidia" ] || fail "NVIDIA firmware is in"
    touch $out
  ''
