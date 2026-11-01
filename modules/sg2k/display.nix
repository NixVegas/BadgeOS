# The vendor's VIP display and codec drivers (pkgs/by-name/soph-display), forward-ported
# to the mainline kernel and loaded in the order the hardware wants.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  soph-display = pkgs.soph-display.override {
    kernel = config.boot.kernelPackages.kernel;
  };

  soph-vpu-firmware = pkgs.soph-vpu-firmware;

  cfg = config.hardware.sg2k.display;
  inherit (config.hardware.sg2k) hdmi;
  graphics = config.badge.graphics.enable;

  # rgn needs to come up before VO for scaler timing.
  loadOrder = [
    "soph_ion_compat"
    "cv181x_sys"
    "cv181x_base"
    "cv181x_vpss"
    "cv181x_rgn"
    "cv181x_vo"
    "cv181x_mipi_tx"
    "soph_dispsrc"
  ];

  # Codec island comes up last.
  codecOrder = [
    "cv181x_vcodec"
    "cv181x_jpeg"
    "cvi_vc_driver"
  ];

  allModules = loadOrder ++ codecOrder;

  # Out of the default load order.
  drmOrder = [ "soph_drm" ];

  mkLoader =
    name: mods:
    pkgs.writeShellScriptBin name ''
      set -e
      for m in ${lib.escapeShellArgs mods}; do
        ${pkgs.kmod}/bin/modprobe "$m"
      done
      ${pkgs.kmod}/bin/lsmod | ${pkgs.gnugrep}/bin/grep -E 'cv181x|soph_|cvi_vc' || true
    '';

  # Display only, safe to run unattended at boot.
  soph-display-load-display = mkLoader "soph-display-load-display" loadOrder;

  soph-display-load-codec = mkLoader "soph-display-load-codec" codecOrder;

  # Display leaf + KMS, for Wayland.
  soph-drm-load = mkLoader "soph-drm-load" (loadOrder ++ drmOrder);

  bootModules =
    loadOrder ++ lib.optionals cfg.autoLoadDrm drmOrder ++ lib.optionals cfg.autoLoadCodec codecOrder;
  soph-display-load-boot = mkLoader "soph-display-load-boot" bootModules;

  # Everything, for interactive use.
  soph-display-load = mkLoader "soph-display-load" allModules;
in
{
  options.hardware.sg2k.display = {
    enable = lib.mkEnableOption "the forward-ported Sophgo VIP display stack" // {
      default = config.hardware.sg2k.hdmi.enable;
      defaultText = lib.literalExpression "config.hardware.sg2k.hdmi.enable";
    };

    autoLoad = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Bring the VIP stack up at boot. Needs clk_ignore_unused on the kernel command
        line (kernel.nix): any MMIO to the VIP region after its clock is gated
        deadlocks the AXI interconnect.
      '';
    };

    autoLoadDrm = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Load the KMS front end (soph_drm) at boot too. Requires autoLoad.
      '';
    };

    autoLoadCodec = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Include the codec island in the boot-time load. Requires autoLoad.
      '';
    };

    drmDevice = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "/dev/dri/card1";
      description = ''
        Pin wlroots to one DRM device (WLR_DRM_DEVICES); empty lets it choose. The
        Sharp memory panel is a DRM device too, and card numbering is not stable.
      '';
    };
  };

  config = lib.mkIf (config.hardware.sg2k.enable && cfg.enable) {
    boot.extraModulePackages = [ soph-display ];
    hardware.firmware = [ soph-vpu-firmware ];
    environment.systemPackages = [
      soph-display-load
      soph-display-load-display
      soph-display-load-codec
      soph-drm-load
    ];

    # drmDevice names soph_drm's card by a stable link. Under sway, every card and link
    # gets a device unit too: greetd starts from drmDevice's, which exists only once udev
    # has processed the card (minutes on the C906).
    services.udev.extraRules =
      lib.optionalString (cfg.drmDevice != "") (
        ''
          SUBSYSTEM=="drm", KERNEL=="card[0-9]*", DRIVERS=="soph-drm", SYMLINK+="${lib.removePrefix "/dev/" cfg.drmDevice}"
        ''
        + lib.optionalString graphics ''
          SUBSYSTEM=="drm", KERNEL=="card[0-9]*", ENV{DEVTYPE}=="drm_minor", TAG+="systemd"
        ''
      )
      + ''
        SUBSYSTEM=="misc", KERNEL=="soph-ion", OWNER="root", GROUP="root", MODE="0600"
      '';

    # The LT8912B bridge's node is in the desktop profile's DTB only, where sway drives
    # it: both soph_drm modes drive a 720p line, so force_720p pins the bridge to it.
    boot.extraModprobeConfig = lib.mkIf graphics ''
      options lontium_lt8912b hactive_offset=${toString hdmi.hactiveOffset} hdmi_audio=${
        if hdmi.audio then "1" else "0"
      } force_720p=1
    '';

    boot.blacklistedKernelModules = allModules ++ drmOrder;

    # The codec island stays out of the boot unit by default: a VPU stuck after a warm
    # reboot blocks its modprobe in D-state, and multi-user.target never finishes.
    systemd.services.soph-display-load = lib.mkIf cfg.autoLoad {
      description = "Sophgo VIP display stack";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-udev-settle.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = 60;
        ExecStart = lib.getExe soph-display-load-boot;
      };
    };
  };
}
