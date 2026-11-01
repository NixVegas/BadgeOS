# nix-badge-emmc-update --detect | --plan | --yes: from an SD boot, put the SD's slot A
# into both slots of an installed eMMC, the inactive one first, each as a RAUC install
# would; USERDATA is kept. --detect exits 0 for an install, 3 for none
# (nix-badge-emmc-init's job), 1 on a refusal, and 4 when the SD's store image does not
# fit the eMMC's slots (an old 2 GiB layout), 5 when the SD's own store image is missing,
# not a squashfs or too big for any layout (--plan and --yes exit 4 and 5 there too).
# EMMC_UPDATE_* stand in for the real devices in tests; with EMMC_UPDATE_DEV set outside
# --yes, the block-device checks are skipped.
set -eu

mode=
for a in "$@"; do
  case $a in
    --detect) mode=detect ;;
    --plan) mode=plan ;;
    --yes) mode=yes ;;
    *) mode=usage; break ;;
  esac
done
case $mode in
  detect | plan | yes) ;;
  *) echo "usage: nix-badge-emmc-update --detect | --plan | --yes" >&2; exit 2 ;;
esac

refuse() { echo "refusing: $*" >&2; exit 1; }
# The SD's own store image is the problem: exit 5, so nix-badge-install can say so.
sd_refuse() { echo "refusing: $*" >&2; exit 5; }

case " $(cat "${EMMC_UPDATE_CMDLINE:-/proc/cmdline}") " in
  *' nixbadge.bootmedium=1 '*) ;;
  *) refuse "not booted from SD (nixbadge.bootmedium=1 missing)" ;;
esac

E=${EMMC_UPDATE_DEV:-/dev/mmcblk1}
name=$(basename "$E")
case $name in
  mmcblk*) ;;
  *) refuse "$E is not an mmcblk device" ;;
esac
sys=${EMMC_UPDATE_SYS:-/sys}
bootdir=${EMMC_UPDATE_BOOTDIR:-/boot}
rostore=${EMMC_UPDATE_ROSTORE:-/nix/.ro-store}
hw=1
if [ -n "${EMMC_UPDATE_DEV:-}" ] && [ "$mode" != yes ]; then hw=0; fi
plan=0
[ "$mode" = yes ] || plan=1

run() { echo "+ $*"; [ "$plan" = 1 ] || "$@"; }
same() { [ "$(sha256sum < "$1")" = "$(sha256sum < "$2")" ]; }

# The eMMC itself, not the SD.
[ -e "$sys/class/block/$name" ] || refuse "no $E (this badge has no eMMC?)"
[ "$(cat "$sys/class/block/$name/device/type" 2>/dev/null)" = MMC ] || refuse "$E is not an eMMC"
if [ "$hw" = 1 ]; then
  [ -e /dev/boot1 ] || refuse "/dev/boot1 missing (not an SD boot?)"
  [ "$(lsblk -no PKNAME "$(readlink -f /dev/boot1)")" != "$name" ] \
    || refuse "$E is the disk holding the booted SD's own BOOT partition"
  # fw_printenv/fw_setenv use /etc/fw_env.config, whose /dev/uboot0 must be this
  # eMMC's boot area 2, or the env read below is another disk's.
  [ "$(readlink -f /dev/uboot0)" = "$(readlink -f "${E}boot1")" ] \
    || refuse "/dev/uboot0 is not ${E}boot1"
fi

tmp=$(mktemp -d)
mnt=$tmp/eboot
cleanup() {
  status=$?
  if mountpoint -q "$mnt" 2>/dev/null; then
    umount "$mnt" 2>/dev/null || echo "warning: failed to unmount $mnt; unmount it by hand" >&2
  fi
  # Never rm -r: after a failed unmount, $mnt is still the eMMC's BOOT.
  rm -f "$tmp/env.err" "$tmp/mount.err"
  rmdir "$mnt" "$tmp" 2>/dev/null || true
  exit "$status"
}
trap cleanup EXIT

# not_installed <reason>: --detect exits 3, the others refuse. Once the partition names
# match (labels=1), user data may be there and only the erase path gets past it.
labels=0
not_installed() {
  if [ "$labels" = 1 ]; then
    set -- "$1 (it has the nix-badge partitions: installing erases them, user data included)"
  fi
  if [ "$mode" = detect ]; then
    echo "eMMC $E: not installed: $1"
    exit 3
  fi
  refuse "eMMC $E is not installed ($1); nix-badge-emmc-init installs a blank one"
}

