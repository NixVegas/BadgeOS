# The boot partition tree (nix-badge-boot-dir) from fixture images:
#   - the tree is exactly the slot-A FIT layout, slot B's copy of it, the fips and
#     /secure, the marker follows the images' .secure, dumpimage reads boot.itb, and
#     markers that disagree (one core, or the vbmeta) fail the build;
#   - a riscv-only tree has no arm/ and no recovery fips;
#   - nix-badge-emmc-init --plan over that tree lists the checked copies, and refuses a
#     tree without arm/slot-A/vbmeta.itb.
{
  runCommand,
  testers,
  ubootTools,
  dtc,
  nix-badge-boot-dir,
  nix-badge-emmc-init,
}:
let
  mkBoot = nix-badge-boot-dir;
  emmcInit = nix-badge-emmc-init;

  fips = {
    fip = builtins.toFile "fip.bin" "fixture polyglot fip\n";
    recoveryFips = {
      arm = builtins.toFile "fip-arm.bin" "fixture arm fip\n";
      riscv = builtins.toFile "fip-riscv.bin" "fixture riscv fip\n";
    };
  };

  # A script-only FIT with a .secure marker, the shape of makeBootImage's and
  # signFit's outputs. The marker is just the file: these are never verified.
  fakeFit =
    file: tag: marker:
    runCommand "boot-dir-fixture-${tag}-${marker}"
      {
        nativeBuildInputs = [
          ubootTools
          dtc
        ];
      }
      ''
        mkdir $out
        printf 'echo ${tag}' > s.txt
        cat > f.its <<'EOF'
        /dts-v1/;
        / {
          description = "boot-dir fixture ${tag}";
          #address-cells = <1>;
          images {
            script-default {
              data = /incbin/("s.txt");
              type = "script";
              compression = "none";
              hash-1 { algo = "sha256"; };
            };
          };
          configurations { };
        };
        EOF
        mkimage -f f.its $out/${file}
        echo ${marker} > $out/.secure
      '';
  bootImagesFor = arm: riscv: {
    arm = fakeFit "boot.itb" "arm" arm;
    riscv = fakeFit "boot.itb" "riscv" riscv;
  };
  vbmetaFor = fakeFit "vbmeta.itb" "vbmeta";
  gptWith =
    {
      arm,
      riscv,
      vbmeta,
    }:
    mkBoot (
      {
        bootImages = bootImagesFor arm riscv;
        vbmeta = vbmetaFor vbmeta;
      }
      // fips
    );
  gpt = gptWith {
    arm = "unsigned";
    riscv = "unsigned";
    vbmeta = "unsigned";
  };
  gptSigned = gptWith {
    arm = "signed";
    riscv = "signed";
    vbmeta = "signed";
  };
  coreMismatch = testers.testBuildFailure (gptWith {
    arm = "signed";
    riscv = "unsigned";
    vbmeta = "signed";
  });
  vbmetaMismatch = testers.testBuildFailure (gptWith {
    arm = "signed";
    riscv = "signed";
    vbmeta = "unsigned";
  });
  gptBootImages = bootImagesFor "unsigned" "unsigned";
  riscvOnly = mkBoot {
    bootImages = { inherit (gptBootImages) riscv; };
    vbmeta = vbmetaFor "unsigned";
    fip = builtins.toFile "fip.bin" "fixture riscv fip\n";
  };
