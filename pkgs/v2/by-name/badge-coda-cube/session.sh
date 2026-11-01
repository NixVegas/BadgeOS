#!/usr/bin/env bash
# session USER: coda-cube on USER's sway session. It starts as root for the
# decoder, /dev/soph-ion and soph_drm's colour parameters, and drops to USER
# (--user) before it connects to the compositor's socket.
set -euo pipefail
PATH=@path@

user=$1
uid=$(id -u "$user")
export XDG_RUNTIME_DIR=/run/user/$uid
WAYLAND_DISPLAY=
for s in "$XDG_RUNTIME_DIR"/wayland-*; do
	case $s in *.lock) continue ;; esac
	if [ -S "$s" ] && [ "$(stat -c %u "$s")" = "$uid" ]; then
		WAYLAND_DISPLAY=${s##*/}
	fi
done
if [ -z "$WAYLAND_DISPLAY" ]; then
	echo "badge-coda-cube: $user has no Wayland socket in $XDG_RUNTIME_DIR" >&2
	exit 1
fi
export WAYLAND_DISPLAY SDL_VIDEODRIVER=wayland
# The demo: decoder frames scanned out as they are, with the anti-aliased
# edges and the loop filter (the best picture), paced on the display.
exec coda-cube --user "$user" --zero-copy --pipeline --aa --deblock
