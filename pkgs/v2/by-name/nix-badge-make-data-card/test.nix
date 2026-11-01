# nix-badge-make-data-card on a BadgeOS card image with stand-ins for sysfs, /boot and the
# command line: USERDATA becomes EXT_USERDATA and BOOT is emptied, everything else on the
# card stays; a second run, or one after a stop between the two, finishes it; it refuses,
# changing nothing, off an SD boot or when /boot is not the card's BOOT.
{
  runCommand,
  gptfdisk,
  nix-badge-make-data-card,
}:
runCommand "nix-badge-make-data-card-test" { nativeBuildInputs = [ gptfdisk ]; } ''
  bin=${nix-badge-make-data-card}/bin/nix-badge-make-data-card
  fail() { echo "FAIL: $*"; cat out err 2>/dev/null; sgdisk -p card.img; ls -la boot; exit 1; }
  truncate -s 32M card.img
  sgdisk -n 1:2048:+8M -t 1:0700 -c 1:BOOT -n 2:0:+1M -c 2:UBOOT -n 3:0:+6M -c 3:NIX_A \
    -n 4:0:+6M -c 4:NIX_B -n 5:0:0 -c 5:USERDATA --hybrid=1:EE card.img > /dev/null
  parts() { for n in 1 2 3 4 5; do sgdisk -i $n card.img | sed -n "s/^Partition name: '\(.*\)'$/\1/p"; done | tr '\n' ' '; }
  mkdir -p sys/block/mmcblk0 sys/block/mmcblk1 dev
  printf 'SD\n' > sys/block/mmcblk0/type; printf 'MMC\n' > sys/block/mmcblk1/type
  for p in 1:BOOT 2:UBOOT 3:NIX_A 4:NIX_B 5:USERDATA; do
    mkdir -p sys/block/mmcblk0/mmcblk0p''${p%%:*}
    printf 'DEVNAME=mmcblk0p%s\nPARTN=%s\nPARTNAME=%s\n' "''${p%%:*}" "''${p%%:*}" "''${p#*:}" > sys/block/mmcblk0/mmcblk0p''${p%%:*}/uevent
  done
  ln -s "$PWD/card.img" dev/mmcblk0
  printf 'init=/init-arm nixbadge.bootmedium=1 rauc.slot=A\n' > sd
  printf 'init=/init-arm nixbadge.bootmedium=0 rauc.slot=A\n' > emmc
  fresh_boot() { rm -rf boot; mkdir -p boot/arm/slot-A boot/riscv; echo fip > boot/fip.bin; echo s > boot/secure; echo f > boot/arm/slot-A/boot.itb; }
  go() { # go <cmdline file> <BOOT's source>
    rc=0
    MAKE_CARD_CMDLINE=$PWD/$1 MAKE_CARD_SYSFS=$PWD/sys MAKE_CARD_DEV=$PWD/dev MAKE_CARD_BOOT=$PWD/boot \
      MAKE_CARD_BOOT_SOURCE=$2 $bin > out 2> err || rc=$?
  }

  # off an SD boot: refused, nothing changed
  fresh_boot; go emmc /dev/mmcblk0p1
  [ $rc = 1 ] && grep -q 'not booted from the SD card' err || fail "an eMMC boot was not refused"
  [ "$(parts)" = 'BOOT UBOOT NIX_A NIX_B USERDATA ' ] && [ -e boot/fip.bin ] || fail "an eMMC boot changed the card"
  # /boot is not the card's BOOT: refused, nothing changed
  go sd /dev/mmcblk1p1
  [ $rc = 1 ] && grep -q "/boot is /dev/mmcblk1p1, not the SD card's BOOT (/dev/mmcblk0p1)" err || fail "a foreign /boot was not refused"
  [ "$(parts)" = 'BOOT UBOOT NIX_A NIX_B USERDATA ' ] && [ -e boot/fip.bin ] || fail "a foreign /boot changed the card"

  go sd /dev/mmcblk0p1
  [ $rc = 0 ] || fail "exit $rc converting the card"
  [ "$(parts)" = 'BOOT UBOOT NIX_A NIX_B EXT_USERDATA ' ] || fail "partitions after converting: $(parts)"
  [ -d boot ] && [ -z "$(ls -A boot)" ] || fail "BOOT is not empty"
  sgdisk -v card.img | grep -q 'No problems found' || fail "the GPT does not verify"

  # a second run (the kernel still lists USERDATA until the reboot): nothing more changes
  fresh_boot; go sd /dev/mmcblk0p1
  [ $rc = 0 ] && [ "$(parts)" = 'BOOT UBOOT NIX_A NIX_B EXT_USERDATA ' ] || fail "a second run: $(parts)"
  [ -z "$(ls -A boot)" ] || fail "a second run left BOOT's files"
  # stopped after the rename and booted again (the kernel lists EXT_USERDATA): BOOT is emptied
  sed -i 's/^PARTNAME=USERDATA$/PARTNAME=EXT_USERDATA/' sys/block/mmcblk0/mmcblk0p5/uevent
  fresh_boot; go sd /dev/mmcblk0p1
  [ $rc = 0 ] && [ "$(parts)" = 'BOOT UBOOT NIX_A NIX_B EXT_USERDATA ' ] || fail "after an interrupted run: $(parts)"
  [ -z "$(ls -A boot)" ] || fail "after an interrupted run, BOOT kept its files"
  touch $out
''