n=0
for label in BOOT UBOOT NIX_A NIX_B USERDATA; do
  n=$((n + 1))
  part=$(sed -n 's/^PARTNAME=//p' "$sys/class/block/${name}p$n/uevent" 2>/dev/null) || part=
  [ "$part" = "$label" ] || not_installed "partition $n is '${part:-absent}', not $label"
done
labels=1

# getenv <name>: the value in $val, empty when not defined. On a bad CRC fw_printenv
# reads its default env and exits 0: the warning is the only sign.
getenv() {
  st=0
  val=$(fw_printenv -n "$1" 2> "$tmp/env.err") || st=$?
  case $(cat "$tmp/env.err") in
    *'Bad CRC'*) not_installed "its U-Boot env has a bad CRC" ;;
  esac
  if [ "$st" != 0 ]; then
    case $(cat "$tmp/env.err") in
      *"\"$1\" not defined"*) val= ;;
      *) refuse "cannot read $1 from the eMMC's U-Boot env (fw_printenv exit $st): $(cat "$tmp/env.err")" ;;
    esac
  fi
}
getenv BOOT_ORDER
order=$val
[ -n "$order" ] || not_installed "its U-Boot env has no BOOT_ORDER"
# U-Boot boots the first slot in BOOT_ORDER whose BOOT_x_LEFT is above 0: that slot
# keeps booting while the other one is written first.
active=
seen=
set -f # BOOT_ORDER is split on spaces, never globbed
for s in $order; do
  case " $seen " in *" $s "*) not_installed "BOOT_ORDER '$order' names slot $s twice" ;; esac
  case $s in
    A | B) seen="$seen $s" ;;
    *) not_installed "BOOT_ORDER '$order' names a slot other than A or B" ;;
  esac
  getenv "BOOT_${s}_LEFT"
  case $val in
    '' | *[!0-9]*) refuse "BOOT_${s}_LEFT is '$val', not a number; cannot tell which eMMC slot boots" ;;
  esac
  [ -n "$active" ] || [ "$val" -eq 0 ] || active=$s
done
set +f
[ -n "$active" ] || refuse "no slot in BOOT_ORDER '$order' has a boot attempt left; cannot tell which eMMC slot boots"
case $active in
  A) new=B; newpart=${E}p4; activepart=${E}p3 ;;
  *) new=A; newpart=${E}p3; activepart=${E}p4 ;;
esac

# The eMMC BOOT FAT (a directory in tests), read-write only for --yes.
if [ -n "${EMMC_UPDATE_EBOOT:-}" ]; then
  eb=$EMMC_UPDATE_EBOOT
else
  mkdir "$mnt"
  opts=ro
  [ "$mode" != yes ] || opts=rw
  # Only a partition with no FAT means no install; any other mount failure is a refusal.
  if ! mount -t vfat -o "$opts,umask=0077" "${E}p1" "$mnt" 2> "$tmp/mount.err"; then
    case $(cat "$tmp/mount.err") in
      *'wrong fs type'*) not_installed "its BOOT partition does not mount as FAT" ;;
      *) refuse "cannot mount ${E}p1: $(cat "$tmp/mount.err")" ;;
    esac
  fi
  eb=$mnt
fi
emmc_marker=$(cat "$eb/secure" 2>/dev/null) || emmc_marker=
case $emmc_marker in
  signed | unsigned) ;;
  *) not_installed "its BOOT has no secure marker of signed or unsigned" ;;
esac

