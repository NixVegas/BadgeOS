# crispy-doom through badge-game, in the badge's video settings. crispy-doom reads
# its fullscreen mode only from its extended config, so this runs it on its own
# copy, badge-doom.cfg, with the $BADGE_DOOM_DEFAULTS keys set before each launch.

merge_defaults() {
  local defaults=$1 config=$2 keys
  if [ ! -e "$config" ]; then
    cp "$defaults" "$config"
  fi
  keys=$(cut -d ' ' -f 1 "$defaults" | paste -sd '|')
  {
    grep -Ev "^($keys)[[:space:]]" "$config" || [ "$?" -eq 1 ]
    cat "$defaults"
  } > "$config.new"
  mv "$config.new" "$config"
}

if [ "${BADGE_PANEL_TOUCH:-0}" = 1 ]; then
  dir=${XDG_DATA_HOME:-$HOME/.local/share}/badge-panel-doom
  mkdir -p "$dir/save"
  config=$dir/crispy-doom.cfg
  merge_defaults "$BADGE_DOOM_DEFAULTS" "$config"
  merge_defaults "$BADGE_DOOM_KEYS" "$dir/default.cfg"
  if [ ! -S "${XDG_RUNTIME_DIR:-}/pulse/native" ] && [ -z "${SDL_AUDIODRIVER:-}" ]; then
    set -- -nosound "$@"
  fi
  # A window as large as the output, which the hidden bar leaves to the game.
  read -r width height < <(swaymsg -rt get_outputs |
    jq -r --arg name "$BADGE_DOOM_OUTPUT" \
      '.[] | select(.name == $name) | .rect | "\(.width) \(.height)"')
  set -- -width "$width" -height "$height" "$@"
  exec badge-game crispy-doom -iwad "$DOOMWADDIR/freedoom2.wad" -config "$dir/default.cfg" \
    -extraconfig "$config" -savedir "$dir/save" -warp 1 "$@"
fi

dir=${XDG_DATA_HOME:-$HOME/.local/share}/crispy-doom
config=$dir/badge-doom.cfg
mkdir -p "$dir"
if [ ! -e "$config" ]; then
  cp "$dir/crispy-doom.cfg" "$config" 2> /dev/null || : > "$config"
fi

keys=$(cut -d ' ' -f 1 "$BADGE_DOOM_DEFAULTS" | paste -sd '|')
{
  grep -Ev "^($keys)[[:space:]]" "$config" || [ "$?" -eq 1 ]
  cat "$BADGE_DOOM_DEFAULTS"
} > "$config.new"
mv "$config.new" "$config"

exec badge-game crispy-doom -extraconfig "$config" "$@"
