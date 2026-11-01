# nix-badge-emmc-init [--plan] [--yes]: lay out a blank eMMC like the SD's GPT and copy
# the booted SD's slot A into both of its slots. --plan prints the commands and skips the
# hardware checks.
plan=0; yes=0
for a in "$@"; do
  case $a in
    --plan) plan=1 ;;
    --yes) yes=1 ;;
    *) echo "usage: nix-badge-emmc-init [--plan] [--yes]" >&2; exit 2 ;;
  esac
done

# The whole "nixbadge.bootmedium=1" token, padded so "=10" cannot match.
cmdline=${EMMC_INIT_CMDLINE:-/proc/cmdline}
content=$(cat "$cmdline")
case " $content " in
  *' nixbadge.bootmedium=1 '*) ;;
  *) echo "refusing: not booted from SD (nixbadge.bootmedium=1 missing)" >&2; exit 1 ;;
esac

E=${EMMC_INIT_DEV:-/dev/mmcblk1}

# The device paths below follow mmcblk naming ("${E}boot0", "${E}p1").
case "$(basename "$E")" in
  mmcblk*) ;;
  *) echo "refusing: $E is not an mmcblk device" >&2; exit 1 ;;
esac

# The eMMC itself, not the SD, in every mode. EMMC_INIT_SYS stands in for /sys in tests.
sys=${EMMC_INIT_SYS:-/sys}
name=$(basename "$E")
[ -e "$sys/class/block/$name" ] \
  || { echo "refusing: no $E (this board has no eMMC?)" >&2; exit 1; }
[ "$(cat "$sys/class/block/$name/device/type" 2>/dev/null)" = MMC ] \
  || { echo "refusing: $E is not an eMMC" >&2; exit 1; }

run() { echo "+ $*"; [ "$plan" = 1 ] || "$@"; }

[ "$plan" = 1 ] || [ "$yes" = 1 ] \
  || { echo "this ERASES $E; re-run with --yes (or --plan to preview)" >&2; exit 1; }

# Refuse the disk that holds the booted SD's own BOOT partition. The test's fake device
# (--plan with EMMC_INIT_DEV) has no /dev/boot1 to compare against.
if [ "$plan" = 1 ] && [ -n "${EMMC_INIT_DEV:-}" ]; then
  echo "skipping self-disk check: --plan with EMMC_INIT_DEV override"
else
  [ -e /dev/boot1 ] \
    || { echo "refusing: /dev/boot1 missing (not an SD boot?)" >&2; exit 1; }
  sd_disk=$(lsblk -no PKNAME "$(readlink -f /dev/boot1)")
  if [ "$(basename "$E")" = "$sd_disk" ]; then
    echo "refusing: $E is the disk holding the booted SD's own BOOT partition" >&2
    exit 1
  fi
fi


# Refuse a card whose slot A is incomplete or not its own NIX_A image's. The eMMC gets
# a raw NIX_A and a fresh USERDATA, so it boots the image generation: slot A's boot.itb
# must be that generation's, not a later deploy's.
# EMMC_INIT_BOOTDIR and EMMC_INIT_ROSTORE stand in for /boot and /nix/.ro-store in tests.
bootdir=${EMMC_INIT_BOOTDIR:-/boot}
rostore=${EMMC_INIT_ROSTORE:-/nix/.ro-store}
# No cmp in runtimeInputs.
same() { [ "$(sha256sum < "$1")" = "$(sha256sum < "$2")" ]; }
if [ "$plan" = 1 ] && [ -z "${EMMC_INIT_BOOTDIR:-}" ]; then
  echo "skipping the slot-A boot image check: --plan"
