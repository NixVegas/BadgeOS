# stage0.sh in plan mode against fake /proc and /sys, then its per-slot state, init
# choice and factory reset on plain directories (STAGE0_STATE_TEST).
{ runCommand, nix-badge-stage0 }:
runCommand "nix-badge-stage0-test" { } ''
    mk() { # $1=name $2=cmdline $3=with-userdata(1/0)
      d=$1; mkdir -p "$d/proc/self" "$d/sys/dev/block" "$d/sys/block/mmcblk0" "$d/dev"
      printf '%s\n' "$2" > "$d/proc/cmdline"
      printf '1 1 179:3 / / ro - squashfs /dev/root ro\n' > "$d/proc/self/mountinfo"
      ln -s ../../block/mmcblk0/mmcblk0p3 "$d/sys/dev/block/179:3"
      mkdir -p "$d/sys/class/block"; ln -s ../../block/mmcblk0/mmcblk0p3 "$d/sys/class/block/mmcblk0p3"
      printf 'SD\n' > "$d/sys/block/mmcblk0/type"
      for p in 1:BOOT 2:UBOOT 3:NIX_A 4:NIX_B; do
        n=''${p%%:*}; name=''${p#*:}; mkdir -p "$d/sys/block/mmcblk0/mmcblk0p$n"
        printf 'DEVNAME=mmcblk0p%s\nPARTNAME=%s\n' "$n" "$name" > "$d/sys/block/mmcblk0/mmcblk0p$n/uevent"
      done
      if [ "$3" = 1 ]; then mkdir -p "$d/sys/block/mmcblk0/mmcblk0p5"; printf 'DEVNAME=mmcblk0p5\nPARTNAME=USERDATA\n' > "$d/sys/block/mmcblk0/mmcblk0p5/uevent"; fi
    }
    mk a 'console=ttyS0 init=/nix/store/real-init root=PARTUUID=x nixbadge.bootmedium=1 init=/nix/store/stage0' 1
    mk b 'console=ttyS0 init=/nix/store/real-init root=PARTUUID=x init=/nix/store/stage0' 1
    mk c 'init=/nix/store/real-init nixbadge.bootmedium=1 init=/nix/store/stage0' 0
    # d: verity root (dm-0 over mmcblk0p3), stamp = the token after sha256 in dm-mod.create
    # (with the optional-params tail restart_on_corruption, as nix-badge-store-squashfs emits)
    mk d 'init=/nix/store/real-init dm-mod.create="nixroot,,0,ro,0 8 verity 1 PARTUUID=x PARTUUID=x 4096 4096 1 1 sha256 deadbeef 0123 1 restart_on_corruption" root=/dev/dm-0 nixbadge.bootmedium=1 rauc.slot=A init=/nix/store/stage0' 1
    printf '1 1 254:0 / / ro - squashfs /dev/dm-0 ro\n' > d/proc/self/mountinfo
    mkdir -p d/sys/devices/virtual/block/dm-0/slaves/mmcblk0p3; ln -sfn ../../devices/virtual/block/dm-0 d/sys/dev/block/254:0
    mk e 'init=/nix/store/real-init nixbadge.bootmedium=0 rauc.slot=B rauc.external init=/nix/store/stage0' 1
    # STAGE0_DEV stays /dev: plan mode only prints the device paths.
    run() { PATH= STAGE0_PLAN=1 STAGE0_CARD_WAIT=0 STAGE0_ARCH=aarch64 STAGE0_PROC=$PWD/$1/proc STAGE0_SYS=$PWD/$1/sys ${nix-badge-stage0}/bin/nix-badge-stage0; }  # PATH= : only the packaged runtimeInputs, as PID 1 has
    mk f 'init=/init-arm nixbadge.bootmedium=1 rauc.slot=B nixbadge.profile=desktop' 1
    run a > a.out; run b > b.out; run c > c.out; run d > d.out; run e > e.out; run f > f.out
    grep -qx 'disk=mmcblk0 medium=1' a.out
    grep -qx 'userdata=/dev/mmcblk0p5 boot=/dev/mmcblk0p1' a.out
    grep -qx 'overlay-store lowerdir=/nix/.ro-store/nix/store upperdir=/.userdata/nix/upper workdir=/.userdata/nix/work' a.out
    grep -qx 'real-init=/nix/store/real-init' a.out
    grep -qx 'fallback-init=/nix/.ro-store/nix/var/nix/profiles/system-arm/init' a.out
    grep -qx 'nix-state slot=A dir=/.userdata/nix-A bound-at=/.userdata/nix' a.out   # no rauc.slot= -> A
    grep -qx 'disk=mmcblk0 medium=1' b.out          # derived from root's parent disk, SD -> 1
    grep -qx 'userdata=TMPFS boot=/dev/mmcblk0p1' c.out
    grep -q 'no USERDATA partition' c.out
    grep -qx 'disk=mmcblk0 medium=1' d.out          # found through dm-0's slave
    grep -q 'stamp=deadbeef' d.out
    grep -q 'stamp=none' a.out
    grep -qx 'nix-state slot=B dir=/.userdata/nix-B bound-at=/.userdata/nix' e.out
    # the overlay/daemon strings never depend on the slot
    grep -qx 'overlay-store lowerdir=/nix/.ro-store/nix/store upperdir=/.userdata/nix/upper workdir=/.userdata/nix/work' e.out
    # constant init= -> the booted slot's profile link (B here)
    grep -qx 'real-init=/.userdata/nix-B/var/nix/profiles/system-arm/init' f.out

    # ---- data cards: booted from the eMMC (mmcblk1, root on mmcblk1p3) ----
    # mke <name> <cmdline> <the SD's partitions as n:NAME words, or none for no card>
    mke() {
      d=$1; mkdir -p "$d/proc/self" "$d/sys/dev/block" "$d/sys/block/mmcblk1" "$d/sys/class/block" "$d/dev"
      printf '%s\n' "$2" > "$d/proc/cmdline"
      printf '1 1 179:35 / / ro - squashfs /dev/root ro\n' > "$d/proc/self/mountinfo"
      ln -s ../../block/mmcblk1/mmcblk1p3 "$d/sys/dev/block/179:35"
      printf 'MMC\n' > "$d/sys/block/mmcblk1/type"
      for p in 1:BOOT 2:UBOOT 3:NIX_A 4:NIX_B 5:USERDATA; do
        n=''${p%%:*}; name=''${p#*:}; mkdir -p "$d/sys/block/mmcblk1/mmcblk1p$n"
        printf 'DEVNAME=mmcblk1p%s\nPARTNAME=%s\n' "$n" "$name" > "$d/sys/block/mmcblk1/mmcblk1p$n/uevent"
      done
      [ "$3" = none ] && return 0
      mkdir -p "$d/sys/block/mmcblk0"; printf 'SD\n' > "$d/sys/block/mmcblk0/type"
      for p in $3; do
        n=''${p%%:*}; name=''${p#*:}; mkdir -p "$d/sys/block/mmcblk0/mmcblk0p$n"
        printf 'DEVNAME=mmcblk0p%s\nPARTNAME=%s\n' "$n" "$name" > "$d/sys/block/mmcblk0/mmcblk0p$n/uevent"
      done
    }
    on='init=/init-arm nixbadge.bootmedium=0 nixbadge.datacard=1'
    mke nocard "$on" none
    mke card "$on" 1:EXT_USERDATA
    mke cardboot "$on" '1:BOOT 2:EXT_USERDATA'
    mke badgeos "$on" '1:BOOT 2:UBOOT 3:NIX_A 4:NIX_B 5:USERDATA'
    mke converted "$on" '1:BOOT 2:UBOOT 3:NIX_A 4:NIX_B 5:EXT_USERDATA'
    mke nouserdata "$on" '1:BOOT 2:DATA'
    mke disabled 'init=/init-arm nixbadge.bootmedium=0' '1:BOOT 2:EXT_USERDATA'
    mke cardfit "$on nixbadge.cardfit=1" none
    for c in nocard card cardboot badgeos converted nouserdata disabled cardfit; do run $c > $c.out; cat $c.out; done
    # no-card: case 1, the eMMC's own USERDATA
    grep -qx 'disk=mmcblk1 medium=0' nocard.out
    grep -qx 'userdata=/dev/mmcblk1p5 boot=/dev/mmcblk1p1' nocard.out
    grep -qx 'storage=emmc' nocard.out && grep -qx 'card=NONE card-boot=NONE' nocard.out || exit 1
    # data-card: EXT_USERDATA alone, or with a BOOT for deploys
    grep -qx 'storage=card' card.out && grep -qx 'card=/dev/mmcblk0p1 card-boot=NONE' card.out || exit 1
    grep -qx 'storage=card' cardboot.out && grep -qx 'card=/dev/mmcblk0p2 card-boot=/dev/mmcblk0p1' cardboot.out || exit 1
    # badgeos-card: a BadgeOS card (USERDATA, not EXT_USERDATA) is never a data card
    grep -qx 'storage=emmc' badgeos.out && grep -qx 'card=NONE card-boot=NONE' badgeos.out && grep -qx 'card-refused=no EXT_USERDATA partition' badgeos.out || exit 1
    # converted: a BadgeOS card turned into a data card keeps its NIX_A and NIX_B
    grep -qx 'storage=card' converted.out && grep -qx 'card=/dev/mmcblk0p5 card-boot=/dev/mmcblk0p1' converted.out || exit 1
    # card-no-userdata: some other card
    grep -qx 'storage=emmc' nouserdata.out && grep -qx 'card-refused=no EXT_USERDATA partition' nouserdata.out || exit 1
    # disabled: without nixbadge.datacard=1 a data card is not looked at
    grep -qx 'storage=emmc' disabled.out && grep -qx 'card=NONE card-boot=NONE' disabled.out || exit 1
    if grep -q card-refused disabled.out; then echo 'a disabled boot looked at the card' >&2; exit 1; fi
    # cardfit-no-card: U-Boot booted a card's kernel, but there is no data card
    grep -qx 'storage=emmc' cardfit.out
    grep -q 'nixbadge.cardfit=1 but no data card is in use: the kernel is the card'"'"'s, the userland the eMMC'"'"'s' cardfit.out
    # sd-boot: an SD boot is case 2 whatever the cmdline says
    grep -qx 'storage=sd' a.out && grep -qx 'card=NONE card-boot=NONE' a.out || exit 1

    # ---- case 3 mounts ----
    # data-card: the eMMC's USERDATA under the card's, the store two tiers deep
    grep -qx 'lower-userdata=/dev/mmcblk1p5' card.out
    grep -qx 'overlay-store lowerdir=/nix/.lower-store/nix/store upperdir=/.userdata/nix/upper workdir=/.userdata/nix/work' card.out
    grep -qx 'lower-store lowerdir=/.lower-userdata/nix-A/upper:/nix/.ro-store/nix/store at=/nix/.lower-store/nix/store' card.out
    grep -qx 'overlays=/etc,/var,/home,/root lower=/.lower-userdata upper=/.userdata' card.out
    grep -qx 'binds=/tmp noexec, /nix/var exec; tmpfs=/bin,/usr,/lib; stamp=none' card.out
    # the userland follows the FIT U-Boot booted: the eMMC's generation, or the card's with
    # nixbadge.cardfit=1
    grep -qx 'real-init=/.lower-userdata/nix-A/var/nix/profiles/system-arm/init' card.out
    mke cardfitcard "$on nixbadge.cardfit=1" '1:BOOT 2:EXT_USERDATA'
    run cardfitcard > cardfitcard.out; cat cardfitcard.out
    grep -qx 'storage=card' cardfitcard.out
    grep -qx 'real-init=/.userdata/nix-A/var/nix/profiles/system-arm/init' cardfitcard.out
    if grep -q 'nixbadge.cardfit=1 but' cardfitcard.out; then echo 'cardfit flagged with a card' >&2; exit 1; fi
    # a factory reset with a data card names the card
    mke cardreset "$on nixbadge.reset=userdata" '1:BOOT 2:EXT_USERDATA'
    run cardreset > cardreset.out; cat cardreset.out
    grep -qx 'reset=userdata device=/dev/mmcblk0p2' cardreset.out
    # lower-unmountable: the eMMC's USERDATA will not mount read-only -> case 1, saying why
    STAGE0_LOWER_MOUNT_FAILS=1 run card > lowerfail.out; cat lowerfail.out
    grep -qx 'storage=emmc' lowerfail.out && grep -qx 'card=NONE card-boot=NONE' lowerfail.out || exit 1
    grep -qx "card-refused=the eMMC's USERDATA does not mount read-only" lowerfail.out
    grep -qx 'overlay-store lowerdir=/nix/.ro-store/nix/store upperdir=/.userdata/nix/upper workdir=/.userdata/nix/work' lowerfail.out
    if grep -q '^lower-userdata=\|^overlays=' lowerfail.out; then echo 'case 3 lines after the fallback' >&2; exit 1; fi
    # lower-not-ready: the eMMC slot has no state for this image yet (a new install, or a
    # RAUC install into the slot): it is read-only here, so case 1 makes it first
    mkdir -p ready/nix-A/upper ready/nix-A/var/nix/db notready/nix-A/upper
    STAGE0_LOWER=$PWD/ready run card > ready.out; grep -qx 'storage=card' ready.out
    STAGE0_LOWER=$PWD/notready run card > notready.out; cat notready.out
    grep -qx 'storage=emmc' notready.out
    grep -qx "card-refused=the eMMC's slot A has not booted this image without the card yet" notready.out
    echo old > ready/nix-A/.slot-stamp
    STAGE0_LOWER=$PWD/ready run card > stale.out; grep -qx 'storage=emmc' stale.out
    # a factory reset with a data card in formats the card even when this boot then cannot
    # use it, and never the eMMC
    STAGE0_LOWER_MOUNT_FAILS=1 run cardreset > crlf.out; cat crlf.out
    grep -qx 'storage=emmc' crlf.out && grep -qx 'reset=userdata device=/dev/mmcblk0p2' crlf.out || exit 1
    STAGE0_LOWER=$PWD/notready run cardreset > crnr.out; cat crnr.out
    grep -qx 'storage=emmc' crnr.out && grep -qx 'reset=userdata device=/dev/mmcblk0p2' crnr.out || exit 1
    # a card that fails e2fsck after U-Boot booted its FIT: case 1, saying why, and the
    # kernel/userland mismatch flagged
    STAGE0_CARD_FSCK_FAILS=1 run cardfitcard > fsckfail.out; cat fsckfail.out
    grep -qx 'storage=emmc' fsckfail.out
    grep -qx "card-refused=e2fsck -p on the data card's /dev/mmcblk0p2 returned 4" fsckfail.out
    grep -q 'nixbadge.cardfit=1 but no data card is in use' fsckfail.out
    # cases 1 and 2 print what they always did, plus the storage lines
    printf '%s\n' 'disk=mmcblk1 medium=0' 'userdata=/dev/mmcblk1p5 boot=/dev/mmcblk1p1' 'storage=emmc' \
      'card=NONE card-boot=NONE' 'reset=none' 'nix-state slot=A dir=/.userdata/nix-A bound-at=/.userdata/nix' \
      'overlay-store lowerdir=/nix/.ro-store/nix/store upperdir=/.userdata/nix/upper workdir=/.userdata/nix/work' \
      'binds=/etc,/var,/tmp,/home,/root noexec, /nix/var exec; tmpfs=/bin,/usr,/lib; stamp=none' \
      'real-init=/.userdata/nix-A/var/nix/profiles/system-arm/init' \
      'fallback-init=/nix/.ro-store/nix/var/nix/profiles/system-arm/init' > case1.want
    diff -u case1.want nocard.out
    printf '%s\n' 'disk=mmcblk0 medium=1' 'userdata=/dev/mmcblk0p5 boot=/dev/mmcblk0p1' 'storage=sd' \
      'card=NONE card-boot=NONE' 'reset=none' 'nix-state slot=A dir=/.userdata/nix-A bound-at=/.userdata/nix' \
      'overlay-store lowerdir=/nix/.ro-store/nix/store upperdir=/.userdata/nix/upper workdir=/.userdata/nix/work' \
      'binds=/etc,/var,/tmp,/home,/root noexec, /nix/var exec; tmpfs=/bin,/usr,/lib; stamp=none' \
      'real-init=/nix/store/real-init' 'fallback-init=/nix/.ro-store/nix/var/nix/profiles/system-arm/init' > case2.want
    diff -u case2.want a.out

    # ---- STAGE0_STATE_TEST: per-slot USERDATA state + init choice ----
    ro=$PWD/ro; mkdir -p "$ro/nix/var/nix/profiles" "$ro/nix/store/gen0"
    printf '#!/bin/sh\n' > "$ro/nix/store/gen0/init"; chmod +x "$ro/nix/store/gen0/init"
    ln -s ../../../store/gen0 "$ro/nix/var/nix/profiles/system-arm-1-link"
    ln -s system-arm-1-link "$ro/nix/var/nix/profiles/system-arm"
    mkdir -p bin; printf '#!/bin/sh\n' > bin/real-init; chmod +x bin/real-init
    st() { # $1=userdata dir $2=cmdline -> stdout
      mkdir -p "st-proc"; printf '%s\n' "$2" > st-proc/cmdline
      PATH= STAGE0_STATE_TEST=1 STAGE0_ARCH=aarch64 STAGE0_PROC=$PWD/st-proc STAGE0_USERDATA=$1 STAGE0_ROSTORE=$ro \
        ${nix-badge-stage0}/bin/nix-badge-stage0
    }
    frag() { printf 'dm-mod.create="nixroot,,0,ro,0 8 verity 1 PARTUUID=x PARTUUID=x 4096 4096 1 1 sha256 %s 0123 1 restart_on_corruption"' "$1"; }
    okinit="init=$PWD/bin/real-init"

    # fresh: empty USERDATA, no rauc.slot= -> slot A
    ud=$PWD/ud-fresh; mkdir -p "$ud"
    st "$ud" "$okinit $(frag h1) init=/stage0" > fresh.out; cat fresh.out
    grep -qx 'slot=A stamp=h1' fresh.out
    test -d "$ud/nix-A/upper" && test -d "$ud/nix-A/work" && test -d "$ud/nix" && test -L "$ud/nix-A/var/nix/profiles/system-arm" || exit 1
    test -z "$(ls -A "$ud/nix")"                                    # the bind target stays empty
    grep -qx "chosen-init=$PWD/bin/real-init" fresh.out

    # migrate: a single-slot card's shared nix/ (with a deployed generation) and stamp
    ud=$PWD/ud-mig; mkdir -p "$ud/nix/upper/deployed-gen" "$ud/nix/work" "$ud/nix/var/nix/profiles"
    echo h1 > "$ud/.slot-stamp"
    st "$ud" "$okinit $(frag h1) init=/stage0" > mig.out; cat mig.out
    grep -q 'migrating the shared Nix state' mig.out
    grep -qx 'slot=A stamp=h1' mig.out
    test -d "$ud/nix-A/upper/deployed-gen"                          # moved, not reset
    test ! -e "$ud/.slot-stamp" && test "$(cat "$ud/nix-A/.slot-stamp")" = h1 || exit 1
    test -d "$ud/nix" && test -z "$(ls -A "$ud/nix")" || exit 1
    # a second boot does not migrate again
    st "$ud" "$okinit $(frag h1) rauc.slot=A init=/stage0" > mig2.out
    if grep -q 'migrating' mig2.out; then echo 'migrated twice' >&2; exit 1; fi
    test -d "$ud/nix-A/upper/deployed-gen"

    # switch + rollback: deploy-rs state in slot A, then slot B boots a
    # different image (another root hash), then A is forced again
    ud=$PWD/ud-c1; mkdir -p "$ud"
    st "$ud" "$okinit $(frag hA) rauc.slot=A init=/stage0" > /dev/null
    mkdir -p "$ud/nix-A/upper/deployed-gen"
    st "$ud" "$okinit $(frag hB) rauc.slot=B init=/stage0" > c1b.out; cat c1b.out
    grep -qx 'slot=B stamp=hB' c1b.out
    test -d "$ud/nix-A/upper/deployed-gen"                          # B's boot left A alone
    test "$(cat "$ud/nix-A/.slot-stamp")" = hA
    st "$ud" "$okinit $(frag hA) rauc.slot=A init=/stage0" > c1a.out; cat c1a.out
    grep -qx 'slot=A stamp=hA' c1a.out
    if grep -q 'resetting' c1a.out; then echo 'rollback into A reset its state' >&2; exit 1; fi
    test -d "$ud/nix-A/upper/deployed-gen"                          # still there after the rollback

    # reset-one-slot: a new image in A resets nix-A only
    mkdir -p "$ud/nix-B/upper/b-gen"
    st "$ud" "$okinit $(frag hA2) rauc.slot=A init=/stage0" > reset.out; cat reset.out
    grep -q "slot A store changed (hA -> hA2)" reset.out
    test ! -e "$ud/nix-A/upper/deployed-gen"
    test -L "$ud/nix-A/var/nix/profiles/system-arm"                 # re-seeded
    test -d "$ud/nix-B/upper/b-gen" && test "$(cat "$ud/nix-B/.slot-stamp")" = hB || exit 1

    # init fallback: the first init= names a generation that is not there
    st "$ud" "init=$PWD/bin/gone-init $(frag hA2) rauc.slot=A init=/stage0" > fb.out 2> fb.err; cat fb.out fb.err
    grep -qx "chosen-init=$ro/nix/var/nix/profiles/system-arm/init" fb.out
    grep -q 'is not executable' fb.err

    # ---- boot profiles (nixbadge.profile=) ----
    top=$PWD/top; mkdir -p "$top/specialisation/desktop"
    for i in "$top/init" "$top/specialisation/desktop/init"; do printf '#!/bin/sh\n' > "$i"; chmod +x "$i"; done
    # profile-desktop: the chosen toplevel has the specialisation
    st "$ud" "init=$top/init $(frag hA2) rauc.slot=A nixbadge.profile=desktop init=/stage0" > pd.out 2> pd.err; cat pd.out pd.err
    grep -qx "chosen-init=$top/specialisation/desktop/init" pd.out
    # profile-absent: no specialisation video -> the base init, logged
    st "$ud" "init=$top/init $(frag hA2) rauc.slot=A nixbadge.profile=video init=/stage0" > pa.out 2> pa.err; cat pa.out pa.err
    grep -qx "chosen-init=$top/init" pa.out
    grep -q 'no specialisation video, booting the base system$' pa.err
    # profile-default: the base init, no specialisation lookup logged
    st "$ud" "init=$top/init $(frag hA2) rauc.slot=A nixbadge.profile=default init=/stage0" > pdef.out 2> pdef.err; cat pdef.out pdef.err
    grep -qx "chosen-init=$top/init" pdef.out
    if grep -q specialisation pdef.err; then echo 'profile default looked up a specialisation' >&2; exit 1; fi
    # profile-link: init=/init-arm -> slot A's profile link (deploy-rs pointed it at $top),
    # then its desktop specialisation
    ln -sfn "$top" "$ud/nix-A/var/nix/profiles/system-arm"
    st "$ud" "init=/init-arm $(frag hA2) rauc.slot=A nixbadge.profile=desktop" > pl.out 2> pl.err; cat pl.out pl.err
    grep -qx "chosen-init=$ud/nix-A/var/nix/profiles/system-arm/specialisation/desktop/init" pl.out
    # profile-path: ../evil is not a profile name; the base init boots even though
    # $top/evil/init is executable
    mkdir -p "$top/evil"; printf '#!/bin/sh\n' > "$top/evil/init"; chmod +x "$top/evil/init"
    st "$ud" "init=$top/init $(frag hA2) rauc.slot=A nixbadge.profile=../evil init=/stage0" > pp.out 2> pp.err; cat pp.out pp.err
    grep -qx "chosen-init=$top/init" pp.out
    grep -q 'nixbadge.profile=../evil is not a profile name, booting the base system$' pp.err
    # ---- factory reset (nixbadge.reset=userdata, both buttons at power-up) ----
    # reset-plan: the USERDATA partition; refused without one, none without the argument
    mk g 'init=/init-arm nixbadge.bootmedium=1 nixbadge.reset=userdata' 1
    mk h 'init=/init-arm nixbadge.bootmedium=1 nixbadge.reset=userdata' 0
    run g > g.out; run h > h.out
    grep -qx 'reset=userdata device=/dev/mmcblk0p5' g.out
    grep -qx 'reset=refused' h.out
    for o in a b c d e f; do grep -qx 'reset=none' $o.out; done
    # reset-fresh: a fresh filesystem (the stub logs its arguments and empties the
    # directory), then the usual boot
    filled() {
      mkdir -p "$1/lost+found/kept" "$1/nix-A/upper/deployed-gen" "$1/nix-B/var" "$1/etc/ssh" "$1/home/badge" "$1/.hidden-dir" "$1/..odd"
      echo key > "$1/etc/ssh/ssh_host_ed25519_key"; echo h1 > "$1/nix-A/.slot-stamp"; touch "$1/.dotfile"
      ln -s /nowhere "$1/dangling"
    }
    cat > bin/mkfs-stub <<'EOF'
  #!/bin/sh
  printf '%s\n' "$*" >> "$MKFS_LOG"
  rm -rf "$STAGE0_USERDATA"/* "$STAGE0_USERDATA"/.[!.]* "$STAGE0_USERDATA"/..?*
  mkdir -p "$STAGE0_USERDATA/lost+found"
  EOF
    printf '#!/bin/sh\nexit 1\n' > bin/mkfs-fail; chmod +x bin/mkfs-stub bin/mkfs-fail
    export STAGE0_MKFS=$PWD/bin/mkfs-stub MKFS_LOG=$PWD/mkfs.log; : > mkfs.log
    ud=$PWD/ud-reset; filled "$ud"
    STAGE0_USERDATA_DEV=/dev/mmcblk0p5 st "$ud" "$okinit $(frag h1) nixbadge.reset=userdata init=/stage0" > rw.out; cat rw.out
    grep -q 'factory reset: making a fresh filesystem on USERDATA (/dev/mmcblk0p5)' rw.out
    grep -q 'factory reset: USERDATA is a fresh filesystem' rw.out
    test "$(cat mkfs.log)" = '-F -q -L USERDATA -- /dev/mmcblk0p5'
    test ! -e "$ud/lost+found/kept"
    test "$(ls -A "$ud" | sort | tr '\n' ' ')" = "lost+found nix nix-A "   # only what slot_state re-created
    test ! -e "$ud/nix-A/upper/deployed-gen" && test -L "$ud/nix-A/var/nix/profiles/system-arm" || exit 1
    grep -qx 'slot=A stamp=h1' rw.out
    grep -qx "chosen-init=$PWD/bin/real-init" rw.out
    # reset-absent: the same USERDATA without the argument is left alone
    ud=$PWD/ud-keep; filled "$ud"
    STAGE0_USERDATA_DEV=/dev/mmcblk0p5 st "$ud" "$okinit $(frag h1) init=/stage0" > rk.out; cat rk.out
    if grep -q 'factory reset' rk.out; then echo 'reset without nixbadge.reset' >&2; exit 1; fi
    test "$(wc -l < mkfs.log)" = 1
    test -f "$ud/etc/ssh/ssh_host_ed25519_key" && test -d "$ud/nix-A/upper/deployed-gen" && test -L "$ud/dangling" && test -e "$ud/.dotfile" || exit 1
    # reset-refused: no USERDATA partition identified -> nothing reset, the boot goes on
    ud=$PWD/ud-refuse; filled "$ud"
    st "$ud" "$okinit $(frag h1) nixbadge.reset=userdata init=/stage0" > rr.out; cat rr.out
    grep -q 'factory reset requested, but the booted disk has no USERDATA partition' rr.out
    test "$(wc -l < mkfs.log)" = 1
    test -f "$ud/etc/ssh/ssh_host_ed25519_key" && test -d "$ud/nix-A/upper/deployed-gen" || exit 1
    grep -qx "chosen-init=$PWD/bin/real-init" rr.out
    # reset-unknown: another nixbadge.reset= value resets nothing
    ud=$PWD/ud-unknown; filled "$ud"
    STAGE0_USERDATA_DEV=/dev/mmcblk0p5 st "$ud" "$okinit $(frag h1) nixbadge.reset=everything init=/stage0" > ru.out; cat ru.out
    grep -q 'unknown nixbadge.reset=everything' ru.out
    test "$(wc -l < mkfs.log)" = 1
    test -f "$ud/etc/ssh/ssh_host_ed25519_key"
    # reset-mkfs-fails: a failing mkfs.ext4 (the stub writes nothing) and the boot goes on
    ud=$PWD/ud-mkfs-fails; filled "$ud"
    STAGE0_USERDATA_DEV=/dev/mmcblk0p5 STAGE0_MKFS=$PWD/bin/mkfs-fail st "$ud" "$okinit $(frag h1) nixbadge.reset=userdata init=/stage0" > rf.out; cat rf.out
    grep -q 'factory reset: mkfs.ext4 /dev/mmcblk0p5 failed; booting with whatever USERDATA holds' rf.out
    test -f "$ud/etc/ssh/ssh_host_ed25519_key" && test -d "$ud/nix-A/upper/deployed-gen" && test -d "$ud/lost+found/kept" || exit 1
    grep -qx 'slot=A stamp=h1' rf.out
    grep -qx "chosen-init=$PWD/bin/real-init" rf.out

    # ---- data card state (case 3: STAGE0_CARD_DEV is the card's EXT_USERDATA, the
    # directory passed is the card's, STAGE0_LOWER the eMMC's) ----
    lower=$PWD/lower; mkdir -p "$lower/nix-A/var/nix/db"; echo db1 > "$lower/nix-A/var/nix/db/db.sqlite"
    echo h1 > "$lower/nix-A/.slot-stamp"
    cst() { # $1=card dir $2=cid $3=fs uuid $4=stamp, then extra cmdline words; $cb: the card's BOOT
      c=$1 i=$2 u=$3 h=$4; shift 4
      STAGE0_CARD_DEV=/dev/mmcblk0p2 STAGE0_CARD_BOOT_DEV=''${cb-/dev/mmcblk0p1} STAGE0_LOWER=$lower STAGE0_LOWER_CID=$i STAGE0_LOWER_FSUUID=$u \
        st "$c" "$okinit $(frag "$h") rauc.slot=A $* init=/stage0"
    }
    tree() { (cd "$1" && find . | sort && find . -type f -exec cat {} +); }
    # fresh-card: no fingerprint -> written, nothing reset
    card=$PWD/card; mkdir -p "$card/etc" "$card/home/badge"
    cst "$card" cid1 u1 h1 > cf.out; cat cf.out
    grep -qx 'storage=card card-state=fresh' cf.out
    grep -qx 'cid=cid1' "$card/.nixbadge-lower" && grep -qx 'fsuuid=u1' "$card/.nixbadge-lower" || exit 1
    grep -qx 'slot=A' "$card/nix-A/.nixbadge-lower" && grep -qx 'stamp=h1' "$card/nix-A/.nixbadge-lower" || exit 1
    grep -qx 'nixdb=[0-9a-f]\{64\}' "$card/nix-A/.nixbadge-lower"
    test ! -e "$card/.nixbadge-card-boot-reset"
    # converted: a BadgeOS card made a data card keeps its files, not its old system's
    # Nix state (same squashfs stamp or not)
    conv=$PWD/conv; mkdir -p "$conv/etc/ssh" "$conv/nix-A/upper/sd-gen" "$conv/nix-A/var/nix/db" "$conv/nix-B/upper/sd-b"
    echo key > "$conv/etc/ssh/ssh_host_ed25519_key"; echo sd > "$conv/nix-A/var/nix/db/db.sqlite"; echo h1 > "$conv/nix-A/.slot-stamp"
    cst "$conv" cid1 u1 h1 > cconv.out; cat cconv.out
    grep -qx 'storage=card card-state=fresh' cconv.out
    grep -q 'the data card holds slot A Nix state from before it was a data card' cconv.out
    test ! -e "$conv/nix-A/upper/sd-gen" && test ! -e "$conv/nix-B" && test ! -s "$conv/nix-A/var/nix/db/db.sqlite" || exit 1
    test -f "$conv/etc/ssh/ssh_host_ed25519_key" && test ! -e "$conv/.nixbadge-card-boot-reset" || exit 1
    grep -qx 'stamp=h1' "$conv/nix-A/.nixbadge-lower"
    # same: every field matches -> nothing reset
    # (and a deploy's markers: U-Boot boots the card's FIT for a slot only while its
    # .nixbadge-cardfit-<slot> is there)
    mkdir -p "$card/nix-A/upper/card-gen" "$card/nix-B/upper/b-gen"; echo b > "$card/nix-B/.nixbadge-lower"
    for s in A B; do echo gen > "$card/.nixbadge-cardfit-$s"; done
    cst "$card" cid1 u1 h1 > cs.out; cat cs.out
    grep -qx 'storage=card card-state=same' cs.out
    test -d "$card/nix-A/upper/card-gen" && test ! -e "$card/.nixbadge-card-boot-reset" || exit 1
    test -e "$card/.nixbadge-cardfit-A" && test -e "$card/.nixbadge-cardfit-B" || exit 1
    # foreign: another eMMC's CID -> case 1, the card untouched
    cp -a "$card" foreign; tree foreign > foreign.before
    cst "$PWD/foreign" cid2 u1 h1 > cfo.out; cat cfo.out
    grep -qx 'storage=emmc card-state=foreign' cfo.out && grep -qx 'card-refused=another badge' cfo.out || exit 1
    tree foreign > foreign.after; cmp foreign.before foreign.after
    # emmc-reset: a new eMMC USERDATA -> both slots' Nix layers reset, the rest kept
    cp -a "$card" er
    cst "$PWD/er" cid1 u2 h1 > cer.out; cat cer.out
    grep -qx 'storage=card card-state=reset' cer.out
    test ! -e er/nix-A/upper/card-gen && test ! -e er/nix-B/upper/b-gen && test -d er/etc && test -d er/home/badge || exit 1
    test "$(cat er/.nixbadge-card-boot-reset)" = "$(printf 'A\nB')"
    test ! -e er/.nixbadge-cardfit-A && test ! -e er/.nixbadge-cardfit-B || exit 1
    grep -qx 'fsuuid=u2' er/.nixbadge-lower
    # new-image: another squashfs stamp -> this slot's Nix layer only
    cp -a "$card" ni
    cst "$PWD/ni" cid1 u1 h2 > cni.out; cat cni.out
    grep -qx 'storage=card card-state=reset' cni.out
    test ! -e ni/nix-A/upper/card-gen && test -d ni/nix-B/upper/b-gen && test -d ni/home/badge || exit 1
    test "$(cat ni/.nixbadge-card-boot-reset)" = A
    grep -qx 'stamp=h2' ni/nix-A/.nixbadge-lower
    test ! -e ni/.nixbadge-cardfit-A && test -e ni/.nixbadge-cardfit-B || exit 1
    # ... and when U-Boot booted the card's FIT for that slot, this boot says so
    cp -a "$card" nifit
    cst "$PWD/nifit" cid1 u1 h2 nixbadge.cardfit=1 > cnifit.out; cat cnifit.out
    grep -q "this boot runs the eMMC's generation on the card's kernel" cnifit.out
    if grep -q "card's kernel" cni.out; then echo 'a reset without cardfit flagged a mismatch' >&2; exit 1; fi
    # nix-changed: the eMMC slot's database changed without the card (a deploy or a GC)
    cp -a "$card" nc; echo db2 > "$lower/nix-A/var/nix/db/db.sqlite"
    cst "$PWD/nc" cid1 u1 h1 > cnc.out; cat cnc.out
    grep -qx 'storage=card card-state=reset' cnc.out
    test ! -e nc/nix-A/upper/card-gen && test -d nc/nix-B/upper/b-gen && test "$(cat nc/.nixbadge-card-boot-reset)" = A || exit 1
    test ! -e nc/.nixbadge-cardfit-A
    echo db1 > "$lower/nix-A/var/nix/db/db.sqlite"
    # no-card-boot: a card without a BOOT has no boot images to drop, so no list
    cp -a "$card" nb
    cb= cst "$PWD/nb" cid1 u1 h2 > cnb.out; cat cnb.out
    grep -qx 'storage=card card-state=reset' cnb.out && test ! -e nb/nix-A/upper/card-gen || exit 1
    test ! -e nb/.nixbadge-card-boot-reset
    # reset-card-only: a factory reset with a data card formats the card, never the eMMC
    : > mkfs.log; cp -a "$card" rc
    STAGE0_USERDATA_DEV=/dev/mmcblk1p5 STAGE0_USERDATA=$PWD/rc cst "$PWD/rc" cid1 u1 h1 nixbadge.reset=userdata > crc.out; cat crc.out
    test "$(cat mkfs.log)" = '-F -q -L EXT_USERDATA -- /dev/mmcblk0p2'
    grep -qx 'storage=card card-state=fresh' crc.out
    test ! -e rc/nix-A/upper/card-gen
    # card-seed: a new card's slot state starts from the eMMC slot's profiles (its deployed
    # generations), and init=/init-arm boots the eMMC's generation
    mkdir -p "$lower/nix-A/var/nix/profiles" "$lower/gen1"
    printf '#!/bin/sh\n' > "$lower/gen1/init"; chmod +x "$lower/gen1/init"
    ln -s "$lower/gen1" "$lower/nix-A/var/nix/profiles/system-arm"
    seed=$PWD/seed; mkdir -p "$seed"
    seedrun() { # $1 = extra cmdline words
      STAGE0_CARD_DEV=/dev/mmcblk0p2 STAGE0_LOWER=$lower STAGE0_LOWER_CID=cid1 STAGE0_LOWER_FSUUID=u1 \
        st "$seed" "init=/init-arm $(frag h1) rauc.slot=A $1"
    }
    seedrun "" > seed.out 2>&1; cat seed.out
    test "$(readlink "$seed/nix-A/var/nix/profiles/system-arm")" = "$lower/gen1"
    grep -qx "chosen-init=$lower/nix-A/var/nix/profiles/system-arm/init" seed.out
    # ... and with nixbadge.cardfit=1, the card's own profile link (a deploy moved it)
    ln -sfn "$top" "$seed/nix-A/var/nix/profiles/system-arm"
    seedrun nixbadge.cardfit=1 > seedfit.out 2>&1; cat seedfit.out
    grep -qx "chosen-init=$seed/nix-A/var/nix/profiles/system-arm/init" seedfit.out
    touch "$out"
''
