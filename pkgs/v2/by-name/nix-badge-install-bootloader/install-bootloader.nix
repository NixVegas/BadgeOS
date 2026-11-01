{
  pkgs,
  lib,
  core,
  secureBoot,
  # This core's own fip, kept on /boot as the way back from the other core; null for
  # none.
  recoveryFip,
  # The fip file the ROM boots, written to fipPath.
  activeFip,
  fipPath,
  # Whether the board has an eMMC, whose boot area 1 an eMMC boot reads the fip from.
  emmc,
  # Data cards (hardware.sg2k.externalStorage): with one in use the FIT goes to the
  # card's BOOT at /boot-card, and nothing on the eMMC is written.
  externalStorage ? false,
}:
let
  # Where the FIT is written: the booted medium's /boot, or with data cards the card's
  # BOOT when one is in use ($fitdir, set below).
  fitdir = if externalStorage then "$fitdir" else "$dir";
  firmwareNote =
    if recoveryFip != null || secureBoot then
      "this core's recovery fip-${core}.bin and the active polyglot ${fipPath}"
    else
      "the active fip ${fipPath}";

  # Every refusal below comes before any write to /boot, fips included.
  installBody = ''
    # RAUC A/B: which slot this deploy writes.
    slot=$(${pkgs.coreutils}/bin/tr ' ' '\n' < /proc/cmdline | ${pkgs.gnused}/bin/sed -n '/^rauc\.slot=/{s///p;q}')
    case "$slot" in
      A|B) ;;
      *) echo "sg2k: no valid rauc.slot= on /proc/cmdline -- refusing to guess the slot" >&2; exit 1 ;;
    esac

    if [ ! -e "$dir/slot-$slot/vbmeta.itb" ]; then
      echo "sg2k: this card is not on the FIT layout (no vbmeta.itb in $dir/slot-$slot); install the RAUC bundle or reflash first" >&2
      exit 1
    fi
    secureMarker=$(cat /boot/secure 2>/dev/null) || secureMarker=
    case "$secureMarker" in
      signed|unsigned) ;;
      *) echo "sg2k: /boot/secure is missing or invalid (expected signed|unsigned) -- refusing" >&2; exit 1 ;;
    esac
    genMarker=$(cat "$toplevel/boot-image/.secure" 2>/dev/null) || genMarker=
    case "$genMarker" in
      signed|unsigned) ;;
      *) echo "sg2k: $toplevel/boot-image/.secure is missing or invalid (expected signed|unsigned) -- refusing" >&2; exit 1 ;;
    esac
    if [ "$secureMarker" != "$genMarker" ]; then
      if [ "$secureMarker" = signed ]; then
        echo "sg2k: this card is secure-boot but the generation's boot image is unsigned -- refusing" >&2
      else
        echo "sg2k: this card is plain (unsigned) but the generation's boot image is signed -- switching secure mode needs a reflash" >&2
      fi
      exit 1
    fi

  ''
  + lib.optionalString externalStorage ''
    if [ "$fitdir" != "$dir" ]; then
      # Room on the card's BOOT for the new FIT and the copy of the old one kept as .prev,
      # counting the leftovers removed first.
      need=$(${pkgs.coreutils}/bin/stat -c%s "$toplevel/boot-image/boot.itb")
      if [ -e "$fitdir/slot-$slot/boot.itb" ]; then
        need=$((need + $(${pkgs.coreutils}/bin/stat -c%s "$fitdir/slot-$slot/boot.itb")))
      fi
      freed=0
      for f in boot.itb.prev boot.itb.prev.new boot.itb.new; do
        if [ -e "$fitdir/slot-$slot/$f" ]; then
          freed=$((freed + $(${pkgs.coreutils}/bin/stat -c%s "$fitdir/slot-$slot/$f")))
        fi
      done
      avail=$(${pkgs.coreutils}/bin/df -k --output=avail /boot-card | ${pkgs.coreutils}/bin/tail -n1 | ${pkgs.coreutils}/bin/tr -d ' ')
      if [ $((avail * 1024 + freed)) -lt "$need" ]; then
        echo "sg2k: the card's BOOT has $((avail * 1024 + freed)) bytes free, the boot image needs $need -- refusing" >&2
        exit 1
      fi
      mkdir -p "$fitdir/slot-$slot"
    fi
  ''
  + ''
    # Copy the generation's FIT into the booted slot so the slot always has a boot.itb.
    rm -f "${fitdir}/slot-$slot/boot.itb.prev" "${fitdir}/slot-$slot/boot.itb.prev.new" "${fitdir}/slot-$slot/boot.itb.new"
    sync
    cp "$toplevel/boot-image/boot.itb" "${fitdir}/slot-$slot/boot.itb.new"
    sync
    if [ -e "${fitdir}/slot-$slot/boot.itb" ]; then
      cp "${fitdir}/slot-$slot/boot.itb" "${fitdir}/slot-$slot/boot.itb.prev.new"
      sync
      mv -f "${fitdir}/slot-$slot/boot.itb.prev.new" "${fitdir}/slot-$slot/boot.itb.prev"
    fi
    mv -f "${fitdir}/slot-$slot/boot.itb.new" "${fitdir}/slot-$slot/boot.itb"
    sync
    echo "sg2k: installed the ${core} boot image in ${fitdir}/slot-$slot"
  '';

  # A data card in use (stage 0 mounted the eMMC's USERDATA read-only at /.lower-userdata):
  # U-Boot boots the FIT on the card's BOOT while the card is in, so the generation goes
  # there, and nothing on the eMMC changes, its fips included.
  cardPreamble = lib.optionalString externalStorage ''
    fitdir=$dir
      if ${pkgs.util-linux}/bin/mountpoint -q /.lower-userdata; then
        if ! ${pkgs.util-linux}/bin/mountpoint -q /boot-card; then
          echo "sg2k: deploying with a data card needs a BOOT partition on the card -- refusing" >&2
          exit 1
        fi
        fitdir="/boot-card/${core}"
      fi
  '';
  # U-Boot boots the card's FIT for a slot only while .nixbadge-cardfit-<slot> is on the
  # card's EXT_USERDATA; stage 0 removes it when it resets the card's Nix layer for the
  # slot.
  cardSkipsFirmware = lib.optionalString externalStorage ''
    if [ "$fitdir" != "$dir" ]; then
        echo "$toplevel" > "/.userdata/.nixbadge-cardfit-$slot.new"
        sync
        mv -f "/.userdata/.nixbadge-cardfit-$slot.new" "/.userdata/.nixbadge-cardfit-$slot"
        sync
        echo "sg2k: data card in use: the eMMC's /boot and fips are left as they are"
        exit 0
      fi
  '';
