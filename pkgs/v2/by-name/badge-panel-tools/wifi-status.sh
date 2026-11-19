export LC_ALL=C
if [[ ! -d /sys/class/net/wlan0 || $(nmcli radio wifi) != enabled ]]; then
    printf 'off\nOff\n'
else
    state=$(nmcli -g GENERAL.STATE device show wlan0)
    case "$state" in
        100*) printf 'on\nConnected\n' ;;
        30*) printf 'on\nNot connected\n' ;;
        *) printf 'waiting\nGetting ready…\n' ;;
    esac
fi