else
  for core in arm riscv; do
    for f in boot.itb vbmeta.itb; do
      [ -s "$bootdir/$core/slot-A/$f" ] || { echo "refusing: $bootdir/$core/slot-A/$f missing" >&2; exit 1; }
    done
  done
  [ -f "$bootdir/secure" ] || { echo "refusing: $bootdir/secure missing" >&2; exit 1; }
  marker=$(cat "$bootdir/secure")
  case $marker in
    signed | unsigned) ;;
    *) echo "refusing: $bootdir/secure says '$marker', not signed or unsigned" >&2; exit 1 ;;
  esac
  for core in arm riscv; do
    gen=$(readlink "$rostore/nix/var/nix/profiles/system-$core-1-link") \
      || { echo "refusing: no system-$core-1-link in this card's NIX_A image" >&2; exit 1; }
    bootimage=$(readlink "$rostore$gen/boot-image") \
      || { echo "refusing: $gen (this card's NIX_A $core generation) has no boot-image" >&2; exit 1; }
    if ! same "$bootdir/$core/slot-A/boot.itb" "$rostore$bootimage/boot.itb"; then
      echo "refusing: $bootdir/$core/slot-A/boot.itb is not the boot image of this card's NIX_A generation ($gen)" >&2
      echo "  Re-flash this card from the image, then run nix-badge-emmc-init before any deploy." >&2
      exit 1
    fi
    echo "slot-A $core boot image is the image generation's: $gen"
  done
  echo "boot tree is $marker"
fi

# The store image's own length: the 4 KiB-padded squashfs and the dm-verity tree
# nix-badge-store-squashfs appends to it; the rest of the SD's slot is padding. Checked
# before any write. EMMC_INIT_NIXA stands in for /dev/nixA1 in tests.
nixa=${EMMC_INIT_NIXA:-/dev/nixA1}
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
if [ -e "$nixa" ]; then
  bytes=$(store_image_bytes "$nixa") || { echo "refusing: $nixa does not hold a squashfs" >&2; exit 1; }
  [ "$bytes" -le $((3 * 1024 * 1024 * 1024)) ] \
    || { echo "refusing: the store image in $nixa is $bytes bytes, larger than the eMMC's 3 GiB slots" >&2; exit 1; }
  echo "store image: $bytes bytes"
elif [ "$plan" = 1 ]; then
  echo "skipping the store image size: --plan without $nixa"
  bytes="<store image bytes>"
else
  echo "refusing: $nixa missing" >&2
  exit 1
fi

# Boot area 1 holds the fip and its copy at +1 MiB, boot area 2 the two 0x20000 env copies.
if [ "$plan" = 0 ]; then
  b0=$(blockdev --getsize64 "${E}boot0")
  [ "$b0" -ge $((2 * 1024 * 1024)) ] \
    || { echo "refusing: ${E}boot0 is $b0 bytes, smaller than the 2 MiB the fip + its +1 MiB copy need" >&2; exit 1; }
  b1=$(blockdev --getsize64 "${E}boot1")
  [ "$b1" -ge $((256 * 1024)) ] \
    || { echo "refusing: ${E}boot1 is $b1 bytes, smaller than the 256 KiB the two env copies need" >&2; exit 1; }
fi
run sgdisk --zap-all "$E"

# The partitions of nix-badge-sd-image-gpt. Offsets past BOOT's start do not matter: the
# ROM reads boot area 1 and U-Boot finds the partitions by number.
run sgdisk -a 2048 \
  -n 1:8192:+512M -t 1:EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 -c 1:BOOT \
  -n 2:0:+1M      -t 2:3DE21764-95BD-54BD-A5C3-4ABE786F38A8 -c 2:UBOOT \
  -n 3:0:+3G      -t 3:0FC63DAF-8483-4772-8E79-3D69D8477DE4 -c 3:NIX_A \
  -n 4:0:+3G      -t 4:0FC63DAF-8483-4772-8E79-3D69D8477DE4 -c 4:NIX_B \
  -n 5:0:0        -t 5:0FC63DAF-8483-4772-8E79-3D69D8477DE4 -c 5:USERDATA \
  "$E"
# sgdisk already re-reads the table, and a second BLKRRPART races udev (EBUSY): wait for
# the nodes, and re-read only if they do not appear.
wait_parts() {
  local _
  for _ in $(seq 1 20); do
    [ -b "${E}p1" ] && [ -b "${E}p5" ] && return 0
    sleep 0.5
  done
  blockdev --rereadpt "$E" 2>/dev/null || true
  sleep 1
  [ -b "${E}p1" ] && [ -b "${E}p5" ] || { echo "refusing: partition nodes ${E}p1..p5 did not appear after sgdisk" >&2; return 1; }
}
if [ "$plan" = 1 ]; then echo "+ wait for ${E}p1..${E}p5"; else wait_parts; fi

