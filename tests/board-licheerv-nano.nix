# A LicheeRV Nano system, for either core: SD-only RAUC, the polyglot fip with this
# core's own fip for recovery, and none of the badge's peripherals or profiles.
# passthru.toplevel builds it; passthru.kernel is its kernel's drvPath.
{
  pkgs,
  # nixosConfigurations.licheerv-nano-<core>-*
  sys,
}:
let
  inherit (pkgs) lib;
  inherit (sys) config;
  inherit (config.hardware.sg2k) core;
  fips = sys.pkgs.buildPackages.sg2k-fips-licheerv-nano;
  otherSystem = if core == "arm" then "riscv64-linux" else "aarch64-linux";
  rauc = config.services.rauc;
  has = lib.hasInfix;
  panel =
    (sys.extendModules {
      modules = [ { hardware.sg2k.dsiPanel.enable = true; } ];
    }).config;

  failures =
    lib.optional (
      config.networking.hostName != "licheerv-nano"
    ) "the hostname is ${config.networking.hostName}"
    ++ lib.optional (
      config.hardware.deviceTree.name != "sophgo/sg2002-licheerv-nano.dtb"
    ) "the device tree is ${toString config.hardware.deviceTree.name}"
    ++ lib.optional (
      rauc.compatible != "sg2k/licheerv-nano"
    ) "the RAUC compatible is ${rauc.compatible}"
    ++ lib.optional (
      map (s: s.device) (rauc.slots.boot ++ rauc.slots.nix) != [
        "/dev/boot1"
        "/dev/nixA1"
        "/dev/nixB1"
      ]
    ) "the RAUC slots are not the SD's"
    ++ lib.optional (rauc.slots ? fip) "RAUC has a fip slot"
    ++ lib.optional (
      config.specialisation != { }
    ) "specialisations: ${toString (lib.attrNames config.specialisation)}"
    ++ lib.optional config.hardware.bluetooth.enable "Bluetooth is enabled"
    ++ lib.optional config.badge.router.enable "the router is on"
    ++ lib.optional (
      config.boot.binfmt.emulatedSystems != [ otherSystem ]
    ) "binfmt emulates ${toString config.boot.binfmt.emulatedSystems}, not ${otherSystem}"
    ++ map (n: "service ${n} is defined") (
      lib.filter (n: config.systemd.services ? ${n}) [
        "nix-badge-bling"
        "nix-badge-oled"
        "nix-badge-content"
        "nix-badge-bootswap"
        "soph-display-load"
        "nix-badge-env-mirror"
        "nix-badge-board-id"
      ]
    )
    ++ lib.optional config.services.pipewire.enable "PipeWire is enabled"
    ++ lib.optional (!lib.elem "cma=16M" config.boot.kernelParams) "the CMA pool is not 16 MiB"
    ++ lib.optional (lib.elem "console=tty1" config.boot.kernelParams) "the console is on tty1"
    ++ lib.optional (
      config.hardware.sg2k.usb.gadget.product != "LicheeRV Nano (NCM)"
    ) "the USB gadget is ${config.hardware.sg2k.usb.gadget.product}"
    ++ map (w: "warning: ${w}") config.warnings
    ++ map (a: "assertion: ${a.message}") (lib.filter (a: !a.assertion) config.assertions)
    ++ lib.optional (
      config.system.build.bootImage.profiles != [ "default" ]
    ) "the boot image has profiles ${toString config.system.build.bootImage.profiles}"
    ++ lib.optional (has "rauc_ext" config.system.build.bootImage.scripts.script_default) "the boot script carries rauc_ext"
    ++ lib.optional (
      !lib.elem (sys.pkgs.aic8800-firmware.override { variants = [ "aic8800D80" ]; }).drvPath (
        map (p: p.drvPath or "") config.hardware.firmware.paths
      )
    ) "the WiFi firmware is not the aic8800D80 set"
    ++ lib.optional (
      config.system.build.activeFip.drvPath != fips.fipPolyglot.drvPath
    ) "the active fip is not the Nano's polyglot"
    ++ lib.optional (
      config.hardware.sg2k.firmware.recoveryFip.drvPath
      != fips.${if core == "arm" then "fipArm" else "fipRiscv"}.drvPath
    ) "the recovery fip is not the Nano's ${core} fip"
    ++ map (a: "dsiPanel: assertion: ${a.message}") (lib.filter (a: !a.assertion) panel.assertions)
    ++ lib.optional (
      !panel.systemd.services ? st7701-panel-init
    ) "dsiPanel: no st7701-panel-init service"
    ++ lib.optional (
      !has "hynitron_cstxxx firmware_probe=1" panel.boot.extraModprobeConfig
    ) "dsiPanel: the touchscreen has no firmware_probe"
    ++ lib.optional (
      panel.system.build.activeFip.drvPath == config.system.build.activeFip.drvPath
    ) "dsiPanel: the fip does not release the touch pads";
in
if failures == [ ] then
  pkgs.runCommand "board-licheerv-nano-${core}" {
    passthru = {
      toplevel = config.system.build.toplevel;
      kernel = config.boot.kernelPackages.kernel.drvPath;
    };
  } "touch $out"
else
  throw ("board-licheerv-nano-${core}:\n  " + lib.concatStringsSep "\n  " failures)
