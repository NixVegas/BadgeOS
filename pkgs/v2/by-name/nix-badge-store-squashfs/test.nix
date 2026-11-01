# The verified-boot outputs of a fake-closure store image (tests/fixtures.nix): an
# /init-<core> link and a system-<core> profile for each core of stage0s and none for
# the others, and a vbmeta.itb whose frag, sourced in the sandbox U-Boot, sets
# verityargs to the expanded verity fragment.
{
  lib,
  runCommand,
  squashfsTools,
  ubootTools,
  dtc,
  storeImage,
  # { <core> = stage-0; } for the image's cores
  stage0s,
  sandbox,
}:
let
  absent = lib.subtractLists (lib.attrNames stage0s) [
    "arm"
    "riscv"
  ];
in
runCommand "store-squashfs-test"
  {
    nativeBuildInputs = [
      squashfsTools
      ubootTools
      dtc
    ];
  }
  ''
    set -euo pipefail
    fail() { echo "FAIL: $*" >&2; exit 1; }
    img=${storeImage}/store.img

    # init-symlinks and profiles
    ls=$(unsquashfs -lls "$img" init-arm init-riscv nix/var/nix/profiles)
    echo "$ls"
    ${lib.concatStrings (
      lib.mapAttrsToList (core: stage0: ''
        echo "$ls" | grep -q ' squashfs-root/init-${core} -> ${stage0}/bin/nix-badge-stage0$' \
          || fail "init-${core} does not point at the ${core} nix-badge-stage0"
        echo "$ls" | grep -qE '^l.* squashfs-root/init-${core} -> /nix/store/[a-z0-9]{32}-[^/]*nix-badge-stage0/bin/nix-badge-stage0$' \
          || fail "init-${core} is not a symlink into a nix-badge-stage0 store path"
        echo "$ls" | grep -q ' squashfs-root/nix/var/nix/profiles/system-${core} -> system-${core}-1-link$' \
          || fail "no system-${core} profile"
        p=nix/store/$(basename ${stage0})/bin/nix-badge-stage0
        unsquashfs -ls "$img" "$p" | grep -qx "squashfs-root/$p" || fail "$p is not in the image"
      '') stage0s
    )}
    ${lib.concatMapStrings (core: ''
      if echo "$ls" | grep -q ' squashfs-root/init-${core} \| squashfs-root/nix/var/nix/profiles/system-${core} '; then
        fail "the image has an init-${core} or system-${core} for a core it does not boot"
      fi
    '') absent}

    # vbmeta-shape
    test -f ${storeImage}/vbmeta.itb || fail "no vbmeta.itb"
    dumpimage -l ${storeImage}/vbmeta.itb > list.txt
    cat list.txt
    grep -qx ' Image 0 (frag)' list.txt || fail "vbmeta.itb has no image frag"
    grep -q 'Type: *Script' list.txt || fail "frag is not a script image"
    if grep -q ' Image 1 ' list.txt; then fail "vbmeta.itb has more than one image"; fi

    # vbmeta-text
    dumpimage -T flat_dt -p 0 -o frag.txt ${storeImage}/vbmeta.itb
    cat frag.txt; echo
    grep -q 'restart_on_corruption' frag.txt || fail "frag lacks restart_on_corruption"
    [ "$(grep -o 'PARTUUID=''${nixroot}' frag.txt | wc -l)" = 2 ] \
      || fail "frag does not carry the literal PARTUUID=\''${nixroot} twice"
    [ "$(grep -o setenv frag.txt | wc -l)" = 1 ] && grep -q '^setenv verityargs ' frag.txt \
      || fail "frag does something besides setting verityargs"
    [ "$(tail -c 1 frag.txt | od -An -c | tr -d ' ')" != '\n' ] || fail "frag ends in a newline"

    # vbmeta-roothash-matches-image
    roothash=$(cat ${storeImage}/roothash)
    [ ''${#roothash} = 64 ] || fail "roothash is not a sha256"
    [ "$(grep -o ' sha256 [0-9a-f]* ' frag.txt)" = " sha256 $roothash " ] \
      || fail "vbmeta-roothash-matches-image: the frag's root hash is not $roothash"

    # vbmeta-sources: an empty control DTB (no required keys), so the unsigned FIT
    # passes on its hash alone
    echo '/dts-v1/; / { };' | dtc -I dts -O dtb -o empty.dtb
    log=$(timeout 60 ${sandbox}/bin/u-boot -d empty.dtb -c \
      "setenv nixroot 01234567-89ab-cdef-0123-456789abcdef; host load hostfs - 0x1000000 ${storeImage}/vbmeta.itb; source 0x1000000:frag && printenv verityargs" 2>&1 | tr -d '\r')
    echo "$log"
    want="verityargs=$(sed 's/''${nixroot}/01234567-89ab-cdef-0123-456789abcdef/g' ${storeImage}/verity-append)"
    # (`source` prints its hash check, "sha256+ ", on the same line, unterminated)
    printf '%s\n' "$log" | sed -n 's/^.*\(verityargs=.*\)$/\1/p' | grep -qxF "$want" || fail "the sourced frag did not set verityargs to the expanded fragment"

    mkdir $out
    cp list.txt frag.txt $out/
  ''