in
''
  set -euo pipefail
  toplevel="$1"
  dir="/boot/${core}"

  # Refuse a card that is not on the squashfs layout: its boot entry would hang on dm-mod.waitfor=.
  if [ "$(${pkgs.util-linux}/bin/findmnt -no FSTYPE / 2>/dev/null)" != squashfs ]; then
    echo "sg2k: / is not squashfs -- this card predates the gpt-squashfs layout; reflash it" >&2
    exit 1
  fi

  # Without the FAT mounted, the install would land on the rootfs and the badge keeps booting the old generation.
  if ! ${pkgs.util-linux}/bin/mountpoint -q /boot; then
    echo "sg2k: /boot is not mounted -- refusing" >&2
    exit 1
  fi
  ${cardPreamble}${installBody}
  ${cardSkipsFirmware}# Firmware: ${firmwareNote}, written tmp + sync + mv.
  ${
    if recoveryFip != null then
      ''
        newfipcore="${recoveryFip}"
        if ! cmp -s "$newfipcore" "/boot/fip-${core}.bin" 2>/dev/null; then
          cp "$newfipcore" "/boot/fip-${core}.bin.new"
          sync
          mv "/boot/fip-${core}.bin.new" "/boot/fip-${core}.bin"
          sync
          echo "sg2k: updated recovery /boot/fip-${core}.bin"
        fi
      ''
    else if secureBoot then
      ''
        # The unsigned recovery blob cannot boot a fused badge.
        echo "sg2k: secure boot -- no unsigned /boot/fip-${core}.bin recovery blob"
      ''
    else
      ""
  }
  # One command per line: under set -e a failed cp inside an && chain does not exit.
  newpoly="${activeFip}"
  if ! cmp -s "$newpoly" "${fipPath}" 2>/dev/null; then
    cp "$newpoly" "${fipPath}.new"
    sync
    mv "${fipPath}.new" "${fipPath}"
    sync
    echo "sg2k: refreshed active polyglot ${fipPath} -- new firmware on next reboot"
  fi
''
+ lib.optionalString emmc ''
  # An eMMC boot reads the fip from boot area 1 (/dev/fip), not /boot/fip.bin; the factory copy at +1 MiB stays untouched.
  if ${pkgs.coreutils}/bin/tr ' ' '\n' < /proc/cmdline | ${pkgs.gnugrep}/bin/grep -qx 'nixbadge.bootmedium=0'; then
  ${
    if fipPath == "/boot/fip.bin" then
      ''
        fipsize=$(${pkgs.coreutils}/bin/stat -c%s "$newpoly")
        if [ "$fipsize" -gt 1048576 ]; then
          echo "sg2k: the new fip is $fipsize bytes, over the 1 MiB before the factory copy at +1 MiB of /dev/fip -- NOT writing /dev/fip" >&2
          exit 1
        fi
        if [ ! -b /dev/fip ]; then
          echo "sg2k: eMMC boot but no /dev/fip -- the ROM keeps its current fip" >&2
        elif ! ${pkgs.diffutils}/bin/cmp -s -n "$fipsize" "$newpoly" /dev/fip; then
          ${pkgs.coreutils}/bin/dd if="$newpoly" of=/dev/fip bs=512 conv=fsync status=none
          echo "sg2k: eMMC boot: wrote the new fip to /dev/fip (boot area 1, offset 0; the +1 MiB factory copy is untouched) -- new firmware on next reboot"
        else
          echo "sg2k: eMMC boot: /dev/fip already holds this fip"
        fi''
    else
      ''echo "sg2k: eMMC boot with fipPath=${fipPath}: /dev/fip is managed by hand, not written by a deploy"''
  }
  fi
''