# The SD's store image, its own length: the 4 KiB-padded squashfs and the dm-verity tree
# nix-badge-store-squashfs appends to it (the rest of its slot is padding), against the
# eMMC's smaller slot. EMMC_UPDATE_NIXA stands in for /dev/nixA1 in tests.
nixa=${EMMC_UPDATE_NIXA:-/dev/nixA1}
store_image_bytes() { # $1 = a slot holding a store image
  local used data n tree=0
  [ "$(od -An -tx1 -N4 "$1" | tr -d ' ')" = 68737173 ] || return 1 # "hsqs"
  used=$(od -An -tu8 --endian=little -j40 -N8 "$1" | tr -d ' ')
  data=$(( (used + 4095) / 4096 ))
  # sha256 over 4 KiB blocks: 128 digests per hash block, one level per 128x
  n=$data
  while [ "$n" -gt 1 ]; do n=$(( (n + 127) / 128 )); tree=$(( tree + n )); done
  echo $(( (data + tree) * 4096 ))
}
[ -e "$nixa" ] || sd_refuse "$nixa missing"
bytes=$(store_image_bytes "$nixa") || sd_refuse "$nixa does not hold a squashfs"
slot=
for p in 3 4; do
  sz=$(cat "$sys/class/block/${name}p$p/size" 2>/dev/null) || sz=
  case $sz in
    '' | *[!0-9]*) refuse "cannot read the size of ${E}p$p" ;;
  esac
  sz=$((sz * 512))
  if [ -z "$slot" ] || [ "$sz" -lt "$slot" ]; then slot=$sz; fi
done
if [ "$bytes" -gt "$slot" ]; then
  [ "$bytes" -le $((3 * 1024 * 1024 * 1024)) ] \
    || sd_refuse "the SD's store image is $bytes bytes, larger than the 3 GiB layout's slots"
  if [ "$mode" = detect ]; then
    echo "eMMC $E: needs-repartition: the SD's store image is $bytes bytes, larger than its $slot-byte NIX_A and NIX_B"
  else
    echo "refusing: the SD's store image is $bytes bytes, larger than the eMMC's $slot-byte NIX_A and NIX_B; the 3 GiB layout erases USERDATA (${E}p5): nix-badge-install offers it" >&2
  fi
  exit 4
fi

if [ "$mode" = detect ]; then
  echo "eMMC $E: installed; slot $active boots first (BOOT_ORDER=$order), boot tree $emmc_marker"
  exit 0
fi

# The SD's slot-A images go with its raw NIX_A only while slot A's boot.itb is the image
# generation's: a deployed one lives in the SD's upper layer, which the eMMC does not get.
for core in arm riscv; do
  for f in boot.itb vbmeta.itb; do
    [ -s "$bootdir/$core/slot-A/$f" ] || refuse "$bootdir/$core/slot-A/$f missing"
  done
done
sd_marker=$(cat "$bootdir/secure" 2>/dev/null) || refuse "$bootdir/secure missing"
case $sd_marker in
  signed | unsigned) ;;
  *) refuse "$bootdir/secure says '$sd_marker', not signed or unsigned" ;;
esac
# One fip serves both slots: a secure one leaves the other slot's unsigned images
# unbootable, a plain one drops the signature check the eMMC was set up with.
[ "$sd_marker" = "$emmc_marker" ] \
  || refuse "this SD is $sd_marker but the eMMC is $emmc_marker; switching secure mode erases the eMMC (nix-badge-emmc-init)"
for core in arm riscv; do
  gen=$(readlink "$rostore/nix/var/nix/profiles/system-$core-1-link") \
    || refuse "no system-$core-1-link in this card's NIX_A image"
  bootimage=$(readlink "$rostore$gen/boot-image") \
    || refuse "$gen (this card's NIX_A $core generation) has no boot-image"
  same "$bootdir/$core/slot-A/boot.itb" "$rostore$bootimage/boot.itb" \
    || refuse "$bootdir/$core/slot-A/boot.itb is not the boot image of this card's NIX_A generation ($gen); re-flash the card and update before any deploy"
done
# The ROM falls back to the factory fip at +1 MiB of boot area 1, so the new one must
# end before it.
[ -s "$bootdir/fip.bin" ] || refuse "$bootdir/fip.bin missing"
fipsize=$(stat -c%s "$bootdir/fip.bin")
[ "$fipsize" -le 1048576 ] \
  || refuse "$bootdir/fip.bin is $fipsize bytes, larger than the 1 MiB before the factory copy"
