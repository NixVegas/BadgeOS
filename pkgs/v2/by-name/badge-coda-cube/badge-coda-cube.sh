#!/usr/bin/env bash
# The CODA980 cube, fullscreen on this sway session. ESC in its window, or Ctrl-C
# here, quits; `badge-coda-cube stop` stops it from anywhere in the session.
set -euo pipefail
PATH=@path@

unit="badge-coda-cube@$(id -un).service"
if [ "${1:-}" = stop ]; then
	exec systemctl stop "$unit"
fi
if [ $# -gt 0 ]; then
	echo "usage: badge-coda-cube [stop]" >&2
	exit 2
fi

journalctl --follow --lines=0 --output=cat --unit="$unit" &
log=$!
trap 'kill "$log" 2>/dev/null || true' EXIT
trap 'systemctl stop "$unit"; exit 130' INT TERM HUP
systemctl start "$unit"
while systemctl --quiet is-active "$unit"; do
	sleep 1
done
result=$(systemctl show --property=Result --value "$unit")
if [ "$result" != success ]; then
	echo "badge-coda-cube: $unit ended: $result" >&2
	exit 1
fi
