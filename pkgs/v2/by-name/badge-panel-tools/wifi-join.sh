export LC_ALL=C
while true; do
    printf '\nAvailable WiFi networks:\n'
    if ! nmcli -f SSID,SIGNAL,SECURITY device wifi list --rescan yes ifname wlan0; then
        printf '\nScan failed. Press Enter to retry, or Close to leave.\n'
        read -r _ || exit 0
        continue
    fi
    printf '\nNetwork name (blank to leave): '
    IFS= read -r ssid || exit 0
    [[ -n $ssid ]] || exit 0
    if nmcli --ask device wifi connect "$ssid" ifname wlan0; then
        printf '\nConnected. Press Enter or Close to return.\n'
        read -r _ || true
        exit 0
    fi
    printf '\nCould not connect. Press Enter to retry, or Close to leave.\n'
    read -r _ || exit 0
done
