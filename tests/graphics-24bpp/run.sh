#!/usr/bin/env bash
# Starts headless sway with ./sway.config, runs the cases against it, and prints
# PASS <case> or FAIL <case>: <why> for each. Exits non-zero on any FAIL. Every
# probe runs under a timeout, so a stuck sway or client fails the case instead of
# blocking the run.
set -u

here=$(dirname "$(readlink -f "$0")")
fails=0
pass() { echo "PASS $1${2:+: $2}"; }
fail() {
  echo "FAIL $1: $2"
  fails=$((fails + 1))
}

export HOME=$TMPDIR/home
export XDG_RUNTIME_DIR=$TMPDIR/xdg
export WAYLAND_DISPLAY=wayland-1
export SWAYSOCK=$XDG_RUNTIME_DIR/sway-ipc.sock
export SDL_VIDEODRIVER=wayland
mkdir -p "$HOME"
mkdir -m 0700 "$XDG_RUNTIME_DIR"

WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
  sway -c "$here/sway.config" > "$TMPDIR/sway.log" 2>&1 &
sway_pid=$!
client_pid=
trap 'kill $client_pid "$sway_pid" 2> /dev/null; wait 2> /dev/null' EXIT

ready() { [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] && [ -S "$SWAYSOCK" ]; }
for _ in $(seq 100); do
  ready && break
  kill -0 "$sway_pid" 2> /dev/null || break
  sleep 0.1
done
if ! ready; then
  echo "FAIL sway: no $WAYLAND_DISPLAY and IPC socket within 10 s"
  cat "$TMPDIR/sway.log"
  exit 1
fi

# shm-formats: the pixman renderer's texture formats are the wl_shm formats.
shm=$(timeout 10 wayland-info -i wl_shm 2>&1)
missing=
grep -qi '0x34324752' <<< "$shm" || missing="$missing RGB888 (0x34324752)"
grep -qi '0x34324742' <<< "$shm" || missing="$missing BGR888 (0x34324742)"
if [ -z "$missing" ]; then
  pass shm-formats
else
  fail shm-formats "wl_shm lacks$missing"
  echo "$shm"
fi

# The badge-graphics-check cases. Its window floats (sway.config), so it keeps
# the size it asks for: 640x360 unless --size says otherwise.
out=$TMPDIR/client.out
shot=$TMPDIR/shot.ppm

# Starts badge-graphics-check with the given arguments and waits up to 15 s for
# its "ready" line.
start_client() {
  timeout 30 badge-graphics-check "$@" > "$out" 2>&1 &
  client_pid=$!
  for _ in $(seq 150); do
    grep -qx ready "$out" && return 0
    kill -0 "$client_pid" 2> /dev/null || break
    sleep 0.1
  done
  return 1
}

# Waits for the client to exit; fails when it exits non-zero.
finish_client() {
  local status=0
  wait "$client_pid" || status=$?
  client_pid=
  return "$status"
}

# A key=value field from the client's output; -1 when it is missing.
field() {
  local v
  v=$(grep -o "\b$1=[^ ]*" "$out" | head -n1 | cut -d= -f2)
  echo "${v:--1}"
}

# The client's output on one line, for the log.
summary() { tr '\n' ' ' < "$out"; }

# "x y w h" of the client's window content, in output coordinates.
client_rect() {
  timeout 10 swaymsg -t get_tree | jq -r '
    .. | objects | select(.app_id? == "badge-graphics-check")
    | "\(.rect.x + .window_rect.x) \(.rect.y + .window_rect.y) \(.window_rect.width) \(.window_rect.height)"' |
    head -n1
}

# bars <c1> <c2> <c3>: takes a screenshot and probes the centre of each third
# of the client's window for the given colours. Prints why on failure.
bars() {
  local rect x y w h i=0 c px py why=
  sleep 0.5
  rect=$(client_rect)
  read -r x y w h <<< "$rect"
  if [ -z "${h:-}" ]; then
    echo "no badge-graphics-check window in the sway tree"
    return 1
  fi
  if ! timeout 10 grim -t ppm "$shot"; then
    echo "grim failed"
    return 1
  fi
  for c in "$@"; do
    px=$((x + (2 * i + 1) * w / 6))
    py=$((y + h / 2))
    timeout 10 python3 "$here/probe.py" "$shot" "$px" "$py" "$c" > "$TMPDIR/probe.out" 2>&1 ||
      why="$why bar $i: $(cat "$TMPDIR/probe.out");"
    i=$((i + 1))
  done
  [ -z "$why" ] && return 0
  echo "window $w x $h at $x,$y:$why"
  return 1
}

# copy_case <name> <SDL format> <c1> <c2> <c3>: 60 frames in copy mode; the last
# one (59, odd) is what the bars show.
copy_case() {
  local name=$1 format=$2 why=
  shift 2
  if ! start_client --format "$format" --frames 60 --hold 3; then
    fail "$name" "client not ready: $(cat "$out")"
    finish_client
    return
  fi
  [ "$(field format)" = "$format" ] || why="$why format is $(field format);"
  [ $(($(field pitch) % 12)) = 0 ] || why="$why pitch $(field pitch) is not a multiple of 12;"
  [ "$(field persist)" = ok ] || why="$why persist=$(field persist);"
  why="$why$(bars "$@")"
  finish_client || why="$why client exited non-zero: $(cat "$out");"
  if [ -z "$why" ]; then pass "$name" "$(summary)"; else fail "$name" "$why"; fi
}

