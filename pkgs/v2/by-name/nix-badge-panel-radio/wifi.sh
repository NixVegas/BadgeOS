case "${1:-}" in
    on)
        # The unit's start limit bounds the wait.
        udevadm wait --initialized=yes /sys/class/net/wlan0
        trap 'if (( $? != 0 )); then nmcli radio wifi off || true; fi' EXIT
        trap 'exit 1' HUP INT TERM
        # Install one flow table before link-up can allocate 257 per-queue tables.
        tc qdisc replace dev wlan0 root fq_codel
        nmcli radio wifi on
        while :; do
            state=$(LC_ALL=C nmcli -g GENERAL.STATE device show wlan0)
            case "$state" in
                30*|100*)
                    exit 0
                    ;;
            esac
            sleep 1
        done
        ;;
    off) nmcli radio wifi off ;;
    *) echo 'Usage: nix-badge-panel-radio-wifi on|off' >&2; exit 2 ;;
esac
