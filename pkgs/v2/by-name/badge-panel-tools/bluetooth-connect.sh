[[ $# == 1 && $1 =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] || exit 2
state_dir=${XDG_RUNTIME_DIR:?}/badge-bluetooth
install -d -m 700 "$state_dir"
cleanup() {
    if [[ -r $state_dir/connecting ]]; then
        read -r owner < "$state_dir/connecting"
        if [[ $owner == "$$" ]]; then rm -f "$state_dir/connecting"; fi
    fi
    badge-panel-bluetooth-audio-state || true
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
if [[ $BADGE_BLUETOOTH_AUDIO == 1 ]] && badge-panel-bluetooth-audio-device "$1"; then
    printf '%s\n' "$$" > "$state_dir/connecting"
    systemctl --user start pipewire.service pipewire-pulse.socket
    # The start is done once the session's services have started, which is some
    # seconds before they have registered their endpoints with BlueZ, and a connect made
    # in between fails with "Protocol not available". The controller lists the audio
    # services among its own once the endpoints are there.
    deadline=$((SECONDS + 20))
    until [[ $(LC_ALL=C bluetoothctl show) =~ 0000110[ab]-0000-1000-8000-00805f9b34fb ]]; do
        (( SECONDS < deadline )) || break
        sleep 1
    done
fi
timeout 45 bluetoothctl connect "$1"
