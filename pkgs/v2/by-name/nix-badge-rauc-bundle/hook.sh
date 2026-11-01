#!/bin/sh
# RAUC bundle hook: puts the files of the bundle's boot.tar into the boot FAT's slots.
#   slot-install       (class boot) checks only; RAUC's own vfat handler would mkfs the FAT
#   slot-post-install  (class nix) re-checks after the store write, then installs this
#                      slot's files, drops its leftover extlinux files and, when boot.tar
#                      carries one (a board without an eMMC), writes /fip.bin last
# RAUC 1.15.2 mounts the slot for neither hook, so both mount the FAT themselves, rw: on
# an eMMC boot it is already mounted rw at /boot, and a second mount cannot change that.
set -eu

BOOTMNT=/run/rauc/nix-badge-boot
BOOTDEV_FILE=/run/rauc/nix-badge-bootdev

mount_boot() {
	# $1 = device to mount
	mkdir -p "$BOOTMNT"
	mount -t vfat -o umask=0077 "$1" "$BOOTMNT"
}

unmount_boot() {
	umount "$BOOTMNT" 2>/dev/null || true
}

# bundle_tar: the bundle's boot.tar, or a refusal (e.g. a nix-only bundle).
bundle_tar() {
	tarball="${RAUC_BUNDLE_MOUNT_POINT:?hook: RAUC_BUNDLE_MOUNT_POINT is not set}/boot.tar"
	[ -f "$tarball" ] || { echo "hook: no boot.tar in the bundle at $RAUC_BUNDLE_MOUNT_POINT -- refusing" >&2; exit 1; }
}

# check_payload: boot.tar holds <core>/boot.itb and <core>/vbmeta.itb for each of its
# cores, secure and store.sha256. Sets $cores, $ncores and $has_fip (fip.bin is optional).
check_payload() {
	listing=$(tar -tf "$tarball")
	cores=$(printf '%s\n' "$listing" | sed -n 's|^\([a-z0-9]*\)/boot\.itb$|\1|p' | tr '\n' ' ')
	[ -n "$cores" ] || { echo "hook: boot.tar has no <core>/boot.itb -- refusing" >&2; exit 1; }
	ncores=0
	for core in $cores; do ncores=$((ncores + 1)); done
	for f in $(for core in $cores; do echo "$core/vbmeta.itb"; done) secure store.sha256; do
		printf '%s\n' "$listing" | grep -qxF "$f" || { echo "hook: boot.tar lacks $f -- refusing" >&2; exit 1; }
	done
	has_fip=0
	if printf '%s\n' "$listing" | grep -qxF fip.bin; then has_fip=1; fi
}

# check_secure <bundle word>: refuse unless the card's /secure allows that bundle.
check_secure() {
	case "$1" in
	  signed|unsigned) ;;
	  *) echo "hook: the bundle's secure marker says '$1', not signed or unsigned -- refusing" >&2; exit 1 ;;
	esac
	if [ -e "$BOOTMNT/secure" ]; then
		card=$(cat "$BOOTMNT/secure")
		case "$card" in
		  signed|unsigned) ;;
		  *) echo "hook: $BOOTMNT/secure says '$card', not signed or unsigned -- refusing" >&2; exit 1 ;;
		esac
		if [ "$1" != "$card" ]; then
			echo "hook: bundle is $1 but this card is $card -- switching secure mode needs a reflash" >&2
			exit 1
		fi
	elif [ "$1" != unsigned ]; then
		echo "hook: card has no /secure (extlinux layout); only an unsigned bundle can migrate it" >&2
		exit 1
	fi
}

case "$1" in
  slot-install)
    [ "$RAUC_SLOT_CLASS" = boot ] || { echo "hook: slot-install for unexpected class $RAUC_SLOT_CLASS" >&2; exit 1; }
    bundle_tar
    trap unmount_boot EXIT
    mount_boot "$RAUC_SLOT_DEVICE"
    # Checks only: this stage never writes to the FAT.
    check_payload
    check_secure "$(tar -xOf "$tarball" secure)"
    # Room for slot-post-install as if the target slot were empty (RAUC_SLOT_BOOTNAME is
    # empty for the boot class): every core's files, the fip's new copy, plus 16 MiB.
    # Sizes from the tar listing, read with the shell: rauc.service's PATH has no awk.
    itb_sum=0
    vb_sum=0
    fip_size=0
    sized=0
    while read -r _mode _owner size _date _time name; do
      case "$name" in
        */boot.itb|*/vbmeta.itb|fip.bin)
          case "$size" in ''|*[!0-9]*) sized=bad; break ;; esac
          sized=$((sized + 1)) ;;
      esac
      case "$name" in
        */boot.itb) itb_sum=$((itb_sum + size)) ;;
        */vbmeta.itb) vb_sum=$((vb_sum + size)) ;;
        fip.bin) fip_size=$size ;;
      esac
    done <<LISTING
