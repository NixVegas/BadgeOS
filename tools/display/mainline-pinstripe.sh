#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Manual control only; never run by a boot service.
set -euo pipefail
control=/sys/bus/platform/devices/a080000.dsi/pinstripe
[[ -r $control ]] || { echo 'DSI driver not bound; inspect dmesg' >&2; exit 1; }
case ${1:-} in
start | stop | status)
  result=0
  [[ $1 == status ]] || printf '%s\n' "$1" > "$control" || result=$?
  cat "$control"
  exit "$result"
  ;;
test) ;;
*) echo 'usage: mainline-pinstripe start|stop|status|test' >&2; exit 2 ;;
esac

[[ $EUID == 0 && $(uname -m) == riscv64 && $(uname -r) == 7.2.2 ]] || {
  echo 'test requires root on the configured RISC-V Linux 7.2.2 image' >&2; exit 1;
}
idle='terminal=0 started=0 owned=0 mac=0x0 stage=idle error=0'
owned='terminal=0 started=1 owned=1 mac=0x4 stage=idle error=0'
status() { timeout -k 2 5 cat "$control"; }
state=$(status) && [[ $state == "$idle" ]] || { echo 'driver is not idle' >&2; exit 1; }
# Keep failed or interrupted attempts from silently becoming another trial.
mkdir /run/badge-display-start-attempted || exit 1
cleanup() {
  result=$?
  trap - EXIT HUP INT TERM
  state=$(status) || state=unknown
  if [[ $state == "$owned" ]]; then
    timeout -k 2 15 "$BASH" "$0" stop || result=1
  elif [[ $state != "$idle" ]]; then
    echo 'unknown driver state; operator recovery required' >&2
    result=1
  fi
  state=$(status) || state=unknown
  printf 'final: %s\n' "$state"
  [[ $state == "$idle" ]] || result=1
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
timeout -k 2 25 "$BASH" "$0" start
state=$(status)
[[ $state == "$owned" ]]
echo 'Display active for 45 seconds; check HDMI for pinstripe.'
sleep 45
state=$(status)
[[ $state == "$owned" ]]
# EXIT performs one guarded stop. Success here checks lifecycle and the MAC
# acknowledgement (mac=0x4), not the pixels.
