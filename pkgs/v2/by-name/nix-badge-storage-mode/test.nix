# nix-badge-storage-mode against fake command lines and mount tables: the daemon's store
# line and the mode for case 1, case 2 and case 3 (slot A and B).
{ runCommand, nix-badge-storage-mode }:
runCommand "nix-badge-storage-mode-test" { } ''
  bin=${nix-badge-storage-mode}/bin/nix-badge-storage-mode
  fail() { echo "FAIL: $*"; cat run/* 2>/dev/null; exit 1; }
  root='29 1 179:35 / / ro - squashfs /dev/root ro'
  emmc='31 29 179:37 / /.userdata rw,nosuid,nodev,noatime - ext4 /dev/mmcblk1p5 rw'
  card='31 29 179:2 / /.userdata rw,nosuid,nodev,noatime - ext4 /dev/mmcblk0p2 rw
  40 29 179:37 / /.lower-userdata ro,nosuid,nodev,noatime - ext4 /dev/mmcblk1p5 ro'
  # go <cmdline> <mountinfo lines>
  go() {
    rm -rf run; printf '%s\n' "$1" > cmdline; printf '%s\n' "$root" "$2" > mountinfo
    STORAGE_MODE_CMDLINE=$PWD/cmdline STORAGE_MODE_MOUNTINFO=$PWD/mountinfo STORAGE_MODE_RUN=$PWD/run $bin \
      || fail "exit $? for $1"
  }
  case1='store = local-overlay://?lower-store=local%3Froot%3D%2Fnix%2F.ro-store%26read-only%3Dtrue&upper-layer=/.userdata/nix/upper'
  go 'init=/init-arm nixbadge.bootmedium=0 rauc.slot=A' "$emmc"
  [ "$(cat run/store.conf)" = "$case1" ] || fail "case 1 store"
  [ "$(cat run/storage)" = emmc ] || fail "case 1 mode"
  go 'init=/init-arm nixbadge.bootmedium=1 rauc.slot=A rauc.external' "$emmc"
  [ "$(cat run/store.conf)" = "$case1" ] && [ "$(cat run/storage)" = sd ] || fail "case 2"
  # case 3: tier2.sh's store_url_tier2 for the booted slot
  tier1() {
    printf 'local-overlay://?root=/nix/.lower-store&lower-store=local%%3Froot%%3D%%2Fnix%%2F.ro-store%%26read-only%%3Dtrue&upper-layer=/.lower-userdata/nix-%s/upper&check-mount=false' "$1" \
      | sed 's/%/%25/g; s/?/%3F/g; s/&/%26/g; s/=/%3D/g; s|/|%2F|g'
  }
  for s in A B; do
    go "init=/init-arm nixbadge.bootmedium=0 rauc.slot=$s nixbadge.datacard=1" "$card"
    [ "$(cat run/store.conf)" = "store = local-overlay://?lower-store=$(tier1 $s)&upper-layer=/.userdata/nix/upper" ] \
      || fail "case 3 slot $s store"
    [ "$(cat run/storage)" = 'card /dev/mmcblk0p2' ] || fail "case 3 mode"
  done
  # no rauc.slot=: slot A, as stage 0 does
  go 'init=/init-arm nixbadge.bootmedium=0 nixbadge.datacard=1' "$card"
  grep -q 'nix-A%2Fupper' run/store.conf || fail "case 3 without rauc.slot="
  touch $out
''
