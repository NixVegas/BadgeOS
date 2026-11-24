# Invoked by a root service. Paths are fixed at build time, never supplied by the caller.
set -euo pipefail
umask 077
boot=/boot
sys=/sys
cmdline=/proc/cmdline
lock=/run/lock/badge-core-reboot.lock
firmware=$CORE_REBOOT_FIRMWARE

die() { echo "nix-badge-core-reboot: $*" >&2; exit 1; }
[[ $# == 2 && ($1 == check || $1 == reboot) && ($2 == arm || $2 == riscv) ]] || die "expected check|reboot arm|riscv"
[[ $EUID == 0 ]] || die "root service required"
operation=$1
target=$2
exec 9>"$lock"
flock -n 9 || die "another core change is in progress"

device=$(findmnt -rn -M "$boot" -o SOURCE)
[[ $device =~ ^/dev/(mmcblk[0-9]+)p1$ ]] || die "BOOT is not an MMC first partition"
disk=${BASH_REMATCH[1]}
[[ $(cat "$sys/class/block/$disk/device/type") == SD ]] || die "BOOT is not on SD"
[[ $(findmnt -rn -M "$boot" -o FSTYPE) == vfat ]] || die "BOOT is not FAT"
case " $(cat "$cmdline") " in *' nixbadge.bootmedium=1 '*) ;; *) die "not booted from SD";; esac
[[ -n $firmware && -r $firmware ]] || die "core-transfer firmware package is not configured"
firmware_hash=$(sha256sum "$firmware" | cut -d ' ' -f 1)
[[ $(sha256sum "$boot/fip.bin" | cut -d ' ' -f 1) == "$firmware_hash" ]] || die "installed firmware is not this system's core-switch firmware"
for core in arm riscv; do
    for slot in A B; do
        [[ -s $boot/$core/slot-$slot/boot.itb && -s $boot/$core/slot-$slot/vbmeta.itb ]] || die "missing $core slot $slot payload"
    done
done
for name in coreswap.request coreswap.pending; do
    [[ ! -e $boot/$name || (-f $boot/$name && ! -L $boot/$name) ]] || die "unexpected $name file type"
done
if [[ $operation == check ]]; then
    echo "Ready to reboot to $target"
    exit 0
fi

# Keep a recovery copy even when a later step fails. A power cut before publication
# leaves no request; the ARM strap remains the recovery path.
backup=$(mktemp -d "$boot/core-reboot-XXXXXXXX.orig")
for name in coreswap.request coreswap.pending; do
    if [[ -e $boot/$name ]]; then
        cp -- "$boot/$name" "$backup/$name"
        cmp -- "$boot/$name" "$backup/$name"
    fi
done
printf 'riscv\n' > "$backup/new-request"
sync -f "$boot"
rollback() {
    local status=$?
    trap - EXIT
    if (( status != 0 )); then
        echo "nix-badge-core-reboot: restoring boot markers from $backup" >&2
        rm -f -- "$boot/coreswap.request"
        for name in coreswap.pending coreswap.request; do
            if [[ -e $backup/$name ]]; then cp -- "$backup/$name" "$boot/$name";
            else rm -f -- "$boot/$name"; fi
        done
        sync -f "$boot"
    fi
    exit "$status"
}
trap rollback EXIT
trap 'exit 1' HUP INT TERM
rm -f -- "$boot/coreswap.request"
sync -f "$boot"
rm -f -- "$boot/coreswap.pending"
if [[ $target == riscv ]]; then
    cp -- "$backup/new-request" "$backup/staged-request"
    sync -f "$boot"
    mv -- "$backup/staged-request" "$boot/coreswap.request"
    cmp -- "$backup/new-request" "$boot/coreswap.request"
fi
sync -f "$boot"
echo "nix-badge-core-reboot: rebooting to $target; original markers saved in $backup"
systemctl --no-block reboot
trap - EXIT
