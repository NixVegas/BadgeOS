# badge-game COMMAND [ARGS...]: runs a game, then puts the HDMI output back in
# $BADGE_OUTPUT_MODE, however the game ended.

if [ "$#" -eq 0 ]; then
  echo "usage: badge-game COMMAND [ARGS...]" >&2
  exit 2
fi

restore() {
  if [ -n "${SWAYSOCK:-}" ]; then
    swaymsg output HDMI-A-1 mode "$BADGE_OUTPUT_MODE" > /dev/null || true
  fi
}

# HUP, INT and TERM stop the game before the mode is restored, with KILL after a
# few seconds for a game that ignores TERM.
game=
stop() {
  # A signal can arrive after the game started but before game= ran.
  game=${game:-${!:-}}
  if [ -n "$game" ]; then
    kill -TERM "$game" 2> /dev/null || true
    for _ in $(seq 30); do
      kill -0 "$game" 2> /dev/null || break
      sleep 0.1
    done
    if kill -0 "$game" 2> /dev/null; then
      kill -KILL "$game" 2> /dev/null || true
    fi
    wait "$game" || true
  fi
  exit "$1"
}

trap restore EXIT
trap 'stop 129' HUP
trap 'stop 130' INT
trap 'stop 143' TERM

# A child rather than exec, so the traps outlive the game. A background job
# would get /dev/null as stdin; <&0 keeps ours.
"$@" <&0 &
game=$!
status=0
wait "$game" || status=$?
exit "$status"
