PROC=${STAGE0_PROC:-/proc}; SYS=${STAGE0_SYS:-/sys}; DEV=${STAGE0_DEV:-/dev}
PLAN=${STAGE0_PLAN:-0}
# STAGE0_STATE_TEST=1 (tests): only the reset, the per-slot state and the init choice, on
# plain directories; STAGE0_USERDATA_DEV stands in for the USERDATA partition.
STATE_TEST=${STAGE0_STATE_TEST:-0}
UD=${STAGE0_USERDATA:-/.userdata}; RO=${STAGE0_ROSTORE:-/nix/.ro-store}
say() { echo "stage-0: $*"; [ -w /dev/kmsg ] && echo "stage-0: $*" > /dev/kmsg || true; }

# 0) pseudo-filesystems (the kernel auto-mounts only /dev)
if [ "$PLAN" = 0 ] && [ "$STATE_TEST" = 0 ]; then
  mount -t proc -o nosuid,noexec,nodev proc /proc 2>/dev/null || :
  mount -t sysfs -o nosuid,noexec,nodev sysfs /sys 2>/dev/null || :
  # No initrd ran, so /dev/fd does not exist yet; stage 2 needs it at its first line.
  [ -e /dev/fd ] || ln -s /proc/self/fd /dev/fd 2>/dev/null || :
  for n in 0:stdin 1:stdout 2:stderr; do [ -e "/dev/${n#*:}" ] || ln -s "/proc/self/fd/${n%%:*}" "/dev/${n#*:}" 2>/dev/null || :; done
fi

# 1) cmdline: the first init= is the real init, rauc.slot= keys the per-slot Nix state
#    (A when absent), the verity root hash (after "sha256" in dm-mod.create) stamps it
real=""; medium=""; slot=""; profile=""; reset=""; datacard=0; cardfit=0
for o in $(< "$PROC/cmdline"); do
  case $o in
    init=*) [ -n "$real" ] || real=${o#init=} ;;
    nixbadge.bootmedium=*) medium=${o#nixbadge.bootmedium=} ;;
    rauc.slot=*) slot=${o#rauc.slot=} ;;
    nixbadge.profile=*) profile=${o#nixbadge.profile=} ;;
    nixbadge.reset=*) reset=${o#nixbadge.reset=} ;;
    nixbadge.datacard=1) datacard=1 ;;
    nixbadge.cardfit=1) cardfit=1 ;;
  esac
done
case $reset in
  ""|userdata) ;;
  *) say "unknown nixbadge.reset=$reset; nothing is reset"; reset="" ;;
esac
case $slot in
  A|B) ;;
  "") slot=A ;;
  *) say "unexpected rauc.slot=$slot on the command line; using slot A's Nix state"; slot=A ;;
esac
stamp=$(tr ' ' '\n' < "$PROC/cmdline" | grep -A1 -x sha256 | tail -1)
if [ -z "$real" ]; then say "no usable init= on the command line"; exit 1; fi

# The image's own generation for this core, linked by nix-badge-store-squashfs.
case ${STAGE0_ARCH:-$(uname -m)} in
  aarch64*) core=arm ;;
  riscv64*) core=riscv ;;
  *) core=unknown ;;
esac
fallback="$RO/nix/var/nix/profiles/system-$core/init"

# init=/init-<core> (the FIT kernel line never names a store path) means the booted
# slot's profile link, which deploy-rs moves.
constinit=0
case $real in
  /init-*|"$0") constinit=1 ;;
esac
# In case 3 the profile link is the one of the FIT U-Boot booted: the card's with
# nixbadge.cardfit=1, else the eMMC's, so the kernel and the userland always match.
follow_fit() {
  [ "$constinit" = 1 ] || return 0
  if [ "$storage" = card ] && [ "$cardfit" = 0 ]; then
    real="$LOWER/nix-$slot/var/nix/profiles/system-$core/init"
  else
    real="$UD/nix-$slot/var/nix/profiles/system-$core/init"
  fi
}

# The first init= if it is executable once the store overlay is up, else the baked one
# (its generation may have lived only in an upper layer that is gone).
choose_init() {
  if [ -x "$real" ]; then
    echo "$real"
  elif [ -x "$fallback" ]; then
    say "init $real is not executable; falling back to $fallback" >&2
    echo "$fallback"
  else
    say "init $real is not executable and the fallback $fallback is missing too; trying $real anyway" >&2
    echo "$real"
  fi
}