if [ "$mode" = yes ]; then
  # Room for both cores' new files beside the old ones (they are replaced by
  # renames), counting what the cleanup below frees first.
  need=$((16 * 1024 * 1024))
  freed=0
  for core in arm riscv; do
    for f in boot.itb vbmeta.itb; do
      need=$((need + $(stat -c%s "$bootdir/$core/slot-A/$f")))
    done
    for s in A B; do
      for f in boot.itb.prev boot.itb.prev.new boot.itb.new vbmeta.itb.new; do
        if [ -f "$eb/$core/slot-$s/$f" ]; then
          freed=$((freed + $(stat -c%s "$eb/$core/slot-$s/$f")))
        fi
      done
    done
  done
  avail_kib=$(df -k --output=avail "$eb" | tail -n1 | tr -d ' ')
  case $avail_kib in
    '' | *[!0-9]*) refuse "cannot read the free space of the eMMC BOOT (df said '$avail_kib')" ;;
  esac
  [ $((avail_kib * 1024 + freed)) -ge "$need" ] \
    || refuse "the eMMC BOOT has $((avail_kib * 1024 + freed)) bytes free, the slot-$new files need $need"
  f="$sys/block/${name}boot0/force_ro"
  if [ "$(cat "$f")" != 0 ]; then
    echo 0 > "$f"
    echo "force_ro was set on $f; cleared it to 0"
  fi
fi

echo "Update: the SD's system goes to both eMMC slots, slot $new first while slot $active still boots,"
echo "then slot $active. USERDATA (${E}p5) is kept."

verify_copy() {
  same "$1" "$2" || { echo "error: $2 differs from $1 after the copy" >&2; exit 1; }
}
# write_slot <slot> <partition>: RAUC's order. The slot is unbootable while it is
# written; the caller makes it bootable again. Each core's slot gets <file>.new, sync,
# rename. No .prev: an older boot.itb would boot against the wrong store. Then the
# slot's leftover extlinux files go.
write_slot() {
  local core d f x
  run fw_setenv "BOOT_$1_LEFT" 0
  run dd if="$nixa" of="$2" bs=4M iflag=count_bytes count="$bytes" conv=fsync status=progress
  for core in arm riscv; do
    d=$eb/$core/slot-$1
    run rm -f "$d/boot.itb.prev" "$d/boot.itb.prev.new" "$d/boot.itb.new" "$d/vbmeta.itb.new"
    run mkdir -p "$d"
  done
  run sync
  for core in arm riscv; do
    d=$eb/$core/slot-$1
    for f in boot.itb vbmeta.itb; do
      run cp "$bootdir/$core/slot-A/$f" "$d/$f.new"
      run sync
      run mv -f "$d/$f.new" "$d/$f"
      run sync
      run verify_copy "$bootdir/$core/slot-A/$f" "$d/$f"
    done
  done
  for core in arm riscv; do
    run rm -rf "$eb/$core/slot-$1/nixos"
    x=$eb/$core/extlinux
    run rm -f "$x/extlinux-$1.conf" "$x/verity-append-$1" "$x/extlinux-desktop-$1.conf" "$x/extlinux-video-$1.conf"
  done
  run sync
}

# A power cut before slot $new is primary leaves slot $active booting as before; after
# it, slot $new boots while slot $active is written.
write_slot "$new" "$newpart"

# Boot area 1, offset 0 only: the factory copy at +1 MiB is the ROM's fallback if
# this write is torn.
run dd if="$bootdir/fip.bin" of="${E}boot0" bs=512 conv=fsync status=none

# One env write for both variables (fw_setenv writes the redundant copy), as RAUC's
# uboot backend marks a slot primary.
echo "+ fw_setenv -s - <<< 'BOOT_ORDER $new $active' 'BOOT_${new}_LEFT 3'"
if [ "$plan" = 0 ]; then
  printf 'BOOT_ORDER %s %s\nBOOT_%s_LEFT 3\n' "$new" "$active" "$new" | fw_setenv -s -
fi

write_slot "$active" "$activepart"
if [ -z "${EMMC_UPDATE_EBOOT:-}" ]; then
  run umount "$mnt"
fi

# Both slots hold the same system: the env of a fresh card.
echo "+ fw_setenv -s - <<< 'BOOT_ORDER A B' 'BOOT_A_LEFT 3' 'BOOT_B_LEFT 3'"
if [ "$plan" = 0 ]; then
  printf 'BOOT_ORDER A B\nBOOT_A_LEFT 3\nBOOT_B_LEFT 3\n' | fw_setenv -s -
fi
# The boot-time nix-badge-env-mirror retries a failed mirror.
run nix-badge-env-mirror || echo "warning: the env mirror failed" >&2
run sync
if [ "$plan" = 0 ]; then
  echo "done: both eMMC slots hold the SD's system."
fi
