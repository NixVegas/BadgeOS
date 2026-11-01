# nix-badge-emmc-init --plan against a fake cmdline, device, sysfs and store image; the
# hardware checks it skips under --plan are grepped for in the script instead.
{
  runCommand,
  callPackage,
  nix-badge-emmc-init,
}:
let
  storeImage = callPackage ./store-image-fixture.nix { };
in
runCommand "nix-badge-emmc-init-test" { } ''
  bin=${nix-badge-emmc-init}/bin/nix-badge-emmc-init

  # fakesys <dir> <type>: a sysfs whose mmcblk1 has that device type
  fakesys() {
    mkdir -p "$1/class/block/mmcblk1/device"
    printf '%s\n' "$2" > "$1/class/block/mmcblk1/device/type"
  }
  fakesys sys MMC
  export EMMC_INIT_SYS=$PWD/sys

  # --- ordered plan-mode command list: SD-booted, --plan, EMMC_INIT_DEV set ---
  printf 'console=ttyS0 nixbadge.bootmedium=1 root=/dev/dm-0\n' > sd.cmdline
  EMMC_INIT_CMDLINE=$PWD/sd.cmdline EMMC_INIT_DEV=/dev/mmcblk1 "$bin" --plan > plan.out
  cat plan.out

  # the self-disk check is skipped (and says so) since EMMC_INIT_DEV is set
  grep -q 'skipping self-disk check: --plan with EMMC_INIT_DEV override' plan.out

  line() { grep -n -F -- "$1" plan.out | head -1 | cut -d: -f1; }
  l1=$(line 'sgdisk --zap-all /dev/mmcblk1')
  l2=$(line 'EBD0A0A2-B9E5-4433-87C0-68B6B72699C7')
  l2b=$(line '3DE21764-95BD-54BD-A5C3-4ABE786F38A8')
  l2c=$(line '0FC63DAF-8483-4772-8E79-3D69D8477DE4')
  l3=$(line 'of=/dev/mmcblk1boot0 bs=512 seek=0 ')
  l4=$(line 'of=/dev/mmcblk1boot0 bs=512 seek=2048 ')
  l5=$(line 'if=/dev/uboot1 of=/dev/mmcblk1boot1 bs=64K count=4 ')
  l6=$(line 'if=/dev/uboot1 of=/dev/mmcblk1p2 bs=64K count=4 ')
  l7=$(line 'mkfs.vfat -F 32 -n EBOOT /dev/mmcblk1p1')
  l8=$(line 'cp -r --no-preserve=all /boot/. ')
  l9=$(line 'if=/dev/nixA1 of=/dev/mmcblk1p3 ')
  l9b=$(line 'if=/dev/nixA1 of=/dev/mmcblk1p4 ')
  l10=$(line 'mkfs.ext4 -F -q -L USERDATA /dev/mmcblk1p5')

  for v in l1 l2 l2b l2c l3 l4 l5 l6 l7 l8 l9 l9b l10; do
    eval "val=\$$v"
    [ -n "$val" ] || { echo "missing/empty line number for $v" >&2; exit 1; }
  done

  # -le: the three GUIDs are on the same sgdisk line
  test "$l1" -le "$l2"
  test "$l2" -le "$l2b"
  test "$l2b" -le "$l2c"
  test "$l2c" -lt "$l3"
  test "$l3" -lt "$l4"
  test "$l4" -lt "$l5"
  test "$l5" -lt "$l6"
  test "$l6" -lt "$l7"
  test "$l7" -lt "$l8"
  test "$l8" -lt "$l9"
  test "$l9" -lt "$l9b"
  test "$l9b" -lt "$l10"

  # geometry: the exact sgdisk tokens
  grep -q -- '-a 2048' plan.out
  grep -q -- '-n 1:8192:+512M' plan.out
  grep -q -- '-n 2:0:+1M' plan.out
  grep -q -- '-n 3:0:+3G' plan.out
  grep -q -- '-n 4:0:+3G' plan.out
  grep -q -- '-n 5:0:0' plan.out
  grep -q -- '-c 1:BOOT' plan.out
  grep -q -- '-c 2:UBOOT' plan.out
  grep -q -- '-c 3:NIX_A' plan.out
  grep -q -- '-c 4:NIX_B' plan.out
  grep -q -- '-c 5:USERDATA' plan.out

  # ... in order on that one line
  geomline=$(grep -F -- 'sgdisk -a 2048' plan.out)
  case "$geomline" in
    *'-a 2048'*'-n 1:8192:+512M'*'-t 1:EBD0A0A2-B9E5-4433-87C0-68B6B72699C7'*'-c 1:BOOT'*'-n 2:0:+1M'*'-t 2:3DE21764-95BD-54BD-A5C3-4ABE786F38A8'*'-c 2:UBOOT'*'-n 3:0:+3G'*'-t 3:0FC63DAF-8483-4772-8E79-3D69D8477DE4'*'-c 3:NIX_A'*'-n 4:0:+3G'*'-t 4:0FC63DAF-8483-4772-8E79-3D69D8477DE4'*'-c 4:NIX_B'*'-n 5:0:0'*'-t 5:0FC63DAF-8483-4772-8E79-3D69D8477DE4'*'-c 5:USERDATA'*) ;;
    *) echo "sgdisk geometry line is missing a token or has mis-ordered tokens:" >&2; echo "$geomline" >&2; exit 1 ;;
  esac

  # the no-preserve copy form specifically, never cp -a
  grep -q 'cp -r --no-preserve=all /boot/. ' plan.out
  if grep -q '^+ cp -a /boot/\. ' plan.out; then echo 'cp -a in the plan' >&2; exit 1; fi

  # mount uses the same umask as the system's own /boot mount
  grep -q 'mount -o umask=0077 /dev/mmcblk1p1' plan.out

  # it says what it did, not what to do with the card: the caller may keep it in as a
  # data card
  [ "$(tail -n1 plan.out)" = "done: both eMMC slots hold the SD's system." ]
  if grep -q 'remove the SD card' plan.out; then echo 'tells the user to remove the card' >&2; exit 1; fi

  # --- refusal 1: not SD-booted ---
  printf 'console=ttyS0 nixbadge.bootmedium=0 root=/dev/dm-0\n' > emmc.cmdline
  rc=0
  EMMC_INIT_CMDLINE=$PWD/emmc.cmdline EMMC_INIT_DEV=/dev/mmcblk1 "$bin" --plan >refuse1.out 2>refuse1.err || rc=$?
  test "$rc" = 1
  grep -q 'refusing: not booted from SD (nixbadge.bootmedium=1 missing)' refuse1.err

  # --- refusal 2: no --yes and no --plan (the ERASES guard) ---
  rc=0
  EMMC_INIT_CMDLINE=$PWD/sd.cmdline EMMC_INIT_DEV=/dev/mmcblk1 "$bin" >refuse2.out 2>refuse2.err || rc=$?
  test "$rc" = 1
  grep -q 'this ERASES /dev/mmcblk1' refuse2.err

  # --- a non-mmcblk EMMC_INIT_DEV is refused, even under --plan ---
  rc=0
  EMMC_INIT_CMDLINE=$PWD/sd.cmdline EMMC_INIT_DEV=/dev/sda "$bin" --plan >refuse3.out 2>refuse3.err || rc=$?
  test "$rc" = 1
  grep -q 'refusing: /dev/sda is not an mmcblk device' refuse3.err

  # --- no eMMC at all, or an SD in its place: refused, even under --plan ---
  mkdir nosys
  rc=0
  EMMC_INIT_SYS=$PWD/nosys EMMC_INIT_CMDLINE=$PWD/sd.cmdline EMMC_INIT_DEV=/dev/mmcblk1 "$bin" --plan >nodev.out 2>nodev.err || rc=$?
  test "$rc" = 1
  grep -qF 'refusing: no /dev/mmcblk1 (this board has no eMMC?)' nodev.err
  if grep -q '^+ sgdisk' nodev.out; then echo 'no-device: planned a write' >&2; exit 1; fi
  fakesys sdsys SD
  rc=0
  EMMC_INIT_SYS=$PWD/sdsys EMMC_INIT_CMDLINE=$PWD/sd.cmdline EMMC_INIT_DEV=/dev/mmcblk1 "$bin" --plan >sdtype.out 2>sdtype.err || rc=$?
  test "$rc" = 1
  grep -qF 'refusing: /dev/mmcblk1 is not an eMMC' sdtype.err
  if grep -q '^+ sgdisk' sdtype.out; then echo 'sd-type: planned a write' >&2; exit 1; fi

  # --- without EMMC_INIT_DEV the self-disk check runs and finds no /dev/boot1 ---
  rc=0
  EMMC_INIT_CMDLINE=$PWD/sd.cmdline "$bin" --plan >refuse4.out 2>refuse4.err || rc=$?
  test "$rc" = 1
  grep -q 'refusing: /dev/boot1 missing (not an SD boot?)' refuse4.err

  # --- the hardware checks --plan skips are in the script ---
  grep -q 'stat -c%s /boot/fip.bin' "$bin"
  grep -q 1048576 "$bin"
  grep -q force_ro "$bin"

  # the BOOT-mount cleanup trap exists and is wired up
  grep -q 'trap nix_badge_emmc_init_cleanup EXIT' "$bin"
  grep -q 'mountpoint -q "$mnt"' "$bin"


  # --- slot-A FIT check ---
  # the default plan run above has no fake /boot, so the check is skipped and says so
  grep -q 'skipping the slot-A boot image check: --plan' plan.out
  # a gpt boot tree in the FIT layout: per core slot-A/boot.itb + vbmeta.itb, and /secure
  mktree() { # $1=bootdir $2=secure marker
    for c in arm riscv; do
      mkdir -p "$1/$c/slot-A"
      printf 'boot image %s' "$c" > "$1/$c/slot-A/boot.itb"
      printf 'vbmeta' > "$1/$c/slot-A/vbmeta.itb"
    done
    printf '%s' "$2" > "$1/secure"
  }
  # the card's NIX_A image: each core's image generation (system-<core>-1-link) links
  # its boot image (boot-image -> .../boot.itb); absolute links, resolved under $ro
  ro=$PWD/ro; mkdir -p "$ro/nix/var/nix/profiles"
  for c in arm riscv; do
    mkdir -p "$ro/nix/store/top-$c" "$ro/nix/store/bi-$c"
    printf 'boot image %s' "$c" > "$ro/nix/store/bi-$c/boot.itb"
    ln -s "/nix/store/bi-$c" "$ro/nix/store/top-$c/boot-image"
    ln -s "/nix/store/top-$c" "$ro/nix/var/nix/profiles/system-$c-1-link"
  done
  plan_on() { # $1=bootdir; stdout/stderr to $1.out/$1.err; sets rc
    rc=0
    EMMC_INIT_CMDLINE=$PWD/sd.cmdline EMMC_INIT_DEV=/dev/mmcblk1 EMMC_INIT_BOOTDIR=$PWD/$1 EMMC_INIT_ROSTORE=$ro "$bin" --plan > "$1.out" 2> "$1.err" || rc=$?
    cat "$1.out" "$1.err"
  }
  refused() { # $1=bootdir $2=expected refusal (grep -x regex): refused, before any write
    plan_on "$1"
    test "$rc" = 1 || { echo "$1: not refused" >&2; exit 1; }
    grep -qx "$2" "$1.err" || { echo "$1: wrong refusal" >&2; exit 1; }
    if grep -q 'sgdisk' "$1.out"; then echo "$1: refusal came after a write" >&2; exit 1; fi
  }
  # good: both cores' slot-A images present and the image generation's own
  mktree good signed
  plan_on good; test "$rc" = 0
  grep -qx 'slot-A arm boot image is the image generation'"'"'s: /nix/store/top-arm' good.out
  grep -qx 'slot-A riscv boot image is the image generation'"'"'s: /nix/store/top-riscv' good.out
  grep -qx 'boot tree is signed' good.out
  grep -q 'sgdisk --zap-all /dev/mmcblk1' good.out
  # the copy is checked file by file after the tree copy, /secure included, in order
  lc=$(grep -n -F 'cp -r --no-preserve=all /boot/. ' good.out | head -1 | cut -d: -f1)
  for f in arm/slot-A/boot.itb arm/slot-A/vbmeta.itb riscv/slot-A/boot.itb riscv/slot-A/vbmeta.itb secure; do
    lv=$(grep -n -- "^+ verify_copy /boot/$f .*/$f\$" good.out | head -1 | cut -d: -f1)
    [ -n "$lv" ] && [ "$lv" -gt "$lc" ] || { echo "no verify_copy of $f after the tree copy" >&2; exit 1; }
  done
  grep -q 'verify_copy() {' "$bin"
  # slot B gets slot A's files (NIX_B gets NIX_A's image), each checked after its copy
  for c in arm riscv; do
    for f in boot.itb vbmeta.itb; do
      lb=$(grep -n -- "^+ cp /boot/$c/slot-A/$f .*/$c/slot-B/$f\$" good.out | head -1 | cut -d: -f1)
      lv=$(grep -n -- "^+ verify_copy /boot/$c/slot-A/$f .*/$c/slot-B/$f\$" good.out | head -1 | cut -d: -f1)
      [ -n "$lb" ] && [ "$lb" -gt "$lc" ] && [ -n "$lv" ] && [ "$lv" -gt "$lb" ] \
        || { echo "no checked slot-B copy of $c/slot-A/$f after the tree copy" >&2; exit 1; }
    done
  done
  # missing images -> refuse, naming the path
  mktree nobi unsigned; rm nobi/riscv/slot-A/boot.itb
  refused nobi "refusing: $PWD/nobi/riscv/slot-A/boot.itb missing"
  mktree novb unsigned; rm novb/arm/slot-A/vbmeta.itb
  refused novb "refusing: $PWD/novb/arm/slot-A/vbmeta.itb missing"
  # an old extlinux card (no slot-A FITs at all) -> refuse
  mkdir -p none/arm/extlinux; touch none/arm/extlinux/extlinux-A.conf
  refused none "refusing: $PWD/none/arm/slot-A/boot.itb missing"
  # /secure missing or not one of the two words -> refuse
  mktree nosec signed; rm nosec/secure
  refused nosec "refusing: $PWD/nosec/secure missing"
  mktree badsec signed; printf 'maybe' > badsec/secure
  refused badsec "refusing: $PWD/badsec/secure says 'maybe', not signed or unsigned"
  # deployed: riscv's slot-A boot.itb is not the image generation's -> refuse
  mktree dep unsigned; printf 'boot image deployed' > dep/riscv/slot-A/boot.itb
  refused dep "refusing: $PWD/dep/riscv/slot-A/boot.itb is not the boot image of this card's NIX_A generation (/nix/store/top-riscv)"

  # --- both slots get the store image's own length (squashfs + verity tree) ---
  # the default plan run has no store image to read, and says so
  grep -qx 'skipping the store image size: --plan without /dev/nixA1' plan.out
  img=${storeImage}/store.img
  size=$(stat -c %s $img)
  rc=0
  EMMC_INIT_CMDLINE=$PWD/sd.cmdline EMMC_INIT_DEV=/dev/mmcblk1 EMMC_INIT_NIXA=$img "$bin" --plan > img.out 2> img.err || rc=$?
  cat img.out img.err
  test "$rc" = 0
  grep -qx "store image: $size bytes" img.out || { echo "the store image is not $size bytes" >&2; exit 1; }
  for p in 3 4; do
    grep -qx "+ dd if=$img of=/dev/mmcblk1p$p bs=4M iflag=count_bytes count=$size conv=fsync status=progress" img.out \
      || { echo "no dd of the $size-byte store image to p$p" >&2; exit 1; }
  done
  # too big for a 3 GiB slot (a superblock claiming 3 GiB + 1 byte), or not a squashfs:
  # refused before any write
  refused_img() { # $1 = image, $2 = expected refusal (grep -x regex)
    rc=0
    EMMC_INIT_CMDLINE=$PWD/sd.cmdline EMMC_INIT_DEV=/dev/mmcblk1 EMMC_INIT_NIXA=$PWD/$1 "$bin" --plan > "$1.out" 2> "$1.err" || rc=$?
    test "$rc" = 1 || { echo "$1: not refused" >&2; exit 1; }
    grep -qx "$2" "$1.err" || { cat "$1.err" >&2; echo "$1: wrong refusal" >&2; exit 1; }
    if grep -q sgdisk "$1.out"; then echo "$1: refusal came after a write" >&2; exit 1; fi
  }
  { printf hsqs; head -c 36 /dev/zero; printf '\001\000\000\300\000\000\000\000'; } > big.img
  refused_img big.img "refusing: the store image in $PWD/big.img is [0-9]* bytes, larger than the eMMC's 3 GiB slots"
  printf 'not a squashfs' > notsq.img
  refused_img notsq.img "refusing: $PWD/notsq.img does not hold a squashfs"

  # --- eMMC boot-area size asserts exist in the source (real hardware only) ---
  grep -q 'blockdev --getsize64 "''${E}boot0"' "$bin"
  grep -q 'blockdev --getsize64 "''${E}boot1"' "$bin"
  touch "$out"
''