# The chosen system's specialisation/<profile>/init if it has one, else its own init.
profile_init() {
  local i spec
  i=$(choose_init)
  case $profile in
    ""|default) ;;
    # A profile is a specialisation name: / or .. would resolve outside specialisation/.
    */*|*..*) say "nixbadge.profile=$profile is not a profile name, booting the base system" >&2 ;;
    *)
      spec="$(dirname "$i")/specialisation/$profile/init"
      if [ -x "$spec" ]; then i=$spec; else say "no specialisation $profile, booting the base system" >&2; fi
      ;;
  esac
  echo "$i"
}

# Per-slot Nix state in $UD/nix-<slot>, bound over $UD/nix so the overlay and daemon
# strings are the same for either slot. A new root hash resets only this slot's state.
# A single-slot card's $UD/nix (and $UD/.slot-stamp) becomes $UD/nix-A once.
slot_state() {
  local d="$UD/nix-$slot"
  if [ ! -e "$UD/nix-A" ] && [ -d "$UD/nix" ] && [ -n "$(ls -A "$UD/nix" 2>/dev/null)" ]; then
    say "migrating the shared Nix state $UD/nix (single-slot layout) to $UD/nix-A"
    if mv "$UD/nix" "$UD/nix-A"; then
      if [ -f "$UD/.slot-stamp" ]; then mv "$UD/.slot-stamp" "$UD/nix-A/.slot-stamp" || say "moving $UD/.slot-stamp into $UD/nix-A failed; slot A's state resets once"; fi
    else
      say "renaming $UD/nix to $UD/nix-A failed; slot A starts with fresh Nix state"
    fi
  fi
  mkdir -p "$d" "$UD/nix"
  local old
  old=$(cat "$d/.slot-stamp" 2>/dev/null || echo none)
  if [ -n "$stamp" ] && [ "$old" != "$stamp" ]; then
    say "slot $slot store changed ($old -> $stamp): resetting slot $slot's Nix upper layer and /nix/var"
    rm -rf "${d:?}/upper" "${d:?}/work" "${d:?}/var"
  fi
  mkdir -p "$d/upper" "$d/work"
  local seed_ok=1 profiles=$RO/nix/var/nix/profiles
  # A data card starts from the eMMC slot's profiles: its deployed generations.
  if [ "$storage" = card ] && [ -d "$LOWER/nix-$slot/var/nix/profiles" ]; then profiles=$LOWER/nix-$slot/var/nix/profiles; fi
  if [ ! -d "$d/var" ]; then
    # Seed only the profiles, not nix/var: the lower database must not become the upper's.
    if mkdir -p "$d/var/nix/db" "$d/var/nix/gcroots/per-user" \
         "$d/var/nix/temproots" "$d/var/nix/profiles/per-user" \
       && cp -a "$profiles/." "$d/var/nix/profiles/"; then
      :
    else
      say "seeding $d/var/nix/profiles failed; the next boot retries"
      rm -rf "${d:?}/var"
      seed_ok=0
    fi
  fi
  if [ -n "$stamp" ] && [ "$seed_ok" = 1 ]; then echo "$stamp" > "$d/.slot-stamp"; fi
}

# Factory reset: a fresh filesystem on the USERDATA partition step 3 found on the booted
# disk, before step 5 mounts it. With a data card in the slot it is the card's, even
# when this boot then cannot use the card, never the eMMC's.
mkfs_userdata() { "${STAGE0_MKFS:-mkfs.ext4}" -F -q -L "$2" -- "$1"; } # $1 = device, $2 = label
reset_userdata() {
  local dev=$userdata what=USERDATA label=USERDATA
  [ "$reset" = userdata ] || return 0
  if [ -n "$resetcard" ]; then dev=$resetcard; what="the data card's EXT_USERDATA" label=EXT_USERDATA; fi
  if [ -z "$dev" ]; then
    say "factory reset requested, but the booted disk has no USERDATA partition; nothing reset"
    return 0
  fi
  say "factory reset: making a fresh filesystem on $what ($dev)"
  if mkfs_userdata "$dev" "$label"; then
    sync
    say "factory reset: $what is a fresh filesystem; booting with empty state"
  else
    say "factory reset: mkfs.ext4 $dev failed; booting with whatever $what holds"
  fi
}

# Case 3's fingerprint of the eMMC, kept on the card: the eMMC's CID and USERDATA
# filesystem UUID in $UD/.nixbadge-lower, each slot's squashfs stamp and Nix database
# hash in $UD/nix-<slot>/.nixbadge-lower. Another badge's card is not used (case 1). Any
# other change resets the card's Nix layer for the slot (both slots for a new eMMC
# USERDATA), removes its .nixbadge-cardfit-<slot> so U-Boot stops booting the card's
# FIT for it, and, when the card has a BOOT, leaves the slot in
# .nixbadge-card-boot-reset for nix-badge-card-boot-reset to drop that FIT; other
# files stay.
LOWER=${STAGE0_LOWER:-/.lower-userdata}
card_reset_nix() { # $1 = slot
  rm -rf "${UD:?}/nix-$1/upper" "${UD:?}/nix-$1/work" "${UD:?}/nix-$1/var" "${UD:?}/nix-$1/.nixbadge-lower" "${UD:?}/.lower-state/nix-$1" \
    "${UD:?}/.nixbadge-cardfit-$1"
  [ -z "$cardboot" ] || echo "$1" >> "$UD/.nixbadge-card-boot-reset"
}
card_state() {
  local f=$UD/.nixbadge-lower g=$UD/nix-$slot/.nixbadge-lower cid fsuuid nixdb old s
  cid=${STAGE0_LOWER_CID-$(cat "$SYS/block/$disk/device/cid" 2>/dev/null)}
  fsuuid=${STAGE0_LOWER_FSUUID-$(blkid -s UUID -o value "$userdata" 2>/dev/null)}
  nixdb=$(cat "$LOWER/nix-$slot/var/nix/db/db.sqlite" "$LOWER/nix-$slot/var/nix/db/db.sqlite-wal" 2>/dev/null | sha256sum | cut -d' ' -f1)
  cstate=same
  if [ ! -f "$f" ]; then
    cstate=fresh
    # A BadgeOS card made a data card still holds its own system's Nix state.
    for s in A B; do
      if [ -e "$UD/nix-$s" ]; then
        say "the data card holds slot $s Nix state from before it was a data card: removing it"
        rm -rf "${UD:?}/nix-$s"
      fi
    done
  else
    old=$(sed -n 's/^cid=//p' "$f")
    if [ "$old" != "$cid" ]; then
      say "the data card was set up on another badge (eMMC CID $old, this one is $cid); not using it"
      storage=emmc; refused="another badge"; cstate=foreign
      return 0
    fi
    if [ "$(sed -n 's/^fsuuid=//p' "$f")" != "$fsuuid" ]; then
      say "the eMMC's USERDATA is new since the card was last used: resetting the card's Nix layers"
      for s in A B; do card_reset_nix "$s"; done
      cstate=reset
    fi
  fi
  if [ "$cstate" != reset ] && [ -f "$g" ]; then
    if [ "$(sed -n 's/^stamp=//p' "$g")" != "$stamp" ] || [ "$(sed -n 's/^nixdb=//p' "$g")" != "$nixdb" ]; then
      say "the eMMC's slot $slot changed since the card was last used: resetting the card's Nix layer for slot $slot"
      card_reset_nix "$slot"; cstate=reset
    fi
  fi
  if [ "$cstate" = reset ] && [ "$cardfit" = 1 ]; then
    say "the data card's boot image for slot $slot belonged to the Nix layer just reset: this boot runs the eMMC's generation on the card's kernel, the next one the eMMC's own"
  fi
  printf 'cid=%s\nfsuuid=%s\n' "$cid" "$fsuuid" > "$f"
  mkdir -p "$UD/nix-$slot"
  printf 'slot=%s\nstamp=%s\nnixdb=%s\n' "$slot" "$stamp" "$nixdb" > "$g"
}

if [ "$STATE_TEST" != 0 ]; then
  userdata=${STAGE0_USERDATA_DEV:-}
  # STAGE0_CARD_DEV: a data card's USERDATA; the directory is then the card's
  card=${STAGE0_CARD_DEV:-}; cardboot=${STAGE0_CARD_BOOT_DEV:-}; resetcard=$card; storage=emmc; refused=""; cstate=""
  [ -z "$card" ] || storage=card
  reset_userdata
  if [ -n "$card" ]; then
    card_state
    [ "$storage" = card ] || UD=$LOWER
    echo "storage=$storage card-state=$cstate"
    [ -z "$refused" ] || echo "card-refused=$refused"
  fi
  slot_state
  follow_fit
  echo "slot=$slot stamp=$(cat "$UD/nix-$slot/.slot-stamp" 2>/dev/null || echo none)"
  echo "chosen-init=$(profile_init)"
  exit 0
fi

# 2) the booted disk: parent of the root device (maj:min from mountinfo); with verity the
#    root is dm-0, so follow its slave to the partition first
majmin=$(awk '$5 == "/" { print $3; exit }' "$PROC/self/mountinfo")
dev=$(readlink -f "$SYS/dev/block/$majmin")
if [ -n "$(ls "$dev/slaves" 2>/dev/null)" ]; then
  for slave in "$dev"/slaves/*; do dev=$(readlink -f "$SYS/class/block/$(basename "$slave")"); break; done
fi
disk=$(basename "$(readlink -f "$dev/..")")
cardtype=$(cat "$SYS/block/$disk/type" 2>/dev/null || cat "$SYS/block/$disk/device/type" 2>/dev/null || echo "?")
case $cardtype in MMC) derived=0 ;; SD) derived=1 ;; *) derived="?" ;; esac
if [ -z "$medium" ]; then medium=$derived; elif [ "$derived" != "?" ] && [ "$medium" != "$derived" ]; then say "cmdline says medium $medium but the root sits on a $cardtype device; trusting the cmdline"; fi
echo "disk=$disk medium=$medium"

# 3) siblings by GPT partition name (no udev yet)
part_by_name() { # $1 = partition name, $2 = disk (the booted one by default)
  local u n d=${2:-$disk}
  for u in "$SYS/block/$d/$d"*/uevent; do
    if grep -qx "PARTNAME=$1" "$u" 2>/dev/null; then n=$(sed -n 's/^DEVNAME=//p' "$u"); [ -n "$n" ] || return 1; echo "$DEV/$n"; return 0; fi
  done
  return 1
}
boot=$(part_by_name BOOT || echo "")
userdata=$(part_by_name USERDATA || echo "")
[ -n "$userdata" ] || say "no USERDATA partition on $disk; state goes to a tmpfs"
echo "userdata=${userdata:-TMPFS} boot=${boot:-NONE}"

