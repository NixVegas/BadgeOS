export LC_ALL=C
systemctl --quiet is-active badge-panel-bluetooth.service || {
    echo 'Turn Bluetooth on in Settings first.'
    read -r _ || true
    exit 1
}
umask 077
work=$(mktemp -d "${XDG_RUNTIME_DIR:?}/badge-bluetooth.XXXXXX")
cleanup() {
    rm -f "$work/pair"
    rmdir "$work"
}
trap cleanup EXIT
trap 'exit 0' HUP INT TERM

pause() { printf '\nPress Enter to return. '; read -r _ || true; }
while true; do
    printf '\nBluetooth devices\n'
    addresses=()
    names=()
    while IFS= read -r line; do
        if [[ $line =~ ^Device\ ([[:xdigit:]:]{17})\ (.*)$ ]]; then
            addresses+=("${BASH_REMATCH[1]}")
            names+=("$(printf '%s' "${BASH_REMATCH[2]}" | tr -d '\000-\037\177')")
        fi
    done < <(bluetoothctl devices)
    for i in "${!addresses[@]}"; do printf '%d. %s (%s)\n' "$((i+1))" "${names[i]}" "${addresses[i]}"; done
    printf '\nDevice number, R to scan, or Enter to leave: '
    IFS= read -r choice || exit 0
    case "$choice" in
        '') exit 0 ;;
        r|R)
            printf 'Scanning for 8 seconds…\n'
            bluetoothctl --timeout 8 scan on || true
            continue ;;
    esac
    [[ $choice =~ ^[1-9][0-9]*$ && ${#choice} -le 3 ]] || continue
    index=$((10#$choice-1))
    (( index < ${#addresses[@]} )) || continue
    address=${addresses[index]}
    name=${names[index]}
    printf '\n%s (%s)\n1. Pair\n2. Connect\n3. Disconnect\n4. Forget\nEnter to go back: ' "$name" "$address"
    IFS= read -r action || exit 0
    case "$action" in
        1)
            info=$(bluetoothctl info "$address")
            if [[ $info == *'Paired: yes'* ]]; then echo 'Already paired.'; pause; continue; fi
            printf '\nPair with %s? [y/N] ' "$name"
            IFS= read -r answer || exit 0
            [[ $answer == [yY] ]] || continue
            printf 'pair %s\n' "$address" > "$work/pair"
            printf '\nConfirm any PIN request below. After pairing finishes,\ntype quit to return to the device menu.\n'
            timeout --foreground 180 bluetoothctl --agent KeyboardDisplay --init-script "$work/pair" || true
            info=$(bluetoothctl info "$address")
            if [[ $info == *'Paired: yes'* ]]; then
                printf '\nTrust %s for future connections? [y/N] ' "$name"
                IFS= read -r answer || exit 0
                if [[ $answer == [yY] ]]; then bluetoothctl trust "$address"; fi
            else
                echo 'Pairing did not complete.'
            fi
            ;;
        2) badge-panel-bluetooth-connect "$address" || echo 'Could not connect.' ;;
        3) timeout 30 bluetoothctl disconnect "$address" || echo 'Could not disconnect.' ;;
        4)
            printf 'Forget %s and remove its pairing? [y/N] ' "$name"
            IFS= read -r answer || exit 0
            if [[ $answer == [yY] ]]; then bluetoothctl remove "$address"; fi
            ;;
        *) continue ;;
    esac
    pause
done
