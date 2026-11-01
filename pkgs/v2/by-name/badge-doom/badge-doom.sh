# crispy-doom through badge-game, in the badge's video settings. crispy-doom reads
# its fullscreen mode only from its extended config, so this runs it on its own
# copy, badge-doom.cfg, with the $BADGE_DOOM_DEFAULTS keys set before each launch.

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
