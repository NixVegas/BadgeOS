# nix-badge-emmc-update --detect and --plan against a fake sysfs, boot trees, lower store
# and store image, and stubs; the real-device checks are grepped for in the script instead.
{
  lib,
  runCommand,
  callPackage,
  writeShellScriptBin,
  symlinkJoin,
  util-linux,
  nix-badge-emmc-update,
}:
let
  # $STUB_ENV: BOOT_ORDER, $STUB_A_LEFT/$STUB_B_LEFT the counters (3 when unset): "crc"
  # for a bad CRC, "" or "unset" for not defined, "io" for an unreadable env. fw_setenv
  # only logs; mount fails with $STUB_MOUNT.
  ubootTools = symlinkJoin {
    name = "stub-uboot-tools";
    paths = [
      (writeShellScriptBin "fw_printenv" ''
        echo "fw_printenv $*" >> "$LOG"
        case $2 in
          BOOT_ORDER) v=$STUB_ENV ;;
          BOOT_A_LEFT) v=''${STUB_A_LEFT-3} ;;
          BOOT_B_LEFT) v=''${STUB_B_LEFT-3} ;;
        esac
        case $v in
          crc) echo "Warning: Bad CRC, using default environment" >&2; echo "A B" ;;
          "" | unset) echo "## Error: \"$2\" not defined" >&2; exit 1 ;;
          io) echo "Can't open /dev/uboot0: Input/output error" >&2; exit 1 ;;
          *) echo "$v" ;;
        esac
      '')
      (writeShellScriptBin "fw_setenv" ''echo "fw_setenv $*" >> "$LOG"'')
    ];
  };
  utilLinux = symlinkJoin {
    name = "stub-mount-util-linux";
    paths = [
      (writeShellScriptBin "mount" ''echo "mount $*" >> "$LOG"; echo "$STUB_MOUNT" >&2; exit 32'')
      (lib.getBin util-linux)
    ];
  };
  storeImage = callPackage ../nix-badge-emmc-init/store-image-fixture.nix { };
  update = nix-badge-emmc-update.override {
    inherit ubootTools;
    util-linux = utilLinux;
    nix-badge-env-mirror = writeShellScriptBin "nix-badge-env-mirror" ''echo nix-badge-env-mirror >> "$LOG"'';
  };
