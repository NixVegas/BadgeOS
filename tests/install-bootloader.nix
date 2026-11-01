# The deploy-rs bootloader installer (install-bootloader.nix), generated from stub
# inputs and run in the sandbox against a fake tree: /boot, /.userdata, /proc/cmdline,
# findmnt, mountpoint and df are rewritten to stand-ins under $FAKE.
{ pkgs }:
let
  inherit (pkgs) lib runCommand;
  core = "arm";

  fakeFip = name: builtins.toFile name "fake ${name} contents\n";
  args = {
    inherit pkgs lib core;
    secureBoot = false;
    recoveryFip = fakeFip "fip-arm.bin";
    activeFip = fakeFip "fip.bin";
    fipPath = "/boot/fip.bin";
    emmc = true;
    externalStorage = true;
  };
  scriptText = import ../pkgs/v2/by-name/nix-badge-install-bootloader/install-bootloader.nix args;
  emmcScript = pkgs.writeText "install-sg2k-bootloader-emmc" scriptText;
  noEmmcScript = pkgs.writeText "install-sg2k-bootloader-no-emmc" (
    import ../pkgs/v2/by-name/nix-badge-install-bootloader/install-bootloader.nix (
      args
      // {
        emmc = false;
        externalStorage = false;
      }
    )
  );
  # One core, chain off: no recovery fip.
  singleCoreScript = pkgs.writeText "install-sg2k-bootloader-single-core" (
    import ../pkgs/v2/by-name/nix-badge-install-bootloader/install-bootloader.nix (
      args // { recoveryFip = null; }
    )
  );

  gptScript = pkgs.writeShellScript "install-sg2k-bootloader-gpt-sandboxed" (
    builtins.replaceStrings
      [
        # Kept as they are (replaceStrings tries these first at each position): the
        # generation and slot image names, which contain "/boot" but are not /boot.
        "/boot-image/"
        "/boot.itb"
        "${pkgs.util-linux}/bin/findmnt"
        "${pkgs.util-linux}/bin/mountpoint"
        "${pkgs.coreutils}/bin/df"
        "/.userdata"
        "/proc/cmdline"
        "/boot"
      ]
      [
        "/boot-image/"
        "/boot.itb"
        "$FAKE/bin/findmnt"
        "$FAKE/bin/mountpoint"
        "$FAKE/bin/df"
        "$FAKE/userdata"
        "$FAKE/proc-cmdline"
        "$FAKE/boot"
      ]
      scriptText
  );
