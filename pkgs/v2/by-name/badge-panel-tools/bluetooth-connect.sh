[[ $# == 1 && $1 =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] || exit 2
timeout 45 bluetoothctl connect "$1"
