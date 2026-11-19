[[ $BADGE_BLUETOOTH_AUDIO == 1 ]] || exit 0
if systemctl --quiet is-active badge-panel-bluetooth.service; then
    devices=$(LC_ALL=C bluetoothctl devices Connected)
    while read -r kind address _; do
        [[ $kind == Device ]] || continue
        if badge-panel-bluetooth-audio-device "$address"; then
            systemctl --user start pipewire.service pipewire-pulse.socket
            exit 0
        fi
    done <<< "$devices"
    # The selected audio device needs endpoints before its Connect call, while it runs.
    marker=${XDG_RUNTIME_DIR:?}/badge-bluetooth/connecting
    if [[ -r $marker ]] && read -r owner < "$marker" && kill -0 "$owner" 2>/dev/null; then exit 0; fi
fi
systemctl --user stop pipewire.socket pipewire-pulse.socket
