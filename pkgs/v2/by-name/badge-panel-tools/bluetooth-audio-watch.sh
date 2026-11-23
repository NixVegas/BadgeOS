coproc SIGNALS {
    exec dbus-monitor --system \
        "type='signal',sender='org.bluez',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',path_namespace='/org/bluez'" \
        "type='signal',sender='org.bluez',interface='org.freedesktop.DBus.ObjectManager',member='InterfacesRemoved'" \
        "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='org.bluez'"
}
monitor_pid=$SIGNALS_PID
exec {signal_fd}<&"${SIGNALS[0]}"
cleanup() {
    kill "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
    systemctl --user stop pipewire.socket pipewire-pulse.socket || true
}
trap cleanup EXIT
trap 'exit 0' HUP INT TERM
badge-panel-bluetooth-audio-state
while IFS= read -r line <&"$signal_fd"; do
    case "$line" in
        *'string "Connected"'*|*'string "ServicesResolved"'*|*'string "UUIDs"'*|*'member=InterfacesRemoved'*|*'member=NameOwnerChanged'*)
            if ! systemctl --quiet is-active badge-panel-bluetooth.service; then exit 0; fi
            badge-panel-bluetooth-audio-state
            ;;
    esac
done
# dbus-monitor ended: fail, so the unit restarts the watch.
false
