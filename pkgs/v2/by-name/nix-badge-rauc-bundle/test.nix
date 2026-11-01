# The bundle hook (./hook.sh) without RAUC: a fake RAUC_* environment, a directory as the
# boot FAT (the hook's /run/rauc paths rewritten to it), and stub mount, umount and df.
# Every successful slot-install must leave the FAT byte-identical.
{
  runCommand,
  runtimeShell,
  gnutar,
}:
runCommand "test-rauc-hook" { nativeBuildInputs = [ gnutar ]; } ''
  set -u
  fails=0
  fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
  passed() { if [ "$fails" = "$f0" ]; then echo "ok: $1"; fi; }

  # mkbundle <dir> <secure word> [omit <path> | big | notar]: a bundle mount point holding
  # boot.tar; big pads riscv/boot.itb (the larger one) to 4 MiB; notar: no boot.tar.
  # $CORES picks the cores (arm riscv by default); $FIP, when set, is fip.bin.
  mkbundle() {
    for core in ''${CORES:-arm riscv}; do
      mkdir -p "$1/src/$core"
      printf 'new boot.itb %s\n' $core > "$1/src/$core/boot.itb"
      printf 'new vbmeta.itb %s\n' $core > "$1/src/$core/vbmeta.itb"
    done
    printf %s "$2" > "$1/src/secure"
    printf %s "$DIGEST" > "$1/src/store.sha256"
    files="$(for core in ''${CORES:-arm riscv}; do printf '%s/boot.itb %s/vbmeta.itb ' $core $core; done)secure store.sha256"
    if [ -n "''${FIP+set}" ]; then printf %s "$FIP" > "$1/src/fip.bin"; files="fip.bin $files"; fi
    if [ "''${3:-}" = omit ]; then files=$(echo "$files" | tr ' ' '\n' | grep -vxF "$4" | tr '\n' ' '); fi
    if [ "''${3:-}" = big ]; then head -c $((4 * 1024 * 1024)) /dev/zero >> "$1/src/riscv/boot.itb"; fi
    if [ "''${3:-}" != notar ]; then (cd "$1/src" && tar -cf "$1/boot.tar" $files); fi
  }

  DIGEST=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
  mkbundle "$PWD/b-unsigned" unsigned
  mkbundle "$PWD/b-signed" signed
  mkbundle "$PWD/b-missing" unsigned omit riscv/vbmeta.itb
  mkbundle "$PWD/b-big" unsigned big
  mkbundle "$PWD/b-notar" unsigned notar
  CORES=riscv mkbundle "$PWD/b-riscv" unsigned
  FIP='new fip' mkbundle "$PWD/b-fip" unsigned

  # setup <case> <card secure: signed|unsigned|none> [extlinux] [oldB] [prevB] [incoming]
  setup() {
    T=$PWD/$1
    rm -rf "$T"; mkdir -p "$T/bin" "$T/fat"
    printf '#!${runtimeShell}\nexit 0\n' > "$T/bin/mount"
    printf '#!${runtimeShell}\nexit 0\n' > "$T/bin/umount"
    printf '#!${runtimeShell}\necho Avail\necho "''${AVAIL_KIB:-1048576}"\n' > "$T/bin/df"
    # mv logs its arguments, so a test can tell the order of the renames.
    printf '#!${runtimeShell}\necho "$*" >> %s/mv.log\nexec %s "$@"\n' "$T" "$(command -v mv)" > "$T/bin/mv"
    chmod +x "$T/bin/"*
    sed -e "s|/run/rauc/nix-badge-bootdev|$T/bootdev|g" -e "s|/run/rauc/nix-badge-boot|$T/fat|g" ${./hook.sh} > "$T/hook.sh"
    if grep -q /run/rauc "$T/hook.sh"; then fail "$1: hook.sh still names /run/rauc after the rewrite"; fi
    [ "$2" = none ] || printf %s "$2" > "$T/fat/secure"
    for core in arm riscv; do
      mkdir -p "$T/fat/$core/slot-A"
      printf 'old boot.itb A %s\n' $core > "$T/fat/$core/slot-A/boot.itb"
      printf 'old boot.itb.prev A %s\n' $core > "$T/fat/$core/slot-A/boot.itb.prev"
      printf 'old vbmeta.itb A %s\n' $core > "$T/fat/$core/slot-A/vbmeta.itb"
    done
    shift 2
    for opt in "$@"; do
      case "$opt" in
        extlinux)
          for core in arm riscv; do
            rm "$T/fat/$core/slot-A/boot.itb" "$T/fat/$core/slot-A/boot.itb.prev" "$T/fat/$core/slot-A/vbmeta.itb"
            mkdir -p "$T/fat/$core/extlinux" "$T/fat/$core/slot-A/nixos" "$T/fat/$core/slot-B/nixos"
            for f in extlinux.conf verity-append extlinux-desktop.conf extlinux-video.conf extlinux-A.conf verity-append-A extlinux-desktop-A.conf extlinux-video-A.conf extlinux-B.conf verity-append-B extlinux-desktop-B.conf extlinux-video-B.conf; do
              printf 'extlinux %s %s\n' $core $f > "$T/fat/$core/extlinux/$f"
            done
            printf 'kernel A\n' > "$T/fat/$core/slot-A/nixos/kernel"
            printf 'kernel B\n' > "$T/fat/$core/slot-B/nixos/kernel"
          done ;;
        oldB)
          for core in arm riscv; do
            mkdir -p "$T/fat/$core/slot-B"
            printf 'old boot.itb B %s\n' $core > "$T/fat/$core/slot-B/boot.itb"
            printf 'old vbmeta.itb B %s\n' $core > "$T/fat/$core/slot-B/vbmeta.itb"
          done ;;
        prevB)
          for core in arm riscv; do
            printf 'old boot.itb.prev B %s\n' $core > "$T/fat/$core/slot-B/boot.itb.prev"
          done ;;
        incoming)
          mkdir -p "$T/fat/.incoming/arm"
          printf 'stale staged boot.itb\n' > "$T/fat/.incoming/arm/boot.itb" ;;
      esac
    done
  }
  snapshot() { (cd "$T/fat" && find . -printf '%p %y %s\n' | sort && find . -type f -exec sha256sum {} + | sort); }
  # stage <bundle>: the boot-class install hook.
  stage() {
    rc=0
    (export PATH="$T/bin:$PATH" RAUC_SLOT_CLASS=boot RAUC_SLOT_DEVICE=/dev/fake-boot0 \
       RAUC_BUNDLE_MOUNT_POINT="$PWD/$1" RAUC_IMAGE_SIZE=$(stat -c %s "$PWD/$1/boot.tar" 2>/dev/null || echo 0)
     sh "$T/hook.sh" slot-install) > "$T.out" 2> "$T.err" || rc=$?
  }
  # stage_ok <case> <bundle>: slot-install succeeds and leaves the FAT byte-identical.
  stage_ok() {
    s0=$(snapshot); stage "$2"; ok_rc "$1 (slot-install)"
    [ "$s0" = "$(snapshot)" ] || { fail "$1: slot-install wrote to the FAT"; diff <(echo "$s0") <(snapshot) >&2 || true; }
  }
  # post <bundle> <slot> <digest>: the nix-class post-install hook.
  post() {
    rc=0
    (export PATH="$T/bin:$PATH" RAUC_SLOT_CLASS=nix RAUC_SLOT_BOOTNAME="$2" RAUC_IMAGE_DIGEST="$3" \
       RAUC_BUNDLE_MOUNT_POINT="$PWD/$1"
     sh "$T/hook.sh" slot-post-install) > "$T.out" 2> "$T.err" || rc=$?
  }
  ok_rc() { [ "$rc" = 0 ] || { fail "$1: exit $rc"; cat "$T.err" >&2; }; }
  # refused <case> <message>: exit 1 with the message on stderr, the FAT as in $before.
  refused() {
    after=$(snapshot)
    [ "$rc" = 1 ] || fail "$1: exit $rc, expected 1"
    grep -qxF -- "$2" "$T.err" || { fail "$1: stderr lacks: $2"; cat "$T.err" >&2; }
    [ "$before" = "$after" ] || { fail "$1: FAT changed"; diff <(echo "$before") <(echo "$after") >&2 || true; }
  }
  # installed <case> <slot> <bundle>: both cores' slot files are the bundle's, nothing
  # else in the slot (no temporaries, no .prev), nothing extracted outside the slots.
  installed() {
    for core in ''${CORES:-arm riscv}; do
      d="$T/fat/$core/slot-$2"
      cmp -s "$d/boot.itb" "$3/src/$core/boot.itb" || fail "$1: $core/slot-$2/boot.itb is not the bundle's"
      cmp -s "$d/vbmeta.itb" "$3/src/$core/vbmeta.itb" || fail "$1: $core/slot-$2/vbmeta.itb is not the bundle's"
      [ "$(ls -A "$d" | tr '\n' ' ')" = "boot.itb vbmeta.itb " ] || fail "$1: $core/slot-$2 holds '$(ls -A "$d" | tr '\n' ' ')'"
    done
    for x in .incoming secure.new fip.bin.new store.sha256 arm/boot.itb arm/vbmeta.itb riscv/boot.itb riscv/vbmeta.itb; do
      [ ! -e "$T/fat/$x" ] || fail "$1: /$x on the FAT"
    done
  }

  # ---- installs-slot-b ----
  f0=$fails; setup installs-slot-b none
  rm -rf "$T/fat/arm" "$T/fat/riscv"
  stage_ok installs-slot-b b-unsigned
  [ "$(cat "$T/bootdev")" = /dev/fake-boot0 ] || fail "installs-slot-b: bootdev not recorded"
  post b-unsigned B "$DIGEST"; ok_rc "installs-slot-b (slot-post-install)"
  installed installs-slot-b B b-unsigned
  for core in arm riscv; do
    [ ! -e "$T/fat/$core/extlinux" ] || fail "installs-slot-b: /$core/extlinux created"
    [ ! -e "$T/fat/$core/slot-A" ] || fail "installs-slot-b: /$core/slot-A created"
  done
  [ "$(od -An -c "$T/fat/secure" | tr -d ' ')" = unsigned ] || fail "installs-slot-b: /secure is not exactly 'unsigned'"
  [ "$(ls -A "$T/fat" | tr '\n' ' ')" = "arm riscv secure " ] || fail "installs-slot-b: FAT root holds '$(ls -A "$T/fat" | tr '\n' ' ')'"
  passed installs-slot-b

  # ---- drops-prev: RAUC keeps no boot.itb.prev ----
  f0=$fails; setup drops-prev unsigned oldB prevB
  aBefore=$(cd "$T/fat" && find arm/slot-A riscv/slot-A -type f -exec sha256sum {} + | sort)
  stage_ok drops-prev b-unsigned
  post b-unsigned B "$DIGEST"; ok_rc "drops-prev (slot-post-install)"
  installed drops-prev B b-unsigned
  [ "$aBefore" = "$(cd "$T/fat" && find arm/slot-A riscv/slot-A -type f -exec sha256sum {} + | sort)" ] \
    || fail "drops-prev: slot A changed (its boot.itb.prev included)"
  passed drops-prev

  # ---- installs-slot-a ----
  f0=$fails; setup installs-slot-a unsigned oldB prevB
  stage_ok installs-slot-a b-unsigned
  post b-unsigned A "$DIGEST"; ok_rc "installs-slot-a (slot-post-install)"
  installed installs-slot-a A b-unsigned
  for core in arm riscv; do
    [ "$(cat "$T/fat/$core/slot-B/boot.itb")" = "old boot.itb B $core" ] || fail "installs-slot-a: $core slot-B/boot.itb changed"
    [ "$(cat "$T/fat/$core/slot-B/boot.itb.prev")" = "old boot.itb.prev B $core" ] || fail "installs-slot-a: $core slot-B/boot.itb.prev changed"
    [ ! -e "$T/fat/$core/extlinux" ] || fail "installs-slot-a: /$core/extlinux created"
  done
  passed installs-slot-a

  # ---- migrates-extlinux-card ----
  f0=$fails; setup migrates-extlinux-card none extlinux
  # What must survive: the shared legacy confs and everything of slot A.
  kept() { (cd "$T/fat" && for core in arm riscv; do
      for x in extlinux.conf verity-append extlinux-desktop.conf extlinux-video.conf extlinux-A.conf verity-append-A extlinux-desktop-A.conf extlinux-video-A.conf; do
        echo "$core/extlinux/$x"; done; done | xargs sha256sum
    find arm/slot-A riscv/slot-A -type f -exec sha256sum {} + | sort); }
  old=$(kept)
  stage_ok migrates-extlinux-card b-unsigned
  post b-unsigned B "$DIGEST"; ok_rc "migrates-extlinux-card (slot-post-install)"
  installed migrates-extlinux-card B b-unsigned
  [ "$old" = "$(kept)" ] || { fail "migrates-extlinux-card: shared or slot-A files changed"; diff <(echo "$old") <(kept) >&2 || true; }
  for core in arm riscv; do
    for x in extlinux/extlinux-B.conf extlinux/verity-append-B extlinux/extlinux-desktop-B.conf extlinux/extlinux-video-B.conf; do
      [ ! -e "$T/fat/$core/$x" ] || fail "migrates-extlinux-card: stale slot-B file $core/$x left"
    done
    left=$(ls "$T/fat/$core/extlinux" | tr '\n' ' ')
    [ "$left" = "extlinux-A.conf extlinux-desktop-A.conf extlinux-desktop.conf extlinux-video-A.conf extlinux-video.conf extlinux.conf verity-append verity-append-A " ] \
      || fail "migrates-extlinux-card: $core/extlinux holds '$left'"
  done
  [ "$(cat "$T/fat/secure")" = unsigned ] || fail "migrates-extlinux-card: /secure not written"
  passed migrates-extlinux-card

  # ---- removes-stale-incoming ----
  f0=$fails; setup removes-stale-incoming unsigned oldB incoming
  stage_ok removes-stale-incoming b-unsigned
  post b-unsigned B "$DIGEST"; ok_rc "removes-stale-incoming (slot-post-install)"
  installed removes-stale-incoming B b-unsigned
  passed removes-stale-incoming

  # ---- refuses-digest-mismatch ----
  f0=$fails; setup refuses-digest-mismatch unsigned oldB prevB
  stage_ok refuses-digest-mismatch b-unsigned
  before=$(snapshot); post b-unsigned B ffff
  refused refuses-digest-mismatch "hook: boot.tar's store.sha256 ($DIGEST) does not match RAUC_IMAGE_DIGEST (ffff) -- refusing"
  passed refuses-digest-mismatch

  # ---- refuses-no-boot-tar ----
  f0=$fails; setup refuses-no-boot-tar unsigned oldB
  before=$(snapshot); post b-notar B "$DIGEST"
  refused refuses-no-boot-tar "hook: no boot.tar in the bundle at $PWD/b-notar -- refusing"
  passed refuses-no-boot-tar

  # ---- secure-mode switches ----
  f0=$fails; setup refuses-signed-on-unsigned unsigned oldB
  before=$(snapshot); stage b-signed
  refused refuses-signed-on-unsigned "hook: bundle is signed but this card is unsigned -- switching secure mode needs a reflash"
  passed refuses-signed-on-unsigned

  f0=$fails; setup refuses-unsigned-on-signed signed oldB
  before=$(snapshot); stage b-unsigned
  refused refuses-unsigned-on-signed "hook: bundle is unsigned but this card is signed -- switching secure mode needs a reflash"
  passed refuses-unsigned-on-signed

  f0=$fails; setup refuses-signed-on-extlinux none extlinux
  before=$(snapshot); stage b-signed
  refused refuses-signed-on-extlinux "hook: card has no /secure (extlinux layout); only an unsigned bundle can migrate it"
  passed refuses-signed-on-extlinux

  # ---- refuses-missing-file ----
  f0=$fails; setup refuses-missing-file unsigned oldB
  before=$(snapshot); stage b-missing
  refused refuses-missing-file "hook: boot.tar lacks riscv/vbmeta.itb -- refusing"
  before=$(snapshot); post b-missing B "$DIGEST"
  refused refuses-missing-file "hook: boot.tar lacks riscv/vbmeta.itb -- refusing"
  passed refuses-missing-file

  # ---- installs-signed-on-signed ----
  f0=$fails; setup installs-signed-on-signed signed oldB prevB
  stage_ok installs-signed-on-signed b-signed
  post b-signed B "$DIGEST"; ok_rc "installs-signed-on-signed (slot-post-install)"
  installed installs-signed-on-signed B b-signed
  [ "$(cat "$T/fat/secure")" = signed ] || fail "installs-signed-on-signed: /secure is not 'signed'"
  passed installs-signed-on-signed

  # ---- free-space guard: both boot.itb + both vbmeta.itb + 16 MiB ----
  itb=$(( $(stat -c %s b-big/src/arm/boot.itb) + $(stat -c %s b-big/src/riscv/boot.itb) ))
  vb=$(( $(stat -c %s b-big/src/arm/vbmeta.itb) + $(stat -c %s b-big/src/riscv/vbmeta.itb) ))
  need=$((itb + vb + 16 * 1024 * 1024))
  # Between vbmeta + margin and the full need: refuse, FAT unchanged.
  f0=$fails; setup refuses-low-space unsigned oldB
  export AVAIL_KIB=$(( (vb + 16 * 1024 * 1024 + itb / 2) / 1024 ))
  before=$(snapshot); stage b-big
  refused refuses-low-space "hook: boot FAT has $((AVAIL_KIB * 1024)) bytes free, need $need (both boot.itb $itb bytes + both vbmeta.itb $vb bytes + 16 MiB margin)"
  passed refuses-low-space
  # Just above the need: slot-install passes and still writes nothing.
  f0=$fails; setup fits-space unsigned oldB
  export AVAIL_KIB=$(( need / 1024 + 1 ))
  stage_ok fits-space b-big
  passed fits-space
  # A stale .incoming/ (1 MiB) is credited as free: 512 KiB short of the need
  # without it, the bundle still stages, and slot-install writes nothing.
  f0=$fails; setup credits-stale-incoming unsigned oldB incoming
  head -c 1048576 /dev/zero > "$T/fat/.incoming/arm/boot.itb"
  export AVAIL_KIB=$(( need / 1024 - 512 ))
  stage_ok credits-stale-incoming b-big
  [ -d "$T/fat/.incoming" ] || fail "credits-stale-incoming: slot-install removed .incoming (it must write nothing)"
  passed credits-stale-incoming
  unset AVAIL_KIB

  # ---- one core: only riscv/slot-B, no arm/ ----
  f0=$fails; setup installs-one-core unsigned
  rm -rf "$T/fat/arm"
  stage_ok installs-one-core b-riscv
  post b-riscv B "$DIGEST"; ok_rc "installs-one-core (slot-post-install)"
  CORES=riscv installed installs-one-core B b-riscv
  [ ! -e "$T/fat/arm" ] || fail "installs-one-core: /arm created"
  passed installs-one-core

  # ---- fip.bin: a new one is written last, through fip.bin.new ----
  f0=$fails; setup writes-new-fip unsigned oldB
  printf 'old fip' > "$T/fat/fip.bin"
  stage_ok writes-new-fip b-fip
  post b-fip B "$DIGEST"; ok_rc "writes-new-fip (slot-post-install)"
  installed writes-new-fip B b-fip
  [ "$(cat "$T/fat/fip.bin")" = "new fip" ] || fail "writes-new-fip: /fip.bin is not the bundle's"
  fipline=$(grep -n ' [^ ]*/fat/fip\.bin$' "$T/mv.log" | cut -d: -f1)
  lastslot=$(grep -n '/slot-B/' "$T/mv.log" | tail -n 1 | cut -d: -f1)
  [ -n "$fipline" ] && [ -n "$lastslot" ] && [ "$fipline" -gt "$lastslot" ] \
    || { fail "writes-new-fip: /fip.bin was not renamed after the slot files"; cat "$T/mv.log" >&2; }
  passed writes-new-fip

  # ---- fip.bin: the same bytes are not rewritten ----
  f0=$fails; setup keeps-same-fip unsigned oldB
  printf 'new fip' > "$T/fat/fip.bin"
  inode=$(stat -c %i "$T/fat/fip.bin")
  stage_ok keeps-same-fip b-fip
  post b-fip B "$DIGEST"; ok_rc "keeps-same-fip (slot-post-install)"
  [ "$(stat -c %i "$T/fat/fip.bin")" = "$inode" ] || fail "keeps-same-fip: /fip.bin was rewritten"
  passed keeps-same-fip

  # ---- fip.bin: a torn write's fip.bin.new is removed ----
  f0=$fails; setup drops-stale-fip-new unsigned oldB
  printf 'new fip' > "$T/fat/fip.bin"
  printf 'torn fip' > "$T/fat/fip.bin.new"
  stage_ok drops-stale-fip-new b-fip
  post b-fip B "$DIGEST"; ok_rc "drops-stale-fip-new (slot-post-install)"
  [ ! -e "$T/fat/fip.bin.new" ] || fail "drops-stale-fip-new: /fip.bin.new is still there"
  [ "$(cat "$T/fat/fip.bin")" = "new fip" ] || fail "drops-stale-fip-new: /fip.bin changed"
  passed drops-stale-fip-new

  if [ "$fails" != 0 ]; then echo "$fails failure(s)" >&2; exit 1; fi
  touch $out
''
