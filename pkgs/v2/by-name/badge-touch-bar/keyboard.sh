# Half size while the output runs half its largest mode, as the bar does.
scale=$(badge-output-scale)
exec wvkbd-mobintl --hidden -H "$((140 / scale))" -L "$((140 / scale))" --fn "$BADGE_FONT $((12 / scale))"
