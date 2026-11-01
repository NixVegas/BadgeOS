# The two-tier Nix store of a data card boot: the card's local-overlay store over the
# eMMC's, over the squashfs. Sourced by stage 0 and the storage-mode service.
#
# The eMMC USERDATA is at /.lower-userdata (read-only) and the card's at /.userdata, with
# the booted slot's Nix state bound at /.userdata/nix as in a case 1 boot. NB_RO is the
# squashfs store root (/nix/.ro-store); NB_ROOT prefixes the store's own root (empty on a
# badge, where the store is /nix/store).

nb_urlenc() { printf '%s' "$1" | sed 's/%/%25/g; s/?/%3F/g; s/&/%26/g; s/=/%3D/g; s|/|%2F|g'; }

# The eMMC tier: its slot's upper layer over the squashfs, read-only, with its Nix state
# a copy on the card (a local-overlay store records rows for the lower paths its upper
# paths refer to, so its database has to be writable; the eMMC's is never touched).
store_url_tier1() { # $1 = slot
  local ro=${NB_RO:-/nix/.ro-store}
  echo "local-overlay://?root=${NB_ROOT:-}/nix/.lower-store&lower-store=$(nb_urlenc "local?root=$ro&read-only=true")&upper-layer=/.lower-userdata/nix-$1/upper&check-mount=false"
}

# The card tier: the real store, over the eMMC tier.
store_url_tier2() { # $1 = slot
  local root=""
  [ -n "${NB_ROOT:-}" ] && root="root=$NB_ROOT&"
  echo "local-overlay://?${root}lower-store=$(nb_urlenc "$(store_url_tier1 "$1")")&upper-layer=/.userdata/nix/upper"
}

# The eMMC tier's store (read-only) and a fresh copy of its state on the card, then the
# card's store over it. The caller binds the card's /.userdata/nix/var at /nix/var, as in
# a case 1 boot.
mount_tier2() { # $1 = lower userdata, $2 = card userdata, $3 = slot
  local r=${NB_ROOT:-} ro=${NB_RO:-/nix/.ro-store}
  mkdir -p "$r/nix/.lower-store/nix/store" "$r/nix/.lower-store/nix/var" "$r/nix/store"
  mount -t overlay overlay -o "ro,lowerdir=$1/nix-$3/upper:$ro/nix/store" "$r/nix/.lower-store/nix/store" &&
    rm -rf "$2/.lower-state/nix-$3" && mkdir -p "$2/.lower-state/nix-$3/nix" &&
    cp -a "$1/nix-$3/var/nix/db" "$2/.lower-state/nix-$3/nix/db" &&
    mount --bind "$2/.lower-state/nix-$3" "$r/nix/.lower-store/nix/var" &&
    mount -t overlay overlay -o "lowerdir=$r/nix/.lower-store/nix/store,upperdir=$2/nix/upper,workdir=$2/nix/work" "$r/nix/store"
}
