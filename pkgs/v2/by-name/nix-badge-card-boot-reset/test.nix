# nix-badge-card-boot-reset against a fake card BOOT and reset list.
{ runCommand, nix-badge-card-boot-reset }:
runCommand "nix-badge-card-boot-reset-test" { } ''
  bin=${nix-badge-card-boot-reset}/bin/nix-badge-card-boot-reset
  fail() { echo "FAIL: $*"; find boot -type f | sort; exit 1; }
  # both cores' slots A and B, each with a boot image and its .prev
  mk() {
    rm -rf boot
    for c in arm riscv; do
      for s in A B; do
        mkdir -p boot/$c/slot-$s
        for f in boot.itb boot.itb.prev; do echo "$c $s $f" > boot/$c/slot-$s/$f; done
      done
    done
  }
  run() { CARD_BOOT_RESET_MARKER=$PWD/marker CARD_BOOT_RESET_BOOT=$PWD/boot $bin > out; }
  # slot A listed: both cores' slot-A images go, slot B's stay, then the list
  mk; echo A > marker; run
  for c in arm riscv; do
    [ ! -e boot/$c/slot-A/boot.itb ] && [ ! -e boot/$c/slot-A/boot.itb.prev ] || fail "slot A kept on $c"
    [ -e boot/$c/slot-B/boot.itb ] || fail "slot B dropped on $c"
  done
  [ ! -e marker ] || fail "the list was kept"
  grep -q 'arm/slot-A' out || fail "nothing said"
  # both slots (A listed twice: a new eMMC USERDATA, then a new image)
  mk; printf 'A\nB\nA\n' > marker; run
  [ -z "$(find boot -type f)" ] || fail "an image of a listed slot was kept"
  # no list: nothing happens
  mk; run; [ "$(find boot -type f | wc -l)" = 8 ] || fail "dropped images without a list"
  # lines that name no slot are ignored
  mk; printf 'C\n../x\n*\n' > marker; run
  [ "$(find boot -type f | wc -l)" = 8 ] && [ ! -e marker ] || fail "a line that is no slot"
  touch $out
''