in
runCommand "nix-badge-emmc-update-test" { } ''
  bin=${lib.getExe update}
  fail() { echo "FAIL: $*"; cat out err 2>/dev/null; exit 1; }
  printf 'console=ttyS0 nixbadge.bootmedium=1 rauc.external\n' > sd.cmdline
  printf 'console=ttyS0 nixbadge.bootmedium=0 rauc.slot=A\n' > emmc.cmdline

  # The SD: both cores' slot-A images, its marker and fip, and its NIX_A image's
  # generations whose boot-image links name the same boot.itb.
  for c in arm riscv; do
    mkdir -p sd/$c/slot-A ro/nix/store/top-$c ro/nix/store/bi-$c ro/nix/var/nix/profiles
    printf 'boot image %s' $c > sd/$c/slot-A/boot.itb
    printf 'boot image %s' $c > ro/nix/store/bi-$c/boot.itb
    printf 'vbmeta %s' $c > sd/$c/slot-A/vbmeta.itb
    ln -s /nix/store/bi-$c ro/nix/store/top-$c/boot-image
    ln -s /nix/store/top-$c ro/nix/var/nix/profiles/system-$c-1-link
  done
  echo unsigned > sd/secure
  printf 'fip' > sd/fip.bin

  # mksys <dir> <name of p1> ... <name of p5>: an eMMC with those GPT partition names
  # ("-" for no partition)
  mksys() {
    d=$1; shift
    mkdir -p "$d/class/block/mmcblk1/device"
    echo MMC > "$d/class/block/mmcblk1/device/type"
    n=0
    for l in "$@"; do
      n=$((n + 1))
      [ "$l" = - ] && continue
      mkdir -p "$d/class/block/mmcblk1p$n"
      printf 'MAJOR=179\nMINOR=%s\nDEVNAME=mmcblk1p%s\nDEVTYPE=partition\nPARTN=%s\nPARTNAME=%s\n' $n $n $n "$l" \
        > "$d/class/block/mmcblk1p$n/uevent"
    done
  }
  # slots <dir> <sectors>: NIX_A and NIX_B of that many 512-byte sectors
  slots() {
    echo "$2" > "$1/class/block/mmcblk1p3/size"
    echo "$2" > "$1/class/block/mmcblk1p4/size"
  }
  mksys sys BOOT UBOOT NIX_A NIX_B USERDATA
  slots sys 6291456
  mksys blank - - - - -
  mksys foreign BOOT UBOOT NIX_A data USERDATA
  mksys sdcard BOOT UBOOT NIX_A NIX_B USERDATA; echo SD > sdcard/class/block/mmcblk1/device/type
  mkdir -p eboot/arm/slot-A eboot/arm/slot-B eboot/riscv/slot-A eboot/riscv/slot-B
  echo unsigned > eboot/secure

  # go <mode> [VAR=value ...]: exit status in $rc, stdout in out, stderr in err, the
  # stubs' calls in log
  go() {
    m=$1; shift
    : > log
    rc=0
    env LOG=$PWD/log STUB_ENV="A B" EMMC_UPDATE_CMDLINE=$PWD/sd.cmdline EMMC_UPDATE_DEV=/dev/mmcblk1 \
      EMMC_UPDATE_SYS=$PWD/sys EMMC_UPDATE_EBOOT=$PWD/eboot EMMC_UPDATE_BOOTDIR=$PWD/sd \
      EMMC_UPDATE_ROSTORE=$PWD/ro EMMC_UPDATE_NIXA=$img "$@" "$bin" "--$m" > out 2> err || rc=$?
  }
  # the SD's NIX_A: a real store image and its own length
  img=${storeImage}/store.img
  size=$(stat -c %s $img)
  # nothing was written: no fw_setenv, no mirror, no planned command
  untouched() {
    ! grep -q 'fw_setenv\|nix-badge-env-mirror' log && ! grep -q '^+ ' out || fail "$1: a write was planned or run"
  }
  # slotplan <slot> <NIX partition>: the planned writes of one slot, RAUC's order
  e=$PWD/eboot
  s=$PWD/sd
  slotplan() {
    echo "+ fw_setenv BOOT_$1_LEFT 0"
    echo "+ dd if=$img of=$2 bs=4M iflag=count_bytes count=$size conv=fsync status=progress"
    for c in arm riscv; do
      echo "+ rm -f $e/$c/slot-$1/boot.itb.prev $e/$c/slot-$1/boot.itb.prev.new $e/$c/slot-$1/boot.itb.new $e/$c/slot-$1/vbmeta.itb.new"
      echo "+ mkdir -p $e/$c/slot-$1"
    done
    echo "+ sync"
    for c in arm riscv; do
      for f in boot.itb vbmeta.itb; do
        echo "+ cp $s/$c/slot-A/$f $e/$c/slot-$1/$f.new"
        echo "+ sync"
        echo "+ mv -f $e/$c/slot-$1/$f.new $e/$c/slot-$1/$f"
        echo "+ sync"
        echo "+ verify_copy $s/$c/slot-A/$f $e/$c/slot-$1/$f"
      done
    done
    for c in arm riscv; do
      echo "+ rm -rf $e/$c/slot-$1/nixos"
      x=$e/$c/extlinux
      echo "+ rm -f $x/extlinux-$1.conf $x/verity-append-$1 $x/extlinux-desktop-$1.conf $x/extlinux-video-$1.conf"
    done
    echo "+ sync"
  }
  # plan <first> <then> <first's NIX partition> <then's>: the exact planned writes when
  # <then> boots: <first> is written and made primary while <then> still boots, then
  # <then> is written behind it, and the env ends as a fresh card's
  plan() {
    slotplan $1 $3
    echo "+ dd if=$s/fip.bin of=/dev/mmcblk1boot0 bs=512 conv=fsync status=none"
    echo "+ fw_setenv -s - <<< 'BOOT_ORDER $1 $2' 'BOOT_$1_LEFT 3'"
    slotplan $2 $4
    echo "+ fw_setenv -s - <<< 'BOOT_ORDER A B' 'BOOT_A_LEFT 3' 'BOOT_B_LEFT 3'"
    echo "+ nix-badge-env-mirror"
    echo "+ sync"
  }

  # --- installed, slot A first: detect says so, the plan writes slot B, then slot A ---
  go detect
  [ $rc = 0 ] && grep -qx 'eMMC /dev/mmcblk1: installed; slot A boots first (BOOT_ORDER=A B), boot tree unsigned' out \
    || fail "installed eMMC not detected"
  [ "$(cat log)" = "$(printf 'fw_printenv -n %s\n' BOOT_ORDER BOOT_A_LEFT BOOT_B_LEFT)" ] \
    || fail "detect ran more than the env reads"
  go plan
  [ $rc = 0 ] || fail "plan A B failed"
  grep '^+ ' out > got || true
  plan B A /dev/mmcblk1p4 /dev/mmcblk1p3 > want
  diff -u want got || fail "plan for BOOT_ORDER=A B"
  grep -qx 'then slot A. USERDATA (/dev/mmcblk1p5) is kept.' out || fail "plan summary"
  # never USERDATA, never the factory fip, never a repartition or a mkfs
  ! grep -q 'mmcblk1p5\|seek=\|sgdisk\|mkfs' got || fail "A B plan touches USERDATA or the factory fip"
  untouched_log() { ! grep -q 'fw_setenv\|nix-badge-env-mirror' log || fail "$1: --plan ran a write"; }
  untouched_log "plan A B"

  # --- slot B first: the plan writes slot A, then slot B ---
  go plan STUB_ENV="B A"
  [ $rc = 0 ] || fail "plan B A failed"
  grep '^+ ' out > got || true
  plan A B /dev/mmcblk1p3 /dev/mmcblk1p4 > want
  diff -u want got || fail "plan for BOOT_ORDER=B A"
  untouched_log "plan B A"
  # ... and a one-slot BOOT_ORDER likewise
  go plan STUB_ENV=B
  grep '^+ ' out > got || true
  plan A B /dev/mmcblk1p3 /dev/mmcblk1p4 > want
  [ $rc = 0 ] && diff -u want got || fail "plan for BOOT_ORDER=B"

  # --- the first slot in BOOT_ORDER with attempts left boots and stays ---
  # B used up its attempts: A boots, B is updated
  go detect STUB_ENV="B A" STUB_B_LEFT=0
  [ $rc = 0 ] && grep -qx 'eMMC /dev/mmcblk1: installed; slot A boots first (BOOT_ORDER=B A), boot tree unsigned' out \
    || fail "detect B A with B_LEFT=0"
  go plan STUB_ENV="B A" STUB_B_LEFT=0 STUB_A_LEFT=3
  grep '^+ ' out > got || true
  plan B A /dev/mmcblk1p4 /dev/mmcblk1p3 > want
  [ $rc = 0 ] && diff -u want got || fail "plan for BOOT_ORDER=B A, B_LEFT=0"
  untouched_log "plan B A, B_LEFT=0"
  # A used up its attempts: B boots, A is updated
  go plan STUB_ENV="A B" STUB_A_LEFT=0 STUB_B_LEFT=1
  grep '^+ ' out > got || true
  plan A B /dev/mmcblk1p3 /dev/mmcblk1p4 > want
  [ $rc = 0 ] && diff -u want got || fail "plan for BOOT_ORDER=A B, A_LEFT=0"
  untouched_log "plan A B, A_LEFT=0"

  # --- not installed: detect exits 3 with the reason; plan refuses, unwritten ---
  # notinst <reason (grep -x)> [VAR=value ...]
  notinst() {
    r=$1; shift
    go detect "$@"
    [ $rc = 3 ] && grep -qx "eMMC /dev/mmcblk1: not installed: $r" out || fail "detect: want not installed: $r"
    go plan "$@"
    [ $rc = 1 ] && grep -qx "refusing: eMMC /dev/mmcblk1 is not installed ($r); nix-badge-emmc-init installs a blank one" err \
      || fail "plan on a non-install ($r)"
    untouched "plan ($r)"
  }
  data=' (it has the nix-badge partitions: installing erases them, user data included)'
  notinst "partition 1 is 'absent', not BOOT" EMMC_UPDATE_SYS=$PWD/blank
  notinst "partition 4 is 'data', not NIX_B" EMMC_UPDATE_SYS=$PWD/foreign
  notinst "its U-Boot env has a bad CRC$data" STUB_ENV=crc
  notinst "its U-Boot env has no BOOT_ORDER$data" STUB_ENV=
  notinst "BOOT_ORDER 'A A' names slot A twice$data" STUB_ENV="A A"
  notinst "BOOT_ORDER 'C A' names a slot other than A or B$data" STUB_ENV="C A"
  mkdir -p nosec; notinst "its BOOT has no secure marker of signed or unsigned$data" EMMC_UPDATE_EBOOT=$PWD/nosec
  mkdir -p badsec; echo maybe > badsec/secure
  notinst "its BOOT has no secure marker of signed or unsigned$data" EMMC_UPDATE_EBOOT=$PWD/badsec
  notinst "its BOOT partition does not mount as FAT$data" EMMC_UPDATE_EBOOT= \
    STUB_MOUNT="mount: /tmp/x/eboot: wrong fs type, bad option, bad superblock on /dev/mmcblk1p1, missing codepage or helper program, or other error."

  # --- refusals (exit 1) before any write ---
  # refused <message (grep -x)> [VAR=value ...]
  refused() {
    r=$1; shift
    for m in detect plan; do
      go $m "$@"
      [ $rc = 1 ] && grep -qx "refusing: $r" err || fail "$m: want refusing: $r"
      untouched "$m ($r)"
    done
  }
  refused 'not booted from SD (nixbadge.bootmedium=1 missing)' EMMC_UPDATE_CMDLINE=$PWD/emmc.cmdline
  refused '/dev/sda is not an mmcblk device' EMMC_UPDATE_DEV=/dev/sda
  refused '/dev/mmcblk1 is not an eMMC' EMMC_UPDATE_SYS=$PWD/sdcard
  refused 'no /dev/mmcblk2 (this badge has no eMMC?)' EMMC_UPDATE_DEV=/dev/mmcblk2
  # an env that cannot be read, a used-up or unreadable counter, a busy BOOT: an
  # install may be there, so never "not installed"
  refused "cannot read BOOT_ORDER from the eMMC's U-Boot env (fw_printenv exit 1): Can't open /dev/uboot0: Input/output error" \
    STUB_ENV=io
  refused "cannot read BOOT_B_LEFT from the eMMC's U-Boot env (fw_printenv exit 1): Can't open /dev/uboot0: Input/output error" \
    STUB_B_LEFT=io
  refused "no slot in BOOT_ORDER 'A B' has a boot attempt left; cannot tell which eMMC slot boots" \
    STUB_A_LEFT=0 STUB_B_LEFT=0
  refused "BOOT_B_LEFT is 'x3', not a number; cannot tell which eMMC slot boots" STUB_B_LEFT=x3
  refused "BOOT_A_LEFT is ''', not a number; cannot tell which eMMC slot boots" STUB_A_LEFT=unset
  busy='mount: /tmp/x/eboot: /dev/mmcblk1p1 already mounted or mount point busy.'
  refused "cannot mount /dev/mmcblk1p1: $busy" EMMC_UPDATE_EBOOT= STUB_MOUNT="$busy"

  # SD-side refusals stop the plan (detect is about the eMMC)
  # sdrefused <message (grep -x)> [VAR=value ...]
  sdrefused() {
    r=$1; shift
    go plan "$@"
    [ $rc = 1 ] && grep -qx "refusing: $r" err || fail "plan: want refusing: $r"
    untouched "plan ($r)"
  }
  # the secure marker of the SD and the eMMC differ, both ways
  mkdir -p signed; cp -r eboot/. signed/; echo signed > signed/secure
  sdrefused "this SD is unsigned but the eMMC is signed; switching secure mode erases the eMMC (nix-badge-emmc-init)" \
    EMMC_UPDATE_EBOOT=$PWD/signed
  cp -r sd sdsigned; echo signed > sdsigned/secure
  sdrefused "this SD is signed but the eMMC is unsigned; switching secure mode erases the eMMC (nix-badge-emmc-init)" \
    EMMC_UPDATE_BOOTDIR=$PWD/sdsigned
  # a deploy-rs'd card: slot A's boot.itb is not its NIX_A generation's
  cp -r sd dep; printf 'boot image deployed' > dep/riscv/slot-A/boot.itb
  sdrefused "$PWD/dep/riscv/slot-A/boot.itb is not the boot image of this card's NIX_A generation (/nix/store/top-riscv); re-flash the card and update before any deploy" \
    EMMC_UPDATE_BOOTDIR=$PWD/dep
  cp -r sd novb; rm novb/arm/slot-A/vbmeta.itb
  sdrefused "$PWD/novb/arm/slot-A/vbmeta.itb missing" EMMC_UPDATE_BOOTDIR=$PWD/novb
  cp -r sd bigfip; head -c 1048577 /dev/zero > bigfip/fip.bin
  sdrefused "$PWD/bigfip/fip.bin is 1048577 bytes, larger than the 1 MiB before the factory copy" \
    EMMC_UPDATE_BOOTDIR=$PWD/bigfip

  # --- slot sizes: the store image's own length against the eMMC's NIX_A and NIX_B ---
  # an old 2 GiB layout keeps its slots when the image fits
  cp -r sys old; slots old 4194304
  go plan EMMC_UPDATE_SYS=$PWD/old
  grep '^+ ' out > got || true
  plan B A /dev/mmcblk1p4 /dev/mmcblk1p3 > want
  [ $rc = 0 ] && diff -u want got || fail "plan for an image that fits a 2 GiB layout"
  # a superblock claiming 2 GiB + 1 byte: 2164408320 bytes with its verity tree, too big
  # for the old layout: needs-repartition (exit 4), nothing written
  { printf hsqs; head -c 36 /dev/zero; printf '\001\000\000\200\000\000\000\000'; } > big2.img
  go detect EMMC_UPDATE_SYS=$PWD/old EMMC_UPDATE_NIXA=$PWD/big2.img
  [ $rc = 4 ] && grep -qx "eMMC /dev/mmcblk1: needs-repartition: the SD's store image is 2164408320 bytes, larger than its 2147483648-byte NIX_A and NIX_B" out \
    || fail "detect: an image too big for a 2 GiB layout"
  go plan EMMC_UPDATE_SYS=$PWD/old EMMC_UPDATE_NIXA=$PWD/big2.img
  [ $rc = 4 ] && grep -qx "refusing: the SD's store image is 2164408320 bytes, larger than the eMMC's 2147483648-byte NIX_A and NIX_B; the 3 GiB layout erases USERDATA (/dev/mmcblk1p5): nix-badge-install offers it" err \
    || fail "plan: an image too big for a 2 GiB layout"
  untouched "plan (needs-repartition)"
  # the same image fits the 3 GiB layout: both slots get its 2164408320 bytes
  go plan EMMC_UPDATE_NIXA=$PWD/big2.img
  [ $rc = 0 ] && [ "$(grep -c "^+ dd if=$PWD/big2.img of=/dev/mmcblk1p[34] bs=4M iflag=count_bytes count=2164408320 conv=fsync status=progress\$" out)" = 2 ] \
    || fail "plan: a 2 GiB+ image in the 3 GiB layout"
  # the SD's own store image is the problem (bigger than even the 3 GiB layout, no
  # squashfs on its NIX_A, or no NIX_A): refused with exit 5, so the installer can say so
  # sdbad <message (grep -x)> [VAR=value ...]
  sdbad() {
    r=$1; shift
    for m in detect plan; do
      go $m "$@"
      [ $rc = 5 ] && grep -qx "refusing: $r" err || fail "$m: want exit 5 and refusing: $r"
      untouched "$m ($r)"
    done
  }
  { printf hsqs; head -c 36 /dev/zero; printf '\001\000\000\300\000\000\000\000'; } > big3.img
  sdbad "the SD's store image is [0-9]* bytes, larger than the 3 GiB layout's slots" EMMC_UPDATE_NIXA=$PWD/big3.img
  printf 'not a squashfs' > notsq.img
  sdbad "$PWD/notsq.img does not hold a squashfs" EMMC_UPDATE_NIXA=$PWD/notsq.img
  sdbad "$PWD/nonix missing" EMMC_UPDATE_NIXA=$PWD/nonix

  # --yes never trusts the stand-ins for the real block devices: here, with no
  # /dev/boot1, it refuses before reading the eMMC
  go yes
  [ $rc = 1 ] && grep -qx 'refusing: /dev/boot1 missing (not an SD boot?)' err || fail "yes on fake devices"
  untouched "yes on fake devices"

  go nonsense
  [ $rc = 2 ] && grep -q '^usage: nix-badge-emmc-update' err || fail "usage"

  # --- the real-device checks exist (skipped here: EMMC_UPDATE_DEV is set) ---
  grep -q 'lsblk -no PKNAME "$(readlink -f /dev/boot1)"' "$bin" || fail "self-disk check"
  grep -q 'readlink -f /dev/uboot0' "$bin" || fail "env device check"
  grep -q 'force_ro' "$bin" && grep -q 'df -k --output=avail' "$bin" || fail "force_ro / free space"
  grep -q 'mount -t vfat -o "$opts,umask=0077"' "$bin" || fail "BOOT mount"
  echo PASS > $out
''
