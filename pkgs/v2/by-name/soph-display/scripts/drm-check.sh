#!/usr/bin/env bash
# Bring up the display stack and the KMS front end and check the DRM device,
# without a compositor.
set -u

say() { printf '\n=== %s ===\n' "$*"; }

say "1. vendor display stack"
soph-display-load-display || { echo "display stack failed to load"; exit 1; }

say "2. DISP timing actually programmed?"
# soph_drm refuses to probe if the DISP timing reads back as zeros.
if [ -r /sys/kernel/debug/soph_dispsrc/status ]; then
    grep -E 'timing|tgen' /sys/kernel/debug/soph_dispsrc/status || true
else
    echo "(no soph_dispsrc debugfs; continuing)"
fi

say "3. KMS front end"
modprobe soph_drm || { echo "soph_drm failed; dmesg:"; dmesg | tail -20; exit 1; }
dmesg | grep -iE 'sophdrm|soph_drm' | tail -10

say "4. DRM devices"
for c in /sys/class/drm/card*; do
    [ -e "$c/device/driver" ] || continue
    printf '%s -> %s\n' "$(basename "$c")" \
        "$(basename "$(readlink -f "$c/device/driver")")"
done
for c in /sys/class/drm/card*-*; do
    [ -d "$c" ] || continue
    printf '  %s: %s  modes: %s\n' "$(basename "$c")" \
        "$(cat "$c/status" 2>/dev/null)" "$(head -1 "$c/modes" 2>/dev/null)"
done

# Match on the driver name: card numbering is not stable.
CARD=
for c in /sys/class/drm/card*; do
    d=$(basename "$(readlink -f "$c/device/driver" 2>/dev/null)" 2>/dev/null)
    [ "$d" = "soph-drm" ] && CARD=/dev/dri/$(basename "$c")
done
[ -n "$CARD" ] || { echo "no soph-drm card found"; exit 1; }
say "5. our card is $CARD"

if command -v modetest >/dev/null 2>&1; then
    say "6. modetest -c (connectors/modes)"
    modetest -M sophdrm -c 2>&1 | head -30
    say "7. modetest -p (planes: expect ARGB8888 and ONLY ARGB8888)"
    modetest -M sophdrm -p 2>&1 | head -30
    say "8. drawing a test pattern for 10s -- LOOK AT THE HDMI OUTPUT"
    # The first connector modetest reports.
    CONN=$(modetest -M sophdrm -c 2>/dev/null | awk '/^[0-9]+\t/{print $1; exit}')
    MODE=$(modetest -M sophdrm -c 2>/dev/null | awk '/#0/{print $2; exit}')
    echo "connector=$CONN mode=$MODE"
    [ -n "$CONN" ] && timeout 12 modetest -M sophdrm -s "$CONN:$MODE" -v 2>&1 | tail -20
else
    echo "modetest not installed (pkgs.libdrm.bin) -- skipping draw test"
fi

say "done"
