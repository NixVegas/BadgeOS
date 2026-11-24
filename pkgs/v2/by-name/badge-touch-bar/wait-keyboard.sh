signal=$(env kill -l RTMIN)
while kill -0 "${MAINPID:?}" 2>/dev/null; do
    while read -r key value _; do
        if [[ "$key" == SigBlk: ]] && (( (16#$value & (1 << (signal - 1))) != 0 )); then
            exit 0
        fi
    done < "/proc/$MAINPID/status"
    sleep 0.05
done
exit 1
