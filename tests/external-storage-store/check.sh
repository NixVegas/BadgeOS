# The two-tier store, end to end, on scratch filesystems. Run as root with
# /etc/es/env providing HELLO, FIGLET and BUSYBOX (store paths in the VM's store).
set -eux
. /etc/es/env
. /etc/es/tier2.sh
export NIX_CONFIG='experimental-features = nix-command local-overlay-store read-only-local-store'

# The squashfs stand-in: a read-only local store holding hello and busybox. (A NixOS
# test VM already has the host store at /nix/.ro-store.)
export NB_RO=/es/ro-store
mkdir -p "$NB_RO"
nix copy --no-check-sigs --to "local?root=$NB_RO" "$HELLO" "$BUSYBOX"
mount --bind "$NB_RO" "$NB_RO"
mount -o remount,bind,ro "$NB_RO"

mkfsimg() { truncate -s 512M "$1.img"; mkfs.ext4 -q -F "$1.img"; mkdir -p "$2"; mount -o loop "$1.img" "$2"; }

# The eMMC: a case-1 layer that adds figlet through a tier-1 local-overlay store.
mkfsimg /tmp/emmc /.lower-userdata
mkdir -p /.lower-userdata/nix-A/upper /.lower-userdata/nix-A/work /.lower-userdata/nix-A/var/nix/db /t1/nix/store /t1/nix/var
mount -t overlay overlay -o lowerdir=$NB_RO/nix/store,upperdir=/.lower-userdata/nix-A/upper,workdir=/.lower-userdata/nix-A/work /t1/nix/store
mount --bind /.lower-userdata/nix-A/var /t1/nix/var
t1="local-overlay://?root=/t1&lower-store=local%3Froot%3D%2Fes%2Fro-store%26read-only%3Dtrue&upper-layer=/.lower-userdata/nix-A/upper"
nix copy --no-check-sigs --to "$t1" "$FIGLET"
umount /t1/nix/var /t1/nix/store
umount /.lower-userdata
mount -o loop,ro /tmp/emmc.img /.lower-userdata
tree() { (cd "$1" && find . -printf '%p %y %m %s\n' | sort && find . -type f -print0 | sort -z | xargs -0 -r sha256sum); }
tree /.lower-userdata > /tmp/emmc.before

# The card, and the two tiers over both.
mkfsimg /tmp/card /.userdata
mkdir -p /.userdata/nix/upper /.userdata/nix/work /.userdata/nix/var/nix/db
export NB_ROOT=/t2
mkdir -p /t2/nix/var; mount --bind /.userdata/nix/var /t2/nix/var
mount_tier2 /.lower-userdata /.userdata A
url=$(store_url_tier2 A)

# Paths from every tier are valid through tier 2.
nix-store --store "$url" --verify-path "$HELLO"
nix-store --store "$url" --verify-path "$FIGLET"

# A build lands in the card's upper layer only.
cat > /tmp/es-built.nix <<NIX
derivation { name = "es-built"; system = builtins.currentSystem; builder = "\${builtins.storePath "$BUSYBOX"}/bin/sh"; args = [ "-c" "echo built > \$out" ]; }
NIX
drv=$(nix-instantiate --store "$url" /tmp/es-built.nix)
out=$(nix-store --store "$url" --realise "$drv")
test -e "/.userdata/nix/upper/$(basename "$out")"
nix-store --store "$url" --verify-path "$out"

# check-mount passes.
nix store info --store "$url&check-mount=true"

# GC deletes the new path, and the tier-1 path's files stay.
nix-collect-garbage --store "$url"
! nix-store --store "$url" --verify-path "$out" 2>/dev/null
test -e "/.lower-userdata/nix-A/upper/$(basename "$FIGLET")"

# The eMMC is byte-identical.
tree /.lower-userdata > /tmp/emmc.after
cmp /tmp/emmc.before /tmp/emmc.after
echo TIER2-OK