in
runCommand "test-install-bootloader" { passthru = { inherit gptScript; }; } ''
  set -u
  fails=0
  fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
  # passed <case>: report ok when the case added no failures (if, not &&: stdenv runs set -e).
  passed() { if [ "$fails" = "$f0" ]; then echo "ok: $1"; fi; }

  # setup <case> <card secure> <generation secure> <slot> [novbmeta|noold|oldprev|nogen|unmounted|nomarker|badmarker|noslot|emptyslot|card|cardnoboot]...
  # card: a data card in use (/.lower-userdata mounted) with its BOOT at $FAKE/boot-card;
  # cardnoboot: the same without a BOOT. $CARD_AVAIL_KIB is what df says the card's BOOT has.
  setup() {
    export FAKE=$PWD/$1
    rm -rf "$FAKE"; mkdir -p "$FAKE/bin" "$FAKE/boot/${core}/slot-A" "$FAKE/boot/${core}/slot-B" "$FAKE/top/boot-image" "$FAKE/boot-card" "$FAKE/userdata"
    printf '#!${pkgs.runtimeShell}\necho squashfs\n' > "$FAKE/bin/findmnt"
    printf '#!${pkgs.runtimeShell}\nfor a; do p=$a; done\ncase $p in /.lower-userdata) exit "$CARD" ;; */boot-card) exit "$CARDBOOT" ;; *) exit "$MOUNTED" ;; esac\n' > "$FAKE/bin/mountpoint"
    printf '#!${pkgs.runtimeShell}\necho Avail; echo "$CARD_AVAIL_KIB"\n' > "$FAKE/bin/df"
    chmod +x "$FAKE/bin/findmnt" "$FAKE/bin/mountpoint" "$FAKE/bin/df"
    export CARD=1 CARDBOOT=1 CARD_AVAIL_KIB=1000000
    printf 'console=ttyS0,115200 rauc.slot=%s init=/init-${core}\n' "$4" > "$FAKE/proc-cmdline"
    printf %s "$2" > "$FAKE/boot/secure"
    for s in A B; do
      printf 'old boot.itb %s\n' $s > "$FAKE/boot/${core}/slot-$s/boot.itb"
      printf 'vbmeta %s\n' $s > "$FAKE/boot/${core}/slot-$s/vbmeta.itb"
    done
    printf 'new generation boot.itb\n' > "$FAKE/top/boot-image/boot.itb"
    printf %s "$3" > "$FAKE/top/boot-image/.secure"
    export MOUNTED=0
    shift 4
    for opt in "$@"; do
      case "$opt" in
        novbmeta) rm "$FAKE/boot/${core}/slot-A/vbmeta.itb" ;;
        noold) rm "$FAKE/boot/${core}/slot-A/boot.itb" ;;
        oldprev) printf 'older boot.itb.prev A\n' > "$FAKE/boot/${core}/slot-A/boot.itb.prev" ;;
        nogen) rm "$FAKE/top/boot-image/boot.itb" ;;
        nomarker) rm "$FAKE/boot/secure" ;;
        badmarker) printf garbage > "$FAKE/boot/secure" ;;
        noslot) printf 'console=ttyS0,115200 init=/init-${core}\n' > "$FAKE/proc-cmdline" ;;
        emptyslot) printf 'console=ttyS0,115200 rauc.slot= init=/init-${core}\n' > "$FAKE/proc-cmdline" ;;
        unmounted) export MOUNTED=1 ;;
        card) export CARD=0 CARDBOOT=0 ;;
        cardnoboot) export CARD=0 CARDBOOT=1 ;;
      esac
    done
  }
  snapshot() { (cd "$FAKE/boot" && find . -printf '%p %y %s\n' | sort && find . -type f -exec sha256sum {} + | sort); }
  run() { rc=0; ${gptScript} "$FAKE/top" > "$FAKE.out" 2> "$FAKE.err" || rc=$?; }
  # refusal <case> <message>: exit 1, the message on stderr, the tree untouched.
  refusal() {
    before=$(snapshot); run; after=$(snapshot)
    [ "$rc" = 1 ] || fail "$1: exit $rc, expected 1"
    grep -qxF -- "$2" "$FAKE.err" || { fail "$1: stderr lacks: $2"; cat "$FAKE.err" >&2; }
    [ "$before" = "$after" ] || { fail "$1: tree changed"; diff <(echo "$before") <(echo "$after") >&2 || true; }
    passed "$1"
  }
  # copied <case> <slot> <expect prev: yes|no>
  copied() {
    d="$FAKE/boot/${core}/slot-$2"
    [ "$rc" = 0 ] || { fail "$1: exit $rc"; cat "$FAKE.err" >&2; }
    cmp -s "$d/boot.itb" "$FAKE/top/boot-image/boot.itb" || fail "$1: slot-$2/boot.itb is not the generation's"
    [ ! -e "$d/boot.itb.new" ] || fail "$1: boot.itb.new left behind"
    [ ! -e "$d/boot.itb.prev.new" ] || fail "$1: boot.itb.prev.new left behind"
    if [ "$3" = yes ]; then
      [ "$(cat "$d/boot.itb.prev" 2>/dev/null)" = "old boot.itb $2" ] || fail "$1: boot.itb.prev is not the old image"
    else
      [ ! -e "$d/boot.itb.prev" ] || fail "$1: unexpected boot.itb.prev"
    fi
    cmp -s "$FAKE/boot/fip.bin" ${args.activeFip} || fail "$1: fip.bin not refreshed"
    [ ! -e "$FAKE/userdata/.nixbadge-cardfit-$2" ] || fail "$1: wrote a data card marker"
  }

  f0=$fails; setup copies-image unsigned unsigned A; run; copied copies-image A yes
  passed copies-image

  f0=$fails; setup copies-image-first unsigned unsigned A noold; run; copied copies-image-first A no
  passed copies-image-first

  f0=$fails; setup copies-image-slot-b unsigned unsigned B; aBefore=$(cd "$FAKE/boot/${core}/slot-A" && sha256sum *)
  run; copied copies-image-slot-b B yes
  [ "$aBefore" = "$(cd "$FAKE/boot/${core}/slot-A" && sha256sum *)" ] || fail "copies-image-slot-b: slot-A changed"
  passed copies-image-slot-b

  f0=$fails; setup drops-old-prev unsigned unsigned A oldprev; run; copied drops-old-prev A yes
  passed drops-old-prev

  # The copy of boot.itb.new fails; by then the older .prev must already be gone.
  f0=$fails; setup drops-prev-before-copy unsigned unsigned A oldprev nogen; run
  d="$FAKE/boot/${core}/slot-A"
  [ "$rc" != 0 ] || fail "drops-prev-before-copy: exit 0 without the generation's boot.itb"
  [ ! -e "$d/boot.itb.prev" ] || fail "drops-prev-before-copy: the older boot.itb.prev was still there when boot.itb.new was written"
  [ "$(cat "$d/boot.itb")" = "old boot.itb A" ] || fail "drops-prev-before-copy: boot.itb changed"
  [ ! -e "$d/boot.itb.new" ] || fail "drops-prev-before-copy: boot.itb.new left behind"
  passed drops-prev-before-copy

  f0=$fails; setup copies-signed-on-secure signed signed A; run; copied copies-signed-on-secure A yes
  passed copies-signed-on-secure

  f0=$fails; setup refuses-unsigned-on-secure signed unsigned A
  refusal refuses-unsigned-on-secure "sg2k: this card is secure-boot but the generation's boot image is unsigned -- refusing"

  f0=$fails; setup refuses-signed-on-plain unsigned signed A
  refusal refuses-signed-on-plain "sg2k: this card is plain (unsigned) but the generation's boot image is signed -- switching secure mode needs a reflash"

  f0=$fails; setup refuses-bad-generation-marker unsigned garbage A
  refusal refuses-bad-generation-marker "sg2k: $FAKE/top/boot-image/.secure is missing or invalid (expected signed|unsigned) -- refusing"

  # A read-only /boot root: the slot copy works (its own directory), the fip refresh's
  # first cp (fip-${core}.bin.new beside fip.bin) fails and must stop the script.
  f0=$fails; setup fip-copy-failure-aborts unsigned unsigned A
  printf 'old fip.bin\n' > "$FAKE/boot/fip.bin"
  chmod a-w "$FAKE/boot"
  run
  chmod u+w "$FAKE/boot"
  [ "$rc" != 0 ] || fail "fip-copy-failure-aborts: exit 0 although the fip copy failed"
  [ "$(cat "$FAKE/boot/fip.bin")" = "old fip.bin" ] || fail "fip-copy-failure-aborts: fip.bin changed"
  if grep -q 'sg2k: updated recovery\|sg2k: refreshed active polyglot' "$FAKE.out"; then
    fail "fip-copy-failure-aborts: reported a fip update that failed: $(cat "$FAKE.out")"
  fi
  passed fip-copy-failure-aborts

  f0=$fails; setup refuses-no-vbmeta unsigned unsigned A novbmeta
  refusal refuses-no-vbmeta "sg2k: this card is not on the FIT layout (no vbmeta.itb in $FAKE/boot/${core}/slot-A); install the RAUC bundle or reflash first"

  f0=$fails; setup refuses-no-boot-mount unsigned unsigned A unmounted
  refusal refuses-no-boot-mount "sg2k: $FAKE/boot is not mounted -- refusing"

  for m in nomarker badmarker; do
    f0=$fails; setup refuses-bad-secure-marker-$m unsigned unsigned A $m
    refusal refuses-bad-secure-marker-$m "sg2k: $FAKE/boot/secure is missing or invalid (expected signed|unsigned) -- refusing"
  done

  for c in noslot emptyslot; do
    f0=$fails; setup refuses-no-slot-$c unsigned unsigned A $c
    refusal refuses-no-slot-$c "sg2k: no valid rauc.slot= on $FAKE/proc-cmdline -- refusing to guess the slot"
  done

  # ---- a data card in use (case 3) ----
  cardfiles() { (cd "$FAKE/boot-card" && find . -type f | sort); }
  # card-boot: the FIT goes to the card's BOOT; /boot (the eMMC's) and its fips are untouched
  f0=$fails; setup card-boot unsigned unsigned A card
  before=$(snapshot); run; after=$(snapshot)
  [ "$rc" = 0 ] || { fail "card-boot: exit $rc"; cat "$FAKE.err" >&2; }
  cmp -s "$FAKE/boot-card/${core}/slot-A/boot.itb" "$FAKE/top/boot-image/boot.itb" || fail "card-boot: the card's slot-A/boot.itb is not the generation's"
  [ "$before" = "$after" ] || { fail "card-boot: /boot changed"; diff <(echo "$before") <(echo "$after") >&2 || true; }
  # (the harness rewrites /boot to $FAKE/boot in the script's messages too)
  grep -qxF "sg2k: data card in use: the eMMC's $FAKE/boot and fips are left as they are" "$FAKE.out" || fail "card-boot: no word about the eMMC"
  # U-Boot boots the card's FIT only while the slot's marker is on the card's EXT_USERDATA
  [ "$(cat "$FAKE/userdata/.nixbadge-cardfit-A" 2>/dev/null)" = "$FAKE/top" ] || fail "card-boot: no marker for slot A"
  # ... the next deploy keeps this one as .prev, still only on the card
  printf 'next generation boot.itb\n' > "$FAKE/top/boot-image/boot.itb"; run
  [ "$rc" = 0 ] && [ "$(cat "$FAKE/boot-card/${core}/slot-A/boot.itb.prev")" = "new generation boot.itb" ] \
    || fail "card-boot: the second deploy did not keep the first as .prev"
  [ "$before" = "$(snapshot)" ] || fail "card-boot: the second deploy changed /boot"
  passed card-boot

  # card-no-boot: a data card without a BOOT cannot take a deploy; nothing is written
  f0=$fails; setup card-no-boot unsigned unsigned A cardnoboot
  refusal card-no-boot "sg2k: deploying with a data card needs a BOOT partition on the card -- refusing"
  [ -z "$(cardfiles)" ] || fail "card-no-boot: the card was written"
  [ ! -e "$FAKE/userdata/.nixbadge-cardfit-A" ] || fail "card-no-boot: marker written"

  # card-boot-full: refused before anything is written ("new generation boot.itb\n" is 24 bytes)
  f0=$fails; setup card-boot-full unsigned unsigned A card; export CARD_AVAIL_KIB=0
  refusal card-boot-full "sg2k: the card's BOOT has 0 bytes free, the boot image needs 24 -- refusing"
  [ -z "$(cardfiles)" ] || fail "card-boot-full: the card was written"
  [ ! -e "$FAKE/userdata/.nixbadge-cardfit-A" ] || fail "card-boot-full: marker written"

  # Without data cards the installer never looks for one.
  f0=$fails
  if grep -q 'lower-userdata\|boot-card' ${noEmmcScript}; then fail "no data cards: the script names a data card"; fi
  passed no-external-storage

  # Without an eMMC there is no boot area to write the fip to.
  f0=$fails
  [ "$(grep -c /dev/fip ${emmcScript})" != 0 ] || fail "emmc: the script never names /dev/fip"
  [ "$(grep -c /dev/fip ${noEmmcScript} || true)" = 0 ] || fail "no-emmc: the script names /dev/fip"
  passed no-emmc-skips-fip

  f0=$fails
  grep -q fip-arm.bin ${emmcScript} || fail "two cores: the script never names fip-arm.bin"
  if grep -q fip-arm.bin ${singleCoreScript}; then fail "single-core: the script names fip-arm.bin"; fi
  passed single-core-no-recovery-fip

  [ "$fails" = 0 ] || { echo "$fails failure(s)" >&2; exit 1; }
  touch $out
''