# 3b) a data card (case 3): an eMMC boot with nixbadge.datacard=1 and an SD whose GPT has
#     an EXT_USERDATA (a BadgeOS card turned into a data card keeps its NIX_A and NIX_B; its
#     USERDATA never counts); a BOOT on it takes deploys
storage=emmc; card=""; cardboot=""; resetcard=""; refused=""; sd=""
if [ "$medium" = 1 ]; then
  storage=sd
elif [ "$medium" = 0 ] && [ "$datacard" = 1 ]; then
  for b in "$SYS"/block/mmcblk*; do
    b=${b##*/}
    case $b in "$disk" | *boot* | *rpmb*) continue ;; esac
    if [ "$(cat "$SYS/block/$b/type" 2>/dev/null || cat "$SYS/block/$b/device/type" 2>/dev/null)" = SD ]; then sd=$b; break; fi
  done
  if [ -n "$sd" ]; then
    # The card's block device is there; give the kernel a moment to list its partitions.
    w=$(( ${STAGE0_CARD_WAIT:-3} * 10 ))
    while [ "$w" -gt 0 ] && ! ls "$SYS/block/$sd/$sd"*/uevent > /dev/null 2>&1; do sleep 0.1; w=$((w - 1)); done
    if card=$(part_by_name EXT_USERDATA "$sd"); then
      storage=card; resetcard=$card; cardboot=$(part_by_name BOOT "$sd" || echo "")
    else
      card=""; refused="no EXT_USERDATA partition"
    fi
  fi
