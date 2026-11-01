# nix-badge-net-scan IFACE: the OLED scan screens' feed in /run/nix-badge. wifi-scan has
# "<dBm>\t<SSID>" for the 8 strongest networks IFACE sees; with Bluetooth, bt-scan has
# "<last two octets>|<RSSI>\t<name>" for the 8 strongest devices. A half that fails still
# leaves its (possibly empty) file.
if [ $# -ne 1 ]; then
  echo "usage: nix-badge-net-scan IFACE" >&2
  exit 2
fi
iface=$1
dir=${NET_SCAN_DIR:-/run/nix-badge}
iw=${NET_SCAN_IW:-iw}
bluetoothctl=${NET_SCAN_BLUETOOTHCTL:-bluetoothctl}
umask 022
mkdir -p "$dir"
TAB="$(printf '\t')"

# WiFi: only each BSS's first SSID, as deeper SSID-list fields would clobber it.
wifi_tmp="$(mktemp "$dir/wifi-scan.XXXXXX")"
{
  timeout 15 "$iw" dev "$iface" scan 2>/dev/null | awk '
    function emit(   name) {
      name = ssid;
      gsub(/[ \t]+$/, "", name);
      if (name == "") name = "<hidden>";
      printf "%d\t%.18s\n", sig, name;
    }
    /^BSS / { if (seen) emit(); seen = 1; sig = -99; ssid = ""; havessid = 0; }
    /^[ \t]+signal:/ {
      v = $0; sub(/^[ \t]+signal:[ \t]*/, "", v); sub(/[ \t].*$/, "", v);
      sig = int(v);
    }
    /^[ \t]+SSID:/ {
      if (!havessid) { s = $0; sub(/^[ \t]+SSID:[ \t]?/, "", s); ssid = s; havessid = 1; }
    }
    END { if (seen) emit(); }
  ' | sort -t"$TAB" -k1,1nr | head -n 8
} > "$wifi_tmp" || true
mv -f "$wifi_tmp" "$dir/wifi-scan"

[ "${NET_SCAN_BLUETOOTH:-}" = 1 ] || exit 0

# Bluetooth: `devices` has no RSSI, so it comes from `info`.
bt_tmp="$(mktemp "$dir/bt-scan.XXXXXX")"
{
  "$bluetoothctl" --timeout 10 scan on >/dev/null 2>&1 || true
  "$bluetoothctl" devices 2>/dev/null | while read -r _kw addr rest; do
    case "$addr" in
      *:*:*:*:*:*) : ;;
      *) continue ;;
    esac
    last2="$(printf '%s\n' "$addr" | awk -F: '{ print $(NF-1)":"$NF }')"
    rssi="$("$bluetoothctl" info "$addr" 2>/dev/null \
      | awk '/RSSI:/ { for (i=1;i<=NF;i++) if ($i ~ /^-?[0-9]+$/) { print $i; exit } }')"
    [ -n "$rssi" ] || rssi="?"
    name="$rest"
    [ -n "$name" ] || name="<unknown>"
    # Numeric sort key first (unknown RSSI sorts last), stripped after sorting.
    key="$rssi"
    case "$key" in -[0-9]*|[0-9]*) : ;; *) key="-9999" ;; esac
    printf '%s\t%s|%s\t%.18s\n' "$key" "$last2" "$rssi" "$name"
  done | sort -t"$TAB" -k1,1nr | head -n 8 | awk -F"$TAB" '{ print $2 "\t" $3 }'
} > "$bt_tmp" || true
mv -f "$bt_tmp" "$dir/bt-scan"
