# nix-badge-grow-userdata: grow the USERDATA partition under /.userdata to the end of its
# disk, once. Its number and name come from sysfs, which the kernel fills before udev
# runs: on a first boot udev can still be busy, and lsblk then knows neither.
# One sgdisk commit moves the backup header, regrows USERDATA (same GUID, type and name)
# and keeps the hybrid MBR entry the mask ROM boots through: no reboot can land on a plain
# protective MBR, which the ROM cannot mount. Only a partition named USERDATA is touched.
sys=${GROW_SYSFS:-/sys}
dev=${GROW_DEV:-/dev}
stamp=${GROW_STAMP:-/var/lib/nix-badge/growpart.done}
src=${GROW_SOURCE:-$(findmnt -no SOURCE /.userdata)}

blk=$sys/class/block/${src##*/}
n=$(cat "$blk/partition" 2>/dev/null || true)
label=$(sed -n 's/^PARTNAME=//p' "$blk/uevent" 2>/dev/null || true)
if [ "$label" != USERDATA ] || [ -z "$n" ]; then
  echo "$src is not a partition named USERDATA (name '$label', number '$n'); not resizing" >&2
  exit 0
fi
disk=$dev/$(basename "$(readlink -f "$blk/..")")

info=$(sgdisk -i "$n" "$disk")
start=$(printf '%s\n' "$info" | sed -n 's/^First sector: \([0-9]*\).*/\1/p')
guid=$(printf '%s\n' "$info" | sed -n 's/^Partition unique GUID: \([0-9A-Fa-f-]*\).*/\1/p')
if [ -z "$start" ] || [ -z "$guid" ]; then
  echo "cannot read partition $n of $disk; not stamping, will retry next boot" >&2
  exit 0
fi
if sgdisk --move-second-header --delete="$n" --new="$n:$start:0" --partition-guid="$n:$guid" \
  --typecode="$n:8300" --change-name="$n:USERDATA" --hybrid=1:EE "$disk"; then
  partx --update --nr "$n" "$disk" || true # the partition is mounted; resize it in place
  mkdir -p "$(dirname "$stamp")"
  touch "$stamp"
else
  echo "sgdisk failed on $disk partition $n; not stamping, will retry next boot" >&2
fi