copy_case A SDL_PIXELFORMAT_BGR24 b g r
copy_case B SDL_PIXELFORMAT_RGB24 b g r

# C: 61 no-copy updates back to back. Every update hands back another buffer, and
# the last frame drawn (60, even) is the one on screen.
why=
if start_client --format SDL_PIXELFORMAT_BGR24 --no-copy --frames 61 --hold 3; then
  [ "$(field pointer-swaps)" -ge 60 ] || why="$why pointer-swaps=$(field pointer-swaps);"
  why="$why$(bars r g b)"
  finish_client || why="$why client exited non-zero: $(cat "$out");"
else
  why="client not ready: $(cat "$out")"
  finish_client
fi
if [ -z "$why" ]; then pass C "$(summary)"; else fail C "$why"; fi

# D: a 641 px wide 24bpp window, whose 1923-byte rows need padding to a stride
# both wl_shm (multiple of 3) and pixman (multiple of 4) take.
why=
if start_client --format SDL_PIXELFORMAT_BGR24 --size 641x361 --frames 2 --hold 3; then
  pitch=$(field pitch)
  [ $((pitch % 12)) = 0 ] || why="$why pitch $pitch is not a multiple of 12;"
  [ "$pitch" -ge 1923 ] || why="$why pitch $pitch is under 641 * 3;"
  why="$why$(bars b g r)"
  finish_client || why="$why client exited non-zero: $(cat "$out");"
else
  why="client not ready: $(cat "$out")"
  finish_client
fi
if [ -z "$why" ]; then pass D "$(summary)"; else fail D "$why"; fi

# E: case A, then sway resizes the window under the client's framebuffer.
why=
if start_client --format SDL_PIXELFORMAT_BGR24 --frames 60 --hold 6; then
  timeout 10 swaymsg '[app_id=badge-graphics-check] resize set 400 300' > /dev/null ||
    why="$why swaymsg resize failed;"
  sleep 1
  read -r _ _ w h <<< "$(client_rect)"
  [ "${w:-}x${h:-}" = 400x300 ] || why="$why window is ${w:-?}x${h:-?}, not 400x300;"
  # A redraw at the new size, not the old buffer scaled into the new rect.
  grep -q '^redraw .* w=400 h=300$' "$out" || why="$why no redraw at 400x300;"
  why="$why$(bars b g r)"
  kill -0 "$client_pid" 2> /dev/null || why="$why client died after the resize;"
  finish_client || why="$why client exited non-zero: $(cat "$out");"
else
  why="client not ready: $(cat "$out")"
  finish_client
fi
if [ -z "$why" ]; then pass E "$(summary)"; else fail E "$why"; fi

# fullscreen: what the badge's 1280x720 desktop gets, a pitch with no padding.
why=
if start_client --format SDL_PIXELFORMAT_BGR24 --fullscreen --frames 60 --hold 3; then
  [ "$(field w)x$(field h) $(field pitch)" = "1280x720 3840" ] ||
    why="$why $(field w)x$(field h) pitch $(field pitch), not 1280x720 pitch 3840;"
  why="$why$(bars b g r)"
  finish_client || why="$why client exited non-zero: $(cat "$out");"
else
  why="client not ready: $(cat "$out")"
  finish_client
fi
if [ -z "$why" ]; then pass fullscreen "$(summary)"; else fail fullscreen "$why"; fi

# The output's current mode, WxH.
output_mode() {
  timeout 10 swaymsg -t get_outputs | jq -r '.[0].current_mode | "\(.width)x\(.height)"'
}

# mode-switch: an exclusive fullscreen request near 640x360 with real mode switching
# on. A headless output has no real modes, so SDL emulates the mode: the window is
# that size, and the output and SDL's modes stay 1280x720 throughout.
why=
export SDL_VIDEO_WAYLAND_MODE_SWITCH=1
if start_client --fullscreen-mode 640x360 --hold 1; then
  during=$(output_mode)
  [ "$during" = 1280x720 ] || why="$why output is $during during fullscreen;"
  [ "$(field w)x$(field h)" = "$(field fullscreen-mode)" ] ||
    why="$why window is $(field w)x$(field h), not the $(field fullscreen-mode) mode;"
  [ "$(field mode-before)" = 1280x720 ] || why="$why mode-before=$(field mode-before);"
  # The output keeps its mode, so the display's current mode does too.
  [ "$(field mode-during)" = 1280x720 ] || why="$why mode-during=$(field mode-during);"
  [ "$(field desktop-mode)" = 1280x720 ] || why="$why desktop-mode=$(field desktop-mode);"
  finish_client || why="$why client exited non-zero: $(cat "$out");"
  [ "$(field mode-after)" = 1280x720 ] || why="$why mode-after=$(field mode-after);"
  after=$(output_mode)
  [ "$after" = 1280x720 ] || why="$why output is $after afterwards;"
else
  why="client not ready: $(cat "$out")"
  finish_client
fi
unset SDL_VIDEO_WAYLAND_MODE_SWITCH
if [ -z "$why" ]; then pass mode-switch "$(summary)"; else fail mode-switch "$why"; fi

if [ "$fails" != 0 ]; then
  echo "--- sway log"
  cat "$TMPDIR/sway.log"
  exit 1
fi
