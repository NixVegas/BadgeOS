# nix-badge-sd-image-gpt's partitioning, hybrid MBR and env blob, with a throwaway
# 8 MiB store. BOOT is the fixed 512 MiB whatever the tree's size, a tree too big for its
# FAT fails the build with the sizes, and so does a store image over its budget.
# passthru.sd-image-gpt-single-core: a riscv-only card passes its own checks, its FAT has
# both slots and no arm/.
{
  lib,
  runCommand,
  testers,
  squashfsTools,
  gptfdisk,
  mtools,
  nix-badge-sd-image-gpt,
}:
let
  mkImgGpt = nix-badge-sd-image-gpt;
  # store.img, as the real store image names it.
  fakeStore = runCommand "fake-store" { nativeBuildInputs = [ squashfsTools ]; } ''
    mkdir -p s/nix/store/hello s/nix/var/nix/db "$out"; echo hi > s/nix/store/hello/x
    mksquashfs s "$out/store.img" -comp zstd -b 131072 -all-root -noappend -no-xattrs
  '';
  # Stand-ins for both cores' system.build.bootImage (boot.itb + .secure), unsigned.
  fakeBootImages = lib.genAttrs [ "arm" "riscv" ] (
    core:
    runCommand "fake-boot-image-${core}" { } ''
      mkdir -p "$out"
      printf 'fake boot.itb %s' ${core} > "$out/boot.itb"
      echo unsigned > "$out/.secure"
    ''
  );
  # A stub boot dir in nix-badge-boot-dir's layout.
  fakeBoot = runCommand "fake-boot" { } ''
    mkdir -p "$out"
    echo "fip" > "$out/fip.bin"
    printf unsigned > "$out/secure"
    for core in arm riscv; do
      mkdir -p "$out/$core/slot-A"
      printf 'fake vbmeta.itb' > "$out/$core/slot-A/vbmeta.itb"
    done
    cp ${fakeBootImages.arm}/boot.itb "$out/arm/slot-A/boot.itb"
    cp ${fakeBootImages.riscv}/boot.itb "$out/riscv/slot-A/boot.itb"
    for core in arm riscv; do cp -r "$out/$core/slot-A" "$out/$core/slot-B"; done
  '';
  realImage = mkImgGpt {
    bootDir = fakeBoot;
    storeImage = fakeStore;
    cores = [
      "arm"
      "riscv"
    ];
    envText = "env_loaded=1\nBOOT_ORDER=A B\nBOOT_A_LEFT=3\nBOOT_B_LEFT=3\n";
    nixSlotMiB = 8;
    userdataMiB = 16;
  };
  # A boot tree too big for its FAT: a 41 MiB sparse file on a 40 MiB FAT.
  tooBigBoot = runCommand "fake-boot-too-big" { } ''
    cp -r ${fakeBoot} "$out"
    chmod -R u+w "$out"
    truncate -s 41M "$out/filler"
  '';
  tooBig = testers.testBuildFailure (mkImgGpt {
    bootDir = tooBigBoot;
    storeImage = fakeStore;
    cores = [
      "arm"
      "riscv"
    ];
    envText = "env_loaded=1\n";
    nixSlotMiB = 8;
    userdataMiB = 16;
    bootMiB = 40;
  });

  # A store image over its budget: 2 MiB against 1 MiB, in an 8 MiB slot.
  overBudgetStore = runCommand "fake-store-over-budget" { } ''
    mkdir "$out"
    truncate -s 2M "$out/store.img"
  '';
  overBudget = testers.testBuildFailure (mkImgGpt {
    bootDir = fakeBoot;
    storeImage = overBudgetStore;
    cores = [
      "arm"
      "riscv"
    ];
    envText = "env_loaded=1\n";
    nixSlotMiB = 8;
    userdataMiB = 16;
    storeBudgetMiB = 1;
  });

  # One core: the riscv tree only.
  fakeBootSingle = runCommand "fake-boot-single-core" { } ''
    mkdir -p "$out/riscv/slot-A"
    echo "fip" > "$out/fip.bin"
    printf unsigned > "$out/secure"
    printf 'fake vbmeta.itb' > "$out/riscv/slot-A/vbmeta.itb"
    cp ${fakeBootImages.riscv}/boot.itb "$out/riscv/slot-A/boot.itb"
    cp -r "$out/riscv/slot-A" "$out/riscv/slot-B"
  '';
  singleCoreImage = mkImgGpt {
    bootDir = fakeBootSingle;
    storeImage = fakeStore;
    cores = [ "riscv" ];
    envText = "env_loaded=1\n";
    nixSlotMiB = 8;
    userdataMiB = 16;
  };
  singleCore =
    runCommand "test-sd-image-gpt-single-core"
      {
        nativeBuildInputs = [
          gptfdisk
          mtools
        ];
      }
      ''
        img=${singleCoreImage}/sdcard.img
        start=$(sgdisk -i 1 $img | sed -n 's/^First sector: \([0-9]*\).*/\1/p')
        fat="$img@@$((start * 512))"
        mcopy -i "$fat" ::/riscv/slot-A/boot.itb boot.itb
        cmp boot.itb ${fakeBootImages.riscv}/boot.itb || { echo "riscv/slot-A/boot.itb differs" >&2; exit 1; }
        mcopy -n -i "$fat" ::/riscv/slot-B/boot.itb boot.itb
        cmp boot.itb ${fakeBootImages.riscv}/boot.itb || { echo "riscv/slot-B/boot.itb differs" >&2; exit 1; }
        if mdir -i "$fat" ::/arm > /dev/null 2>&1; then echo "the FAT has arm/" >&2; exit 1; fi
        touch $out
      '';
