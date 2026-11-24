set -euo pipefail
for card in /sys/class/drm/card[0-9]*; do
    name=${card##*/}
    [[ $name =~ ^card[0-9]+$ ]] || continue
    driver=$(readlink -f "$card/device/driver") || continue
    test "${driver##*/}" = soph-drm || continue
    test -c "/dev/dri/$name" || continue
    if test -e "$DRM_DEVICE" || test -L "$DRM_DEVICE"; then
        test "$(readlink -f "$DRM_DEVICE")" = "/dev/dri/$name"
    else
        # udev may publish the same link between the check and creation.
        ln -s "/dev/dri/$name" "$DRM_DEVICE" 2>/dev/null ||
            test "$(readlink -f "$DRM_DEVICE")" = "/dev/dri/$name"
    fi
    exit 0
done
echo 'The panel DRM card is missing after its driver loaded' >&2
exit 1
