# nix-badge-grow-userdata on a card image dd'd onto a bigger card, with only sysfs to go
# on (no udev, as on a first boot whose udev is still busy): USERDATA reaches the end of
# the disk with its GUID and name, the hybrid MBR keeps the FAT entry the mask ROM boots
# through, and the run is stamped. A partition not named USERDATA is left alone.
{
  runCommand,
  gptfdisk,
  nix-badge-grow-userdata,
}:
runCommand "nix-badge-grow-userdata-test" { nativeBuildInputs = [ gptfdisk ]; } ''
  bin=${nix-badge-grow-userdata}/bin/nix-badge-grow-userdata
  fail() { echo "FAIL: $*"; sgdisk -p disk.img; exit 1; }
  # A 32 MiB image in the SD layout, on a 64 MiB card: its backup GPT sits mid-card.
  truncate -s 32M disk.img
  sgdisk -n 1:2048:+8M -t 1:0700 -c 1:BOOT -n 2:0:+1M -c 2:UBOOT -n 3:0:+6M -c 3:NIX_A \
    -n 4:0:+6M -c 4:NIX_B -n 5:0:0 -t 5:8300 -c 5:USERDATA --hybrid=1:EE disk.img > /dev/null
  guid=$(sgdisk -i 5 disk.img | sed -n 's/^Partition unique GUID: //p')
  truncate -s 64M disk.img
  mkdir -p sys/devices/card/sdt/sdtp5 sys/devices/card/sdt/sdtp3 sys/class/block dev
  printf 5 > sys/devices/card/sdt/sdtp5/partition
  printf 'MAJOR=8\nMINOR=5\nDEVNAME=sdtp5\nDEVTYPE=partition\nPARTN=5\nPARTNAME=USERDATA\n' > sys/devices/card/sdt/sdtp5/uevent
  printf 3 > sys/devices/card/sdt/sdtp3/partition
  printf 'MAJOR=8\nMINOR=3\nDEVNAME=sdtp3\nDEVTYPE=partition\nPARTN=3\nPARTNAME=NIX_A\n' > sys/devices/card/sdt/sdtp3/uevent
  ln -s ../../devices/card/sdt/sdtp5 sys/class/block/sdtp5
  ln -s ../../devices/card/sdt/sdtp3 sys/class/block/sdtp3
  ln -s "$PWD/disk.img" dev/sdt
  go() { GROW_SYSFS=$PWD/sys GROW_DEV=$PWD/dev GROW_STAMP=$PWD/stamp GROW_SOURCE=/dev/$1 $bin; }

  # Not USERDATA: nothing changes and nothing is stamped.
  before=$(sgdisk -i 3 disk.img)
  go sdtp3 || fail "exit $? for a partition that isn't USERDATA"
  [ ! -e stamp ] || fail "stamped a partition that isn't USERDATA"
  [ "$(sgdisk -i 3 disk.img)" = "$before" ] || fail "changed a partition that isn't USERDATA"

  go sdtp5 || fail "exit $? growing USERDATA"
  [ -e stamp ] || fail "not stamped"
  info=$(sgdisk -i 5 disk.img)
  [ "$(printf '%s\n' "$info" | sed -n 's/^Last sector: \([0-9]*\).*/\1/p')" = $(( 64 * 2048 - 34 )) ] || fail "USERDATA does not reach the end"
  [ "$(printf '%s\n' "$info" | sed -n 's/^Partition unique GUID: //p')" = "$guid" ] || fail "USERDATA's GUID changed"
  printf '%s\n' "$info" | grep -q "^Partition name: 'USERDATA'" || fail "USERDATA lost its name"
  sgdisk -v disk.img | grep -q 'No problems found' || fail "the GPT does not verify"
  # MBR entries 1 and 2 (types at 0x1c2 and 0x1d2): the FAT partition and the EE protective.
  types=$(od -An -tx1 -j 450 -N 1 disk.img)$(od -An -tx1 -j 466 -N 1 disk.img)
  case $types in *ee*) ;; *) fail "no EE entry in the MBR ($types)" ;; esac
  case $types in *07* | *0b* | *0c*) ;; *) fail "the MBR lost the FAT entry ($types)" ;; esac
  touch $out
''