fi
[ -z "$refused" ] || say "the SD card $sd is not a data card ($refused); using the eMMC's USERDATA"

# 3c) case 3: the eMMC's USERDATA read-only at /.lower-userdata first (its journal
#     replays, nothing else writes it); if it will not mount, case 1
not_card() { # $1 = why
  say "$1; not using the data card"
  storage=emmc; card=""; cardboot=""; refused=$1
}
# The eMMC is read-only here, so its slot state must already be this image's: a case 1
# boot makes it (a new or reinstalled slot has none yet).
lower_ready() {
  [ -d "$LOWER/nix-$slot/upper" ] && [ -d "$LOWER/nix-$slot/var/nix/db" ] \
    && [ "$(cat "$LOWER/nix-$slot/.slot-stamp" 2>/dev/null)" = "$stamp" ]
}
notready="the eMMC's slot $slot has not booted this image without the card yet"
if [ "$storage" = card ]; then
  if [ "$PLAN" != 0 ]; then
    # STAGE0_LOWER_MOUNT_FAILS, STAGE0_LOWER and STAGE0_CARD_FSCK_FAILS stand in for the
    # mounts and the card's e2fsck (step 5) in plan mode.
    if [ "${STAGE0_LOWER_MOUNT_FAILS:-0}" = 1 ]; then
      not_card "the eMMC's USERDATA does not mount read-only"
    elif [ -n "${STAGE0_LOWER:-}" ] && ! lower_ready; then
      not_card "$notready"
    elif [ "${STAGE0_CARD_FSCK_FAILS:-0}" = 1 ]; then
      not_card "e2fsck -p on the data card's $card returned 4"
    fi
  elif [ -z "$userdata" ]; then
    not_card "the eMMC has no USERDATA partition"
  elif ! mount -t ext4 -o ro,noatime,nosuid,nodev "$userdata" /.lower-userdata; then
    not_card "the eMMC's USERDATA does not mount read-only"
  elif ! lower_ready; then
    umount /.lower-userdata || say "unmounting the eMMC's read-only USERDATA failed"
    not_card "$notready"
  fi
