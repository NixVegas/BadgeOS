# nix-badge-make-data-card: turn the SD card this badge booted from into a data card for its
# eMMC system, in place. USERDATA is renamed EXT_USERDATA, which marks a data card, and BOOT
# is emptied so the mask ROM no longer boots the card; what USERDATA holds, and NIX_A and
# NIX_B, stay. The rename goes first: stopped between the two, the card still boots (its
# state in a tmpfs, as it has no USERDATA), and this runs again. MAKE_CARD_CMDLINE, MAKE_CARD_SYSFS, MAKE_CARD_DEV, MAKE_CARD_BOOT and
# MAKE_CARD_BOOT_SOURCE stand in for /proc/cmdline, /sys, /dev, /boot and BOOT's source.
sys=${MAKE_CARD_SYSFS:-/sys}
dev=${MAKE_CARD_DEV:-/dev}
boot=${MAKE_CARD_BOOT:-/boot}

case " $(cat "${MAKE_CARD_CMDLINE:-/proc/cmdline}") " in
  *' nixbadge.bootmedium=1 '*) ;;
  *) echo "nix-badge-make-data-card: not booted from the SD card" >&2; exit 1 ;;
esac

# The SD card, and its partitions by name as the kernel listed them at boot.
sd=""
for b in "$sys"/block/mmcblk*; do
  b=${b##*/}
  case $b in *boot* | *rpmb*) continue ;; esac
  if [ "$(cat "$sys/block/$b/type" 2>/dev/null || cat "$sys/block/$b/device/type" 2>/dev/null)" = SD ]; then sd=$b; break; fi
done
[ -n "$sd" ] || { echo "nix-badge-make-data-card: no SD card" >&2; exit 1; }
part() { # $1 = name: its partition number, as the kernel listed it
  local u
  for u in "$sys/block/$sd/$sd"*/uevent; do
    if grep -qx "PARTNAME=$1" "$u" 2>/dev/null; then sed -n 's/^PARTN=//p' "$u"; return 0; fi
  done
  return 1
}
# EXT_USERDATA already: a run stopped after the rename, and the card booted again.
n=$(part USERDATA || part EXT_USERDATA) || { echo "nix-badge-make-data-card: the SD card has no USERDATA partition" >&2; exit 1; }
b=$(part BOOT) || { echo "nix-badge-make-data-card: the SD card has no BOOT partition" >&2; exit 1; }
src=${MAKE_CARD_BOOT_SOURCE:-$(findmnt -no SOURCE "$boot")}
if [ "$src" != "/dev/${sd}p$b" ]; then
  echo "nix-badge-make-data-card: $boot is $src, not the SD card's BOOT (/dev/${sd}p$b); nothing changed" >&2
  exit 1
fi

sgdisk --change-name="$n:EXT_USERDATA" "$dev/$sd" > /dev/null
find "$boot" -mindepth 1 -delete
sync
echo "The SD card is a data card: its USERDATA is EXT_USERDATA, and its BOOT is empty."