# The fip must fit below its copy at +1 MiB, and the boot areas' force_ro must be 0.
# Never touch EXT_CSD or `mmc bootpart`: the ROM manages the boot-area enable bits.
if [ "$plan" = 0 ]; then
  fipsize=$(stat -c%s /boot/fip.bin)
  [ "$fipsize" -le 1048576 ] \
    || { echo "refusing: /boot/fip.bin is $fipsize bytes, larger than the 1 MiB gap before its own second copy" >&2; exit 1; }
  for area in boot0 boot1; do
    f="/sys/block/$(basename "$E")$area/force_ro"
    if [ "$(cat "$f")" != 0 ]; then
      echo 0 > "$f"
      echo "force_ro was set on $f; cleared it to 0"
    fi
  done
fi

# Boot area 1: the fip at 0 and the fallback copy RAUC never rewrites at +1 MiB. Boot
# area 2 and UBOOT: the SD's live env, both 0x20000 copies.
run dd if=/boot/fip.bin of="${E}boot0" bs=512 seek=0    conv=fsync status=none
run dd if=/boot/fip.bin of="${E}boot0" bs=512 seek=2048 conv=fsync status=none
run dd if=/dev/uboot1   of="${E}boot1" bs=64K count=4   conv=fsync status=none
run dd if=/dev/uboot1   of="${E}p2"    bs=64K count=4   conv=fsync status=none

# BOOT: fresh FAT32 and a copy of the SD's /boot (`cp -a` fails on vfat). The trap
# unmounts it on any exit, so a retry is not blocked by a mounted ${E}p1.
run mkfs.vfat -F 32 -n EBOOT "${E}p1"
mnt=$(mktemp -d)
nix_badge_emmc_init_cleanup() {
  local status=$?
  if [ "$plan" = 0 ] && mountpoint -q "$mnt" 2>/dev/null; then
    umount "$mnt" 2>/dev/null \
      || echo "warning: failed to unmount $mnt during cleanup -- unmount it by hand before retrying" >&2
  fi
  rmdir "$mnt" 2>/dev/null || true
  exit "$status"
}
trap nix_badge_emmc_init_cleanup EXIT

run mount -o umask=0077 "${E}p1" "$mnt" \
  || { echo "error: mounting ${E}p1 on $mnt failed" >&2; exit 1; }
run cp -r --no-preserve=all /boot/. "$mnt"/ \
  || { echo "error: copying /boot onto the new BOOT partition failed" >&2; exit 1; }
# Slot B gets slot A's files, as NIX_B gets NIX_A's image.
for core in arm riscv; do
  run rm -rf "$mnt/$core/slot-B"
  run mkdir -p "$mnt/$core/slot-B"
  for f in boot.itb vbmeta.itb; do
    run cp "/boot/$core/slot-A/$f" "$mnt/$core/slot-B/$f"
  done
done
# Read the boot-critical files back from the new FAT before it is unmounted.
verify_copy() { # $1 = the card's file, $2 = its copy on the eMMC
  same "$1" "$2" || { echo "refusing: $2 differs from $1 after the copy" >&2; exit 1; }
}
for core in arm riscv; do
  for f in boot.itb vbmeta.itb; do
    run verify_copy "/boot/$core/slot-A/$f" "$mnt/$core/slot-A/$f"
    run verify_copy "/boot/$core/slot-A/$f" "$mnt/$core/slot-B/$f"
  done
done
run verify_copy /boot/secure "$mnt/secure"
run umount "$mnt" \
  || { echo "error: unmounting $mnt failed" >&2; exit 1; }

# NIX_A and NIX_B: the SD's store image, its own length.
run dd if="$nixa" of="${E}p3" bs=4M iflag=count_bytes count="$bytes" conv=fsync status=progress
run dd if="$nixa" of="${E}p4" bs=4M iflag=count_bytes count="$bytes" conv=fsync status=progress

# USERDATA: fresh ext4 only -- stage-0 finds it by PARTNAME and seeds it.
run mkfs.ext4 -F -q -L USERDATA "${E}p5"   # -F: a re-run finds the previous USERDATA and must not prompt
run sync
echo "done: both eMMC slots hold the SD's system."