fi
# U-Boot booted the card's FIT, but this boot does not use the card: say so here, and
# again if step 5 drops the card.
cardfit_check() {
  if [ "$cardfit" = 1 ] && [ "$storage" != card ]; then
    say "nixbadge.cardfit=1 but no data card is in use: the kernel is the card's, the userland the eMMC's"
  fi
}
cardfit_check
follow_fit
echo "storage=$storage"
echo "card=${card:-NONE} card-boot=${cardboot:-NONE}"
[ -z "$refused" ] || echo "card-refused=$refused"
[ "$storage" != card ] || echo "lower-userdata=$userdata"
if [ "$reset" != userdata ]; then echo "reset=none"
elif [ -n "$resetcard" ]; then echo "reset=userdata device=$resetcard"
elif [ -n "$userdata" ]; then echo "reset=userdata device=$userdata"
else echo "reset=refused"; fi
echo "nix-state slot=$slot dir=/.userdata/nix-$slot bound-at=/.userdata/nix"
if [ "$storage" = card ]; then
  echo "overlay-store lowerdir=/nix/.lower-store/nix/store upperdir=/.userdata/nix/upper workdir=/.userdata/nix/work"
  echo "lower-store lowerdir=/.lower-userdata/nix-$slot/upper:/nix/.ro-store/nix/store at=/nix/.lower-store/nix/store"
  echo "overlays=/etc,/var,/home,/root lower=/.lower-userdata upper=/.userdata"
  echo "binds=/tmp noexec, /nix/var exec; tmpfs=/bin,/usr,/lib; stamp=${stamp:-none}"
else
  echo "overlay-store lowerdir=/nix/.ro-store/nix/store upperdir=/.userdata/nix/upper workdir=/.userdata/nix/work"
  echo "binds=/etc,/var,/tmp,/home,/root noexec, /nix/var exec; tmpfs=/bin,/usr,/lib; stamp=${stamp:-none}"
fi
echo "real-init=$real"
echo "fallback-init=$fallback"
[ "$PLAN" != 0 ] && exit 0

# 4) the root stays the read-only squashfs; /bin, /usr and /lib are tmpfs, refilled every
#    boot with this core's links (the only root-level entries that differ per core)
mount --bind / /nix/.ro-store || say "bind of / onto /nix/.ro-store failed"  # the squashfs = the lower store root
mount -t tmpfs -o mode=0755,nosuid,nodev,noexec tmpfs /bin || say "tmpfs on /bin failed"
mount -t tmpfs -o mode=0755,nosuid,nodev,noexec tmpfs /usr || say "tmpfs on /usr failed"
mount -t tmpfs -o mode=0755,nosuid,nodev,noexec tmpfs /lib || say "tmpfs on /lib failed"  # tmpfiles links the per-core stub-ld here