in
(runCommand "test-sd-image-gpt"
  {
    nativeBuildInputs = [
      gptfdisk
      mtools
    ];
  }
  ''
    img=${realImage}/sdcard.img
    sectors() { sgdisk -i "$1" $img | sed -n 's/^Partition size: \([0-9]*\) sectors.*/\1/p'; }
    first() { sgdisk -i "$1" $img | sed -n 's/^First sector: \([0-9]*\).*/\1/p'; }
    # BOOT is the fixed 512 MiB (1048576 sectors) whatever the tree's size.
    bootsectors=$(sectors 1)
    [ "$bootsectors" = 1048576 ] || { echo "BOOT is $bootsectors sectors, not the fixed 512 MiB (1048576)" >&2; exit 1; }
    # Both slots are nixSlotMiB (8 MiB here), and NIX_B holds NIX_A's store image.
    for p in 3 4; do
      [ "$(sectors $p)" = 16384 ] || { echo "partition $p is $(sectors $p) sectors, not 8 MiB (16384)" >&2; exit 1; }
    done
    n=$(stat -L -c %s ${fakeStore}/store.img)
    cmp -n "$n" -i "$(( $(first 3) * 512 )):$(( $(first 4) * 512 ))" $img $img \
      || { echo "NIX_B does not hold NIX_A's $n-byte store image" >&2; exit 1; }
    # Each core's slot-B boot files on the FAT are slot A's.
    fat="$img@@$(( $(first 1) * 512 ))"
    for core in arm riscv; do
      for f in boot.itb vbmeta.itb; do
        mcopy -n -i "$fat" ::/$core/slot-A/$f a.readback && mcopy -n -i "$fat" ::/$core/slot-B/$f b.readback \
          || { echo "missing $core/slot-A or slot-B/$f on the FAT" >&2; exit 1; }
        cmp a.readback b.readback || { echo "$core/slot-B/$f on the FAT is not slot A's" >&2; exit 1; }
      done
    done

    # A tree too big for its FAT fails the build with the sizes.
    [ "$(cat ${tooBig}/testBuildFailure.exit)" != 0 ] || { echo "an oversized boot tree built" >&2; exit 1; }
    grep -q 'more than the [0-9]* bytes free on the 40 MiB BOOT FAT' ${tooBig}/testBuildFailure.log || {
      echo "the oversized boot tree failed for the wrong reason:" >&2
      cat ${tooBig}/testBuildFailure.log >&2
      exit 1
    }

    # A store image over its budget fails the build, though it fits the slot.
    [ "$(cat ${overBudget}/testBuildFailure.exit)" != 0 ] || { echo "a store image over its budget built" >&2; exit 1; }
    grep -q 'store.img is larger than its 1 MiB budget' ${overBudget}/testBuildFailure.log || {
      echo "the store image over its budget failed for the wrong reason:" >&2
      cat ${overBudget}/testBuildFailure.log >&2
      exit 1
    }

    # Positive: the real (short) fixture still builds and passes
    # nix-badge-sd-image-gpt's own boot-tree checks.
    ln -s "${realImage}" "$out"
  ''
).overrideAttrs
  (_: {
    # test-rauc-bundle reuses fakeBootImages, so the two fixtures cannot drift.
    passthru = {
      inherit fakeBoot fakeBootImages;
      sd-image-gpt-single-core = singleCore;
    };
  })
