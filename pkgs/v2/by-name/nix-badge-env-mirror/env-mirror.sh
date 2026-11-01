src=/dev/uboot0
[ -b "$src" ] || { echo "no $src"; exit 0; }

# /dev/uboot0 is boot area 2 (mmcblkNboot1); UBOOT is partition 2 of the same disk.
# Not `blkid -L UBOOT`: -L matches filesystem labels and this partition is a raw blob.
real=$(readlink -f "$src")
disk="/dev/$(basename "$real" | sed 's/boot1$//')"
dst="$disk"p2
[ -b "$dst" ] || { echo "no $dst"; exit 0; }
label=$(lsblk -no PARTLABEL "$dst" 2>/dev/null || true)
if [ "$label" != "UBOOT" ]; then
  echo "$dst is PARTLABEL '$label', not UBOOT -- refusing to touch it"
  exit 0
fi

dd if="$src" of="$dst" bs=64K count=4 conv=fsync status=none && echo "mirrored $src -> $dst"
