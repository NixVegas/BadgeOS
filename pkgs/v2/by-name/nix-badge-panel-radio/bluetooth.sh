case "${1:-}" in
    on)
        bluetoothctl power on
        bluetoothctl pairable off
        bluetoothctl discoverable off
        ;;
    off)
        if systemctl --quiet is-active bluetooth.service; then
            bluetoothctl power off
        fi
        ;;
    *) echo 'Usage: nix-badge-panel-radio-bluetooth on|off' >&2; exit 2 ;;
esac