in
runCommand "boot-dir"
  {
    nativeBuildInputs = [
      ubootTools
    ];
    passthru = { inherit gpt; };
  }
  ''
    fail() { echo "boot-dir: $*" >&2; exit 1; }

    g=${gpt}
    for core in arm riscv; do
      for f in boot.itb vbmeta.itb; do
        test -s "$g/$core/slot-A/$f" || fail "gpt: $core/slot-A/$f missing"
      done
    done
    cmp ${gptBootImages.arm}/boot.itb $g/arm/slot-A/boot.itb || fail "gpt: arm boot.itb is not bootImages.arm's"
    cmp ${gptBootImages.riscv}/boot.itb $g/riscv/slot-A/boot.itb || fail "gpt: riscv boot.itb is not bootImages.riscv's"
    cmp $g/arm/slot-A/vbmeta.itb $g/riscv/slot-A/vbmeta.itb || fail "gpt: the two cores' vbmeta.itb differ"
    for core in arm riscv; do
      for f in boot.itb vbmeta.itb; do
        cmp $g/$core/slot-A/$f $g/$core/slot-B/$f || fail "gpt: $core/slot-B/$f is not slot A's"
      done
    done
    cmp ${fips.fip} $g/fip.bin || fail "gpt: fip.bin is not the polyglot"
    # nothing but the FIT layout (+ the recovery split fips passed in)
    ( cd $g && find . -type f | sort ) > gpt.files
    printf '%s\n' ./arm/slot-A/boot.itb ./arm/slot-A/vbmeta.itb ./arm/slot-B/boot.itb ./arm/slot-B/vbmeta.itb \
      ./fip-arm.bin ./fip-riscv.bin ./fip.bin ./riscv/slot-A/boot.itb ./riscv/slot-A/vbmeta.itb \
      ./riscv/slot-B/boot.itb ./riscv/slot-B/vbmeta.itb ./secure | sort > gpt.expected
    diff -u gpt.expected gpt.files || fail "gpt: unexpected file set"
    [ "$(cat $g/secure)" = unsigned ] || fail "gpt: secure marker is '$(cat $g/secure)', not unsigned"
    [ "$(cat ${gptSigned}/secure)" = signed ] || fail "gpt (signed markers): secure marker is not signed"
    dumpimage -l $g/arm/slot-A/boot.itb > dump.txt || fail "gpt: dumpimage cannot read arm/slot-A/boot.itb"
    grep -q 'script-default' dump.txt || fail "gpt: arm boot.itb lists no image"

    # ---- one core ----
    ( cd ${riscvOnly} && find . -type f | sort ) > riscv.files
    printf '%s\n' ./fip.bin ./riscv/slot-A/boot.itb ./riscv/slot-A/vbmeta.itb ./riscv/slot-B/boot.itb \
      ./riscv/slot-B/vbmeta.itb ./secure > riscv.expected
    diff -u riscv.expected riscv.files || fail "riscv-only: unexpected file set"
    [ ! -e ${riscvOnly}/arm ] || fail "riscv-only: the tree has arm/"

    for f in ${coreMismatch} ${vbmetaMismatch}; do
      [ "$(cat $f/testBuildFailure.exit)" != 0 ] || fail "mismatched markers built"
      grep -qF 'make-boot-dir: secure markers disagree' $f/testBuildFailure.log \
        || { cat $f/testBuildFailure.log >&2; fail "mismatched markers failed without the message"; }
    done

    # ---- nix-badge-emmc-init --plan over the gpt tree ----
    bin=${emmcInit}/bin/nix-badge-emmc-init
    printf 'console=ttyS0 nixbadge.bootmedium=1\n' > sd.cmdline
    mkdir -p sys/class/block/mmcblk1/device
    echo MMC > sys/class/block/mmcblk1/device/type
    # the lower store: each core's image generation links the boot image on the card
    ro=$PWD/ro
    mkdir -p $ro/nix/var/nix/profiles
    for core in arm riscv; do
      mkdir -p $ro/nix/store/top-$core $ro/nix/store/bi-$core
      cp $g/$core/slot-A/boot.itb $ro/nix/store/bi-$core/boot.itb
      ln -s /nix/store/bi-$core $ro/nix/store/top-$core/boot-image
      ln -s /nix/store/top-$core $ro/nix/var/nix/profiles/system-$core-1-link
    done
    run_plan() { # $1 = bootdir
      EMMC_INIT_CMDLINE=$PWD/sd.cmdline EMMC_INIT_SYS=$PWD/sys EMMC_INIT_DEV=/dev/mmcblk1 EMMC_INIT_BOOTDIR="$1" EMMC_INIT_ROSTORE=$ro "$bin" --plan
    }
    run_plan $g > plan.out || { cat plan.out >&2; fail "emmc-init --plan refused the gpt tree"; }
    for f in arm/slot-A/boot.itb arm/slot-A/vbmeta.itb riscv/slot-A/boot.itb riscv/slot-A/vbmeta.itb secure; do
      grep -q "^+ verify_copy /boot/$f .*/$f\$" plan.out || { cat plan.out >&2; fail "emmc-init --plan does not list the copy of $f"; }
    done
    cp -r --no-preserve=all $g nov
    rm nov/arm/slot-A/vbmeta.itb
    rc=0; run_plan $PWD/nov > nov.out 2> nov.err || rc=$?
    [ "$rc" = 1 ] || fail "emmc-init accepted a tree without vbmeta.itb"
    grep -qx "refusing: $PWD/nov/arm/slot-A/vbmeta.itb missing" nov.err || { cat nov.err >&2; fail "wrong refusal"; }
    if grep -q sgdisk nov.out; then fail "emmc-init refused only after a write"; fi

    touch $out
  ''
