# nix-badge-stable-mac against a fake ip: the link goes down, gets the address derived
# from the machine-id, and comes back up; without a machine-id nothing is touched.
{ runCommand, nix-badge-stable-mac }:
runCommand "nix-badge-stable-mac-test" { } ''
  bin=${nix-badge-stable-mac}/bin/nix-badge-stable-mac
  fail() { echo "FAIL: $*"; cat calls 2>/dev/null; exit 1; }
  printf '#!%s\necho "$*" >> %s/calls\n' "$BASH" "$PWD" > ip
  chmod +x ip
  export STABLE_MAC_IP=$PWD/ip STABLE_MAC_MACHINE_ID=$PWD/machine-id
  $bin wlan0; [ ! -e calls ] || fail "changed the link without a machine-id"
  echo 0123456789abcdef0123456789abcdef > machine-id
  $bin wlan0
  want=$(printf '%s\n' "link set dev wlan0 down" "link set dev wlan0 address 88:00:33:80:3e:91" "link set dev wlan0 up")
  [ "$(cat calls)" = "$want" ] || fail "the link calls"
  rc=0; $bin 2>/dev/null || rc=$?; [ $rc = 2 ] || fail "usage"
  touch $out
''
