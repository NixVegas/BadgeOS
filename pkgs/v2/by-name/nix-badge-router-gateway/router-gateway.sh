# nix-badge-router-gateway [--reload] UPLINK ADDRESS FILE: dnsmasq's DHCP options for the
# router's LAN. While UPLINK has a default route the badge (ADDRESS) is the gateway and
# DNS server; otherwise neither is offered. FILE is rewritten only when that changes,
# and --reload then has dnsmasq re-read it.
reload=0
if [ "${1:-}" = --reload ]; then
  reload=1
  shift
fi
if [ $# -ne 3 ]; then
  echo "usage: nix-badge-router-gateway [--reload] UPLINK ADDRESS FILE" >&2
  exit 2
fi
uplink=$1 address=$2 file=$3

if [ -n "${ROUTER_GATEWAY_ROUTES:-}" ]; then
  routes=$(cat "$ROUTER_GATEWAY_ROUTES")
else
  routes=$(ip -4 route show default)
fi

if printf '%s\n' "$routes" | awk -v dev="$uplink" '
  { for (i = 1; i < NF; i++) if ($i == "dev" && $(i + 1) == dev) found = 1 }
  END { exit !found }'; then
  want=$(printf 'option:router,%s\noption:dns-server,%s' "$address" "$address")
else
  want=$(printf 'option:router\noption:dns-server')
fi

if [ -f "$file" ] && [ "$(cat "$file")" = "$want" ]; then
  exit 0
fi

tmp=$(mktemp "$file.XXXXXX")
printf '%s\n' "$want" > "$tmp"
chmod 0644 "$tmp"
mv -f "$tmp" "$file"

# dnsmasq reads the file when it starts, so one that isn't running needs no signal.
if [ "$reload" = 1 ]; then
  "${ROUTER_GATEWAY_SYSTEMCTL:-systemctl}" kill --kill-whom=main --signal=SIGHUP dnsmasq.service || true
fi
