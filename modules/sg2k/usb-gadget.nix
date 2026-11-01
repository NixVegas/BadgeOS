# USB CDC-NCM gadget: assemble the composite gadget in configfs and bind it to the
# dwc2 UDC, so the badge appears to a host as a USB network device.
{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.hardware.sg2k.usb.gadget;
  udc = "4340000.usb";
  lan = config.badge.lan;
  # The badge's network is this link, rather than a port of the router's.
  ownLink = lan.enable && lan.interface == config.badge.router.interfaces.usb;

  nixBadge = pkgs.nix-badge-noeval;

  # The fused DEVICE_ID, else a per-die fingerprint of the always-programmed EPHY
  # calibration fuses (0x08..0x27).
  serialSnippet = lib.optionalString cfg.serialFromEfuse ''
    if [ -z "$serial" ]; then
      serial=$(${nixBadge}/bin/nix-badge board-id --serial 2>/dev/null || true)
    fi
    if [ -z "$serial" ]; then
      nv=/sys/bus/nvmem/devices/sophgo_efuse_nvmem0/nvmem
      if [ -r "$nv" ]; then
        fp=$(dd if="$nv" bs=1 skip=8 count=32 2>/dev/null | sha256sum | cut -c1-12)
        [ -n "$fp" ] && serial="SG-$fp"
      fi
    fi
  '';

  # The fused USER record, else the configured product string.
  productSnippet = ''
    product='${cfg.product}'
    p=$(${nixBadge}/bin/nix-badge board-id --product 2>/dev/null || true)
    [ -n "$p" ] && product="$p"
  '';

  addrSnippet = lib.optionalString ownLink ''
    # usb0 appears when the ncm function binds, a little after the UDC.
    for _ in $(seq 1 25); do
      [ -e /sys/class/net/usb0 ] && break
      sleep 0.2
    done
    if [ -e /sys/class/net/usb0 ]; then
      ip link set usb0 up 2>/dev/null || true
      ip addr replace ${lan.address}/${toString lan.prefixLength} dev usb0 2>/dev/null || true
    fi
  '';

  gadgetUp = pkgs.writeShellScript "nix-badge-usb-gadget-up" ''
    set -eu
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.kmod
        pkgs.iproute2
      ]
    }:$PATH
    modprobe libcomposite || true

    # Slack only: udev starts this on the UDC's add event.
    for _ in $(seq 1 30); do
      [ -e /sys/class/udc/${udc} ] && break
      sleep 0.2
    done
    [ -e /sys/class/udc/${udc} ] || { echo "no UDC ${udc}; skipping gadget"; exit 0; }

    # Descriptor serial: explicit override, else eFuse-derived, else DT.
    serial='${cfg.serialNumber}'
    ${serialSnippet}
    if [ -z "$serial" ]; then
      serial=$(cat /sys/firmware/devicetree/base/serial-number 2>/dev/null | tr -d '\0' || true)
    fi
    [ -n "$serial" ] || serial="SG1-0001"

    ${productSnippet}

    G=/sys/kernel/config/usb_gadget/nix-badge
    if [ ! -d "$G" ]; then
      mkdir -p "$G"
      cd "$G"
      echo 0x1d6b > idVendor          # Linux Foundation
      echo 0x0104 > idProduct         # Multifunction Composite Gadget
      echo 0x0100 > bcdDevice
      echo 0x0200 > bcdUSB
      mkdir -p strings/0x409
      printf '%s' "$serial"                > strings/0x409/serialnumber
      printf '%s' '${cfg.manufacturer}'    > strings/0x409/manufacturer
      printf '%s' "$product"               > strings/0x409/product
      mkdir -p configs/c.1/strings/0x409
      echo "CDC NCM" > configs/c.1/strings/0x409/configuration
      echo 250       > configs/c.1/MaxPower
      mkdir -p functions/ncm.usb0
      # Locally-administered MACs (0x02 bit): dev = badge side, host = the PC side.
      echo "02:1d:6b:00:00:01" > functions/ncm.usb0/dev_addr
      echo "02:1d:6b:00:00:02" > functions/ncm.usb0/host_addr
      ln -sf functions/ncm.usb0 configs/c.1/
    else
      # The fuses may have been burned since the gadget was assembled.
      printf '%s' "$serial"  > "$G/strings/0x409/serialnumber" 2>/dev/null || true
      printf '%s' "$product" > "$G/strings/0x409/product"      2>/dev/null || true
    fi

    cd "$G"
    if [ -z "$(cat UDC 2>/dev/null)" ]; then
      echo ${udc} > UDC
    fi
    # No role write: dr_mode is peripheral, and a role write can soft-lock dwc2.
    ${addrSnippet}
    echo "gadget bound; serial=$serial; udc state=$(cat /sys/class/udc/${udc}/state 2>/dev/null)"
  '';
  gadgetDown = pkgs.writeShellScript "nix-badge-usb-gadget-down" ''
    set -u
    G=/sys/kernel/config/usb_gadget/nix-badge
    [ -d "$G" ] || exit 0
    echo "" > "$G/UDC" 2>/dev/null || true
    # Tear down in reverse: unlink function from config, then rmdir the tree.
    rm -f "$G"/configs/c.1/ncm.usb0 2>/dev/null || true
    rmdir "$G"/configs/c.1/strings/0x409 2>/dev/null || true
    rmdir "$G"/configs/c.1 2>/dev/null || true
    rmdir "$G"/functions/ncm.usb0 2>/dev/null || true
    rmdir "$G"/strings/0x409 2>/dev/null || true
    rmdir "$G" 2>/dev/null || true
  '';
in
{
  options.hardware.sg2k.usb.gadget = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable the USB CDC-NCM gadget (badge-as-network-device over USB).";
    };

    manufacturer = lib.mkOption {
      type = lib.types.str;
      default = "Dagian Industries";
      description = "USB iManufacturer string descriptor.";
    };

    product = lib.mkOption {
      type = lib.types.str;
      default = "SG200x board (NCM)";
      description = ''
        USB iProduct string descriptor. May carry a store path or build id (up to
        126 UTF-16 units).
      '';
    };

    serialNumber = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        USB iSerialNumber. Empty means derive it at runtime.
      '';
    };

    serialFromEfuse = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        When serialNumber is empty, get the serial from the eFuses.
      '';
    };
  };

  config = lib.mkIf (config.hardware.sg2k.enable && cfg.enable) {
    systemd.services.nix-badge-usb-gadget = {
      description = "nix-badge USB CDC-NCM gadget";
      # Started by the udev rule below once dwc2 registers its UDC, late in boot.
      after = [ "sys-kernel-config.mount" ];
      requires = [ "sys-kernel-config.mount" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = gadgetUp;
        ExecStop = gadgetDown;
      };
    };

    services.udev.extraRules = ''
      SUBSYSTEM=="udc", KERNEL=="4340000.usb", ACTION=="add", TAG+="systemd", ENV{SYSTEMD_WANTS}+="nix-badge-usb-gadget.service"
    '';

    system.build.usbGadgetUp = gadgetUp;
  };
}
