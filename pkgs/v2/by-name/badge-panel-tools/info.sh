arch=$(uname -m)
case "$arch" in
    aarch64) cpu='ARM (Cortex-A53)'; core=arm ;;
    riscv64) cpu='RISC-V (C906)'; core=riscv ;;
    *) cpu=$arch; core=$arch ;;
esac
profile=$(readlink "/nix/var/nix/profiles/system-$core" || true)
generation=${profile##*system-"$core"-}
generation=${generation%-link}
slot=unknown
read -r -a cmdline < /proc/cmdline
for word in "${cmdline[@]}"; do
    case "$word" in rauc.slot=*) slot=${word#*=} ;; esac
done
read -r uptime_seconds _ < /proc/uptime
uptime_seconds=${uptime_seconds%.*}
printf '\033[2J\033[HSystem info\n\n'
printf 'CPU:         %s\nKernel:      %s\n' "$cpu" "$(uname -r)"
printf 'System:      %s\n' "$(cat /run/current-system/nixos-version)"
printf 'Selected profile: %s\nBoot slot:        %s\n' "${generation:-unknown}" "$slot"
printf 'Uptime:      %sh %sm\n\n' "$((uptime_seconds / 3600))" "$((uptime_seconds / 60 % 60))"
awk '
    /^MemTotal:/ {total=$2} /^MemAvailable:/ {available=$2}
    /^CmaTotal:/ {cma=$2} /^CmaFree:/ {cmafree=$2}
    /^SwapTotal:/ {swap=$2} /^SwapFree:/ {swapfree=$2}
    END {
      printf "RAM available:  %.1f / %.1f MiB\n", available/1024, total/1024
      printf "CMA free:       %.1f / %.1f MiB\n", cmafree/1024, cma/1024
      printf "Swap used:      %.1f MiB\n", (swap-swapfree)/1024
    }
' /proc/meminfo
printf '\nSnapshot at opening. Reopen to refresh.\nUse Close to return.\n'
trap 'exit 0' HUP INT TERM
sleep infinity &
wait "$!"
