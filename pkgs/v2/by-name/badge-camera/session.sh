#!/usr/bin/env bash
# session USER: the camera on USER's sway session. It starts as root for the camera
# devices and drops to USER (--user) before it connects to the compositor's socket.
set -euo pipefail
PATH=@path@

user=$1
shift
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
	echo "badge-camera: $user has no Wayland socket in $XDG_RUNTIME_DIR" >&2
	exit 1
fi
export WAYLAND_DISPLAY SDL_VIDEODRIVER=wayland
exec badge-camera --user "$user" "$@"
