# 2 while the output runs half its largest mode, as the bar's Half, otherwise 1.
# Callers divide by this, so print a number even when there is no such output or no
# compositor to ask: fall back to 1, leaving swaymsg's own message on stderr.
scale=$(swaymsg -rt get_outputs | jq -r --arg name "$BADGE_OUTPUT_NAME" \
    '.[] | select(.name == $name) | (.modes | max_by([.width, .height])) as $full
     | if .current_mode.width * 2 == $full.width and .current_mode.height * 2 == $full.height
       then 2 else 1 end') || true
printf '%s\n' "${scale:-1}"
