[[ $# == 1 && $1 =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] || exit 2
info=$(LC_ALL=C bluetoothctl info "$1")
while IFS= read -r line; do
    [[ $line == *UUID:* ]] || continue
    # Standard audio sink/source, headset, hands-free and LE audio services.
    if [[ ${line,,} =~ 0000(110a|110b|1108|1112|111e|111f|184e|1850)-0000-1000-8000-00805f9b34fb ]]; then
        exit 0
    fi
done <<< "$info"
exit 1
