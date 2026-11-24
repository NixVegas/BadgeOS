export LC_ALL=C
# Reading Settings must not activate BlueZ or load the driver.
if ! systemctl --quiet is-active badge-panel-bluetooth.service; then
    printf 'off\nOff\n'
elif ! systemctl --quiet is-active bluetooth.service; then
    printf 'waiting\nStarting Bluetooth…\n'
else
    info=$(bluetoothctl show)
    if [[ $info == *'Powered: yes'* ]]; then
        devices=$(bluetoothctl devices Connected)
        if [[ -n $devices ]]; then printf 'on\nConnected\n'; else printf 'on\nNot connected\n'; fi
    else
        printf 'off\nOff\n'
    fi
fi
