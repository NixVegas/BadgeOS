# nix-badge-stable-mac IFACE: give IFACE the vendor OUI and three bytes of
# sha256(machine-id), stable per badge and distinct across badges. Without a machine-id
# it leaves IFACE alone.
if [ $# -ne 1 ]; then
  echo "usage: nix-badge-stable-mac IFACE" >&2
  exit 2
fi
iface=$1
machine_id=${STABLE_MAC_MACHINE_ID:-/etc/machine-id}
ip=${STABLE_MAC_IP:-ip}
[ -r "$machine_id" ] || exit 0
id=$(cat "$machine_id")
# Domain-separated so this never collides with another use of machine-id.
h=$(printf '%s' "aic8800-wlan-mac-v1:$id" | sha256sum | cut -c1-6)
mac="88:00:33:${h:0:2}:${h:2:2}:${h:4:2}"
# Setting a MAC needs the link down; udev runs before NM claims the device.
"$ip" link set dev "$iface" down 2>/dev/null || true
"$ip" link set dev "$iface" address "$mac"
"$ip" link set dev "$iface" up 2>/dev/null || true