$(tar -tvf "$tarball")
LISTING
    [ "$sized" = $((2 * ncores + has_fip)) ] || { echo "hook: could not size the files in boot.tar -- refusing" >&2; exit 1; }
    margin=$((16 * 1024 * 1024))
    need=$((itb_sum + vb_sum + fip_size + margin))
    case $ncores in 1) all=the ;; 2) all=both ;; *) all=all ;; esac
    fip_note=
    [ "$has_fip" = 0 ] || fip_note=" + fip.bin $fip_size bytes"
    # No pipefail in sh: check df's own output instead of trusting the pipe.
    avail_kib=$(df -k --output=avail "$BOOTMNT" | tail -n1 | tr -d ' ')
    case $avail_kib in
      ''|*[!0-9]*) echo "hook: could not read the free space of $BOOTMNT (df said '$avail_kib')" >&2; exit 1 ;;
    esac
    avail=$((avail_kib * 1024))
    # An older hook's .incoming/ is deleted by slot-post-install, so it counts as free.
    if [ -d "$BOOTMNT/.incoming" ]; then
      stale_kib=$(du -sk --apparent-size "$BOOTMNT/.incoming" | cut -f1)  # apparent: never more than the clusters freed
      case $stale_kib in ''|*[!0-9]*) stale_kib=0 ;; esac
      avail=$((avail + stale_kib * 1024))
    fi
    if [ "$avail" -lt "$need" ]; then
      echo "hook: boot FAT has $avail bytes free, need $need ($all boot.itb $itb_sum bytes + $all vbmeta.itb $vb_sum bytes$fip_note + 16 MiB margin)" >&2
      exit 1
    fi
    rm -f "$BOOTDEV_FILE"
    printf '%s' "$RAUC_SLOT_DEVICE" > "$BOOTDEV_FILE"
    ;;
  slot-post-install)
    [ "$RAUC_SLOT_CLASS" = nix ] || { echo "hook: slot-post-install for unexpected class $RAUC_SLOT_CLASS" >&2; exit 1; }
    slot=$RAUC_SLOT_BOOTNAME
    case "$slot" in
      A|B) ;;
      *) echo "hook: unexpected RAUC_SLOT_BOOTNAME=$slot" >&2; exit 1 ;;
    esac
    bundle_tar
    # The device slot-install recorded, else the eMMC's boot FAT.
    bootdev=/dev/boot0
    [ -r "$BOOTDEV_FILE" ] && bootdev=$(cat "$BOOTDEV_FILE")
    trap unmount_boot EXIT
    mount_boot "$bootdev"
    # Every check before the first write. The digest catches a boot.tar built for another
    # store.img: its vbmeta.itb carries that store's verity root.
    check_payload
    check_secure "$(tar -xOf "$tarball" secure)"
    staged=$(tar -xOf "$tarball" store.sha256)
    if [ "$staged" != "$RAUC_IMAGE_DIGEST" ]; then
      echo "hook: boot.tar's store.sha256 ($staged) does not match RAUC_IMAGE_DIGEST ($RAUC_IMAGE_DIGEST) -- refusing" >&2
      exit 1
    fi
    # Free the target slot first: its .prev (RAUC keeps none), a torn install's
    # temporaries, and an older hook's .incoming/.
    rm -rf "$BOOTMNT/.incoming"
    for core in $cores; do
      d="$BOOTMNT/$core/slot-$slot"
      rm -f "$d/boot.itb.prev" "$d/boot.itb.prev.new" "$d/boot.itb.new" "$d/vbmeta.itb.new"
    done
    [ "$has_fip" = 0 ] || rm -f "$BOOTMNT/fip.bin.new"
    sync
    # <file>.new, sync, rename: the slot always holds complete files. One command per
    # line, so a failed tar (FAT full) aborts under set -e before its mv.
    for core in $cores; do
      d="$BOOTMNT/$core/slot-$slot"
      mkdir -p "$d"
      for f in boot.itb vbmeta.itb; do
        tar -xOf "$tarball" "$core/$f" > "$d/$f.new"
        sync
        mv -f "$d/$f.new" "$d/$f"
        sync
      done
    done
    # This slot's leftover extlinux files describe the store just overwritten; the
    # other slot's and the shared ones stay.
    for core in $cores; do
      rm -rf "$BOOTMNT/$core/slot-$slot/nixos"
      for f in "extlinux-$slot.conf" "verity-append-$slot" "extlinux-desktop-$slot.conf" "extlinux-video-$slot.conf"; do
        rm -f "$BOOTMNT/$core/extlinux/$f"
      done
    done
    sync
    # A card without /secure (check_secure allowed only unsigned) gets it now.
    if [ ! -e "$BOOTMNT/secure" ]; then
      tar -xOf "$tarball" secure > "$BOOTMNT/secure.new"
      sync
      mv -f "$BOOTMNT/secure.new" "$BOOTMNT/secure"
      sync
    fi
    # Last: the SD has no second fip, so a cut power here can leave it unbootable. Only
    # a changed fip is written (rauc.service's PATH has no cmp).
    if [ "$has_fip" = 1 ]; then
      new=$(tar -xOf "$tarball" fip.bin | sha256sum | cut -d' ' -f1)
      old=
      if [ -f "$BOOTMNT/fip.bin" ]; then old=$(sha256sum < "$BOOTMNT/fip.bin" | cut -d' ' -f1); fi
      if [ "$new" != "$old" ]; then
        tar -xOf "$tarball" fip.bin > "$BOOTMNT/fip.bin.new"
        sync
        mv -f "$BOOTMNT/fip.bin.new" "$BOOTMNT/fip.bin"
        sync
      fi
    fi
    ;;
  slot-pre-install) exit 0 ;;
  *) echo "hook: unknown stage $1" >&2; exit 1 ;;
esac