# 5) USERDATA: the factory reset first, then check, mount, fall back. Case 3: the card's,
#    which must pass e2fsck -p, mount and belong to this badge, else case 1.
reset_userdata
if [ "$storage" = card ]; then
  e2fsck -p "$card"; rc=$?
  if [ "$rc" -ge 4 ]; then
    not_card "e2fsck -p on the data card's $card returned $rc"
  elif ! mount -t ext4 -o rw,noatime,nosuid,nodev "$card" /.userdata; then
    not_card "the data card's $card does not mount as ext4"
  else
    card_state
    [ "$storage" = card ] || umount /.userdata || say "unmounting the data card failed"
  fi
  if [ "$storage" != card ]; then
    umount /.lower-userdata || say "unmounting the eMMC's read-only USERDATA failed"
    follow_fit
    cardfit_check
  fi
fi
if [ "$storage" = card ]; then
  :
elif [ -n "$userdata" ]; then
  e2fsck -p "$userdata"; rc=$?
  [ "$rc" -ge 4 ] && say "e2fsck on $userdata returned $rc; mounting anyway, check it from stage 2"
  if ! mount -t ext4 -o rw,noatime,nosuid,nodev "$userdata" /.userdata; then
    say "mount $userdata failed; tmpfs state"; mount -t tmpfs tmpfs /.userdata
  fi
else
  mount -t tmpfs tmpfs /.userdata || say "tmpfs on /.userdata failed"
fi

# 6) per-slot Nix state, bound over /.userdata/nix; /etc, /var, /home, /root and /tmp
#    are shared by both slots
slot_state
mount --bind "/.userdata/nix-$slot" /.userdata/nix || say "bind of /.userdata/nix-$slot onto /.userdata/nix failed"
mkdir -p /.userdata/nix/upper /.userdata/nix/work /.userdata/etc /.userdata/var /.userdata/tmp /.userdata/home /.userdata/root
chmod 1777 /.userdata/tmp; chmod 0700 /.userdata/root

# 7) persistent state, noexec (symlinks into the store still execute: the check is on the
#    target's filesystem); then the store overlay, exec, with the strings check-mount wants.
#    Case 3: /etc, /var, /home and /root are overlays of the card over the eMMC, /tmp the
#    card's alone, and the store two tiers deep (tier2.sh).
if [ "$storage" = card ]; then
  for d in etc var home root; do
    mkdir -p "/.userdata/.work/$d"
    if [ -d "/.lower-userdata/$d" ]; then
      mount -t overlay overlay -o "nosuid,nodev,noexec,lowerdir=/.lower-userdata/$d,upperdir=/.userdata/$d,workdir=/.userdata/.work/$d" "/$d" || say "overlay on /$d failed"
    else
      mount --bind -o nosuid,nodev,noexec "/.userdata/$d" "/$d" || say "bind of /$d failed"
    fi
  done
  mount --bind -o nosuid,nodev,noexec /.userdata/tmp /tmp || say "bind of /tmp failed"
  mount --bind -o nosuid,nodev /.userdata/nix/var /nix/var || say "bind of /nix/var failed; Nix builds will fail"
  mount_tier2 /.lower-userdata /.userdata "$slot" || say "the two-tier store mount failed; /nix/store stays read-only"
else
  for d in etc var tmp home root; do
    mount --bind -o nosuid,nodev,noexec "/.userdata/$d" "/$d" || say "bind of /$d failed"
  done
  mount --bind -o nosuid,nodev /.userdata/nix/var /nix/var || say "bind of /nix/var failed; Nix builds will fail"   # exec: Nix builds under /nix/var/nix/builds
  mount -t overlay overlay -o lowerdir=/nix/.ro-store/nix/store,upperdir=/.userdata/nix/upper,workdir=/.userdata/nix/work /nix/store || say "store overlay mount failed; /nix/store stays read-only"
fi
# Not /boot: vfat and its codepages are modules that cannot load before systemd.
[ -n "$boot" ] && say "BOOT is $boot; systemd mounts it at /boot"

# 8) the real init, checked only now (it resolves through the overlay), else the
#    image's own generation for this core; then its boot profile's specialisation
init=$(profile_init)
exec "$init" "$@"
