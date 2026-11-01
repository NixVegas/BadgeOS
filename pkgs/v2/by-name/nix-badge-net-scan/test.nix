# nix-badge-net-scan against a fake iw and bluetoothctl: the strongest networks and
# devices first, hidden and unnamed ones labelled, names cut to 18 characters, and no
# Bluetooth file without Bluetooth.
{ runCommand, nix-badge-net-scan }:
let
  scan =
    withBluetooth: "${nix-badge-net-scan.override { inherit withBluetooth; }}/bin/nix-badge-net-scan";
in
runCommand "nix-badge-net-scan-test" { } ''
  fail() { echo "FAIL: $*"; for f in out/*; do echo "== $f"; cat "$f"; done; exit 1; }
  printf '%s\n' \
    'BSS 00:11:22:33:44:55(on wlan0)' $'\tsignal: -70.00 dBm' $'\tSSID: alpha' \
    'BSS 00:11:22:33:44:66(on wlan0)' $'\tsignal: -40.00 dBm' $'\tSSID: ' \
    'BSS 00:11:22:33:44:77(on wlan0)' $'\tsignal: -55.00 dBm' \
    $'\tSSID: a-very-long-network-name' $'\tSSID: second' > iw-out
  printf '#!%s\n[ "$*" = "dev wlan0 scan" ] && cat %s/iw-out\n' "$BASH" "$PWD" > iw
  printf '#!%s\n%s\n' "$BASH" '
    case "$1" in
      devices) printf "%s\n" "Device AA:BB:CC:DD:EE:01 Phone" "Device AA:BB:CC:DD:EE:02" "Device AA:BB:CC:DD:EE:03 Watch" "Controller 11:22" ;;
      info) case "$2" in *:01) printf "\tRSSI: -60\n" ;; *:02) printf "\tRSSI: -30\n" ;; esac ;;
    esac' > bluetoothctl
  chmod +x iw bluetoothctl
  export NET_SCAN_DIR=$PWD/out NET_SCAN_IW=$PWD/iw NET_SCAN_BLUETOOTHCTL=$PWD/bluetoothctl

  ${scan false} wlan0
  [ "$(cat out/wifi-scan)" = "$(printf '%s\t%s\n' -40 '<hidden>' -55 a-very-long-networ -70 alpha)" ] \
    || fail "the WiFi networks"
  [ ! -e out/bt-scan ] || fail "a Bluetooth scan without Bluetooth"

  ${scan true} wlan0
  [ "$(cat out/bt-scan)" = "$(printf '%s\t%s\n' 'EE:02|-30' '<unknown>' 'EE:01|-60' Phone 'EE:03|?' Watch)" ] \
    || fail "the Bluetooth devices"

  NET_SCAN_IW=false ${scan false} wlan0
  [ -e out/wifi-scan ] && [ ! -s out/wifi-scan ] || fail "a failed WiFi scan leaves no empty file"
  rc=0; ${scan false} 2>/dev/null || rc=$?; [ $rc = 2 ] || fail "usage"
  touch $out
''
