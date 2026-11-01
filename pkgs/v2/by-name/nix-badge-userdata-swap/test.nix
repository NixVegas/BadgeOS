# nix-badge-userdata-swap with stand-ins for fallocate and mkswap: an allocation that runs
# out of room leaves no partial file behind (it would fill USERDATA), a good one makes a
# 0600 file and formats it, and a file of the right size is only formatted.
{ runCommand, nix-badge-userdata-swap }:
runCommand "nix-badge-userdata-swap-test" { } ''
  bin=${nix-badge-userdata-swap}/bin/nix-badge-userdata-swap
  fail() { echo "FAIL: $*"; ls -la; cat calls 2>/dev/null; exit 1; }
  # A fallocate that runs out of room after part of the file, as ext4's does.
  printf '#!%s\ntruncate -s 3M "$3"; echo fallocate >> %s/calls; exit 1\n' "$BASH" "$PWD" > short
  printf '#!%s\ntruncate -s "$2" "$3"; echo fallocate >> %s/calls\n' "$BASH" "$PWD" > room
  printf '#!%s\necho "mkswap $*" >> %s/calls\n' "$BASH" "$PWD" > mkswap
  chmod +x short room mkswap
  go() { SWAP_FALLOCATE=$PWD/$1 SWAP_MKSWAP=$PWD/mkswap $bin "$PWD/swap" 8; }

  rc=0; go short 2> err || rc=$?
  [ "$rc" != 0 ] || fail "a failed allocation exited 0"
  [ ! -e swap ] || fail "a failed allocation left $(stat -c %s swap) bytes behind"
  grep -q "no room for the 8 MiB swap file" err || fail "no message for the failed allocation"
  ! grep -q mkswap calls || fail "mkswap ran without a swap file"

  : > calls; go room || fail "exit $? with room"
  [ "$(stat -c %s swap)" = $(( 8 * 1048576 )) ] || fail "the swap file is $(stat -c %s swap) bytes"
  [ "$(stat -c %a swap)" = 600 ] || fail "the swap file is mode $(stat -c %a swap)"
  [ "$(cat calls)" = "$(printf 'fallocate\nmkswap %s' "$PWD/swap")" ] || fail "calls with room"

  : > calls; go short || fail "exit $? for an existing swap file"
  [ "$(cat calls)" = "mkswap $PWD/swap" ] || fail "an existing swap file was reallocated"

  # Without a size: 256 MiB on the eMMC's own USERDATA, 512 MiB on an SD card's (booted
  # from it, or a data card's, where the eMMC's sits read-only at /.lower-userdata).
  printf '22 1 179:5 / /.userdata rw - ext4 /dev/mmcblk1p5 rw\n' > emmc.mi
  { cat emmc.mi; printf '34 30 179:37 / /.lower-userdata ro - ext4 /dev/mmcblk1p5 ro\n'; } > card.mi
  sized() { # sized <bootmedium> <mountinfo> <MiB>
    rm -f swap; : > calls
    NIXBADGE_BOOTMEDIUM=$1 SWAP_MOUNTINFO=$PWD/$2 SWAP_FALLOCATE=$PWD/room SWAP_MKSWAP=$PWD/mkswap \
      $bin "$PWD/swap" || fail "exit $? for medium $1 with $2"
    [ "$(stat -c %s swap)" = $(( $3 * 1048576 )) ] || fail "medium $1 with $2: $(stat -c %s swap) bytes, not $3 MiB"
  }
  sized 0 emmc.mi 256
  sized 0 card.mi 512
  sized 1 emmc.mi 512
  sized "" emmc.mi 512
  # a 512 MiB file from before is remade at 256 on the eMMC
  sized 1 emmc.mi 512; NIXBADGE_BOOTMEDIUM=0 SWAP_MOUNTINFO=$PWD/emmc.mi SWAP_FALLOCATE=$PWD/room \
    SWAP_MKSWAP=$PWD/mkswap $bin "$PWD/swap" || fail "exit $? shrinking"
  [ "$(stat -c %s swap)" = $(( 256 * 1048576 )) ] || fail "the old 512 MiB file was kept"
  touch $out
''
