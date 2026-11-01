# GPT + hybrid-MBR card: BOOT (FAT, fip + each core's boot tree), UBOOT (U-Boot env
# blob), NIX_A and NIX_B (the store image in both slots), USERDATA (ext4, grown on first
# boot). Partition names are the handles everything else uses; numbers are fixed.
{
  lib,
  callPackage,
  runCommand,
  genimage,
  dosfstools,
  mtools,
  libfaketime,
  ubootTools,
  gptfdisk,
  e2fsprogs,
  util-linux,
}:
let
  makeSdImageGpt =
    {
      bootDir,
      storeImage,
      envText,
      # the cores bootDir holds a tree for
      cores,
      nixSlotMiB ? 3072,
      # The most the store image may take of its slot, so the slot keeps room to grow.
      storeBudgetMiB ? 2944,
      userdataMiB ? 256,
      # The eMMC's BOOT size, so a tree that fits the card fits the eMMC it seeds. Only
      # ./test.nix passes a smaller one.
      bootMiB ? 512,
    }:
    runCommand "sg2k-sdcard-gpt"
      {
        nativeBuildInputs = [
          genimage
          dosfstools
          mtools
          libfaketime
          ubootTools
          gptfdisk
          e2fsprogs
          util-linux
        ];
        inherit envText;
        passAsFile = [ "envText" ];
      }
      ''
        mkdir -p input emptyroot tmp "$out/nix-support"
        # BOOT: a fixed-size FAT32. A tree that does not fit (in whole clusters) fails here,
        # with the sizes, rather than halfway through mcopy.
        truncate -s ${toString bootMiB}M input/boot.vfat
        faketime -f "1970-01-01 00:00:00" mkfs.vfat -F 32 -n BOOT -i 12345678 input/boot.vfat
        minfo -i input/boot.vfat :: > boot.minfo
        sector=$(sed -n 's/^sector size: \([0-9]*\) bytes$/\1/p' boot.minfo)
        csize=$(( $(sed -n 's/^cluster size: \([0-9]*\) sectors$/\1/p' boot.minfo) * sector ))
        free=$(( $(sed -n 's/^free clusters=\([0-9]*\)$/\1/p' boot.minfo) * csize ))
        [ "$free" -gt 0 ] || { echo "could not read the free space of the BOOT FAT:" >&2; cat boot.minfo >&2; exit 1; }
        need=$(find -L "${bootDir}" -mindepth 1 -printf '%y %s\n' \
          | awk -v c="$csize" '{ n += ($1 == "d") ? c : int(($2 + c - 1) / c) * c } END { printf "%d\n", n }')
        if [ "$need" -gt "$free" ]; then
          echo "the boot tree needs $need bytes (in $csize-byte clusters), more than the $free bytes free on the ${toString bootMiB} MiB BOOT FAT" >&2
          exit 1
        fi
        echo "BOOT FAT: ${toString bootMiB} MiB, boot tree $need of $free free bytes"
        ( cd "${bootDir}" && for entry in *; do faketime -f "1970-01-01 00:00:00" mcopy -s -i "$OLDPWD/input/boot.vfat" -- "$entry" :: ; done )
        # UBOOT: 1 MiB, env blob (CRC + flags, redundant format) at offset 0, copy 1 left
        # invalid (U-Boot's redundant logic accepts one valid copy)
        truncate -s 1M input/uboot.img
        mkenvimage -s 0x20000 -r -o input/env.bin "$envTextPath"
        dd if=input/env.bin of=input/uboot.img conv=notrunc status=none
        # NIX_A and NIX_B: the store image, padded to the slot, in both slots so either
        # one boots it
        # (-L: the real store image's store.img is a symlink into its squashfs derivation)
        test "$(stat -L -c %s "${storeImage}/store.img")" -le $(( ${toString storeBudgetMiB} * 1048576 )) \
          || { echo "store.img is larger than its ${toString storeBudgetMiB} MiB budget ($(( $(stat -L -c %s "${storeImage}/store.img") / 1048576 )) MiB)" >&2; exit 1; }
        test "$(stat -L -c %s "${storeImage}/store.img")" -le $(( ${toString nixSlotMiB} * 1048576 )) \
          || { echo "store.img is larger than the ${toString nixSlotMiB} MiB slot" >&2; exit 1; }
        cp "${storeImage}/store.img" input/nixa.img
        chmod u+w input/nixa.img
        truncate -s "${toString nixSlotMiB}M" input/nixa.img
        cp --sparse=always input/nixa.img input/nixb.img
        # USERDATA: small ext4, grown online on first boot
        truncate -s "${toString userdataMiB}M" input/userdata.ext4
        faketime -f "1970-01-01 00:00:00" mkfs.ext4 -q -L USERDATA -E lazy_itable_init=0,lazy_journal_init=0 input/userdata.ext4
        cat > genimage.cfg <<CFG
        image sdcard.img {
          hdimage { partition-table-type = "gpt"  align = 4M  gpt-no-backup = false }
          partition BOOT     { partition-type-uuid = "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"  bootable = "true"  image = "boot.vfat" }
          partition UBOOT    { partition-type-uuid = "3DE21764-95BD-54BD-A5C3-4ABE786F38A8"  image = "uboot.img" }
          partition NIX_A    { partition-type-uuid = "0FC63DAF-8483-4772-8E79-3D69D8477DE4"  image = "nixa.img" }
          partition NIX_B    { partition-type-uuid = "0FC63DAF-8483-4772-8E79-3D69D8477DE4"  image = "nixb.img" }
          partition USERDATA { partition-type-uuid = "0FC63DAF-8483-4772-8E79-3D69D8477DE4"  image = "userdata.ext4" }
        }
        CFG
        genimage --config genimage.cfg --inputpath input --outputpath output --rootpath emptyroot --tmppath tmp
        sgdisk --hybrid=1:EE output/sdcard.img
        # checks: five named partitions in order, hybrid entries, signature, env blob CRC
        sgdisk -p output/sdcard.img | awk '$1 ~ /^[1-5]$/ {print $1, $NF}' | tr '\n' ' ' | grep -qx '1 BOOT 2 UBOOT 3 NIX_A 4 NIX_B 5 USERDATA '
        test "$(od -An -tx1 -j450 -N1 output/sdcard.img | tr -d ' ')" = 07
        bstart=$(sgdisk -i 1 output/sdcard.img | sed -n 's/^First sector: \([0-9]*\).*/\1/p')
        test "$(od -An -tu4 --endian=little -j454 -N4 output/sdcard.img | tr -d ' ')" = "$bstart"
        test "$(od -An -tx1 -j466 -N1 output/sdcard.img | tr -d ' ')" = ee
        test "$(od -An -tx1 -j510 -N2 output/sdcard.img | tr -d ' ')" = 55aa
        test "$(od -An -tu4 --endian=little -j470 -N4 output/sdcard.img | tr -d ' ')" = 1
        # BOOT is exactly the fixed FAT (bootMiB), in 512-byte sectors
        test "$(sgdisk -i 1 output/sdcard.img | sed -n 's/^Partition size: \([0-9]*\) sectors.*/\1/p')" = $(( ${toString bootMiB} * 2048 ))
        ustart=$(sgdisk -i 2 output/sdcard.img | sed -n 's/^First sector: \([0-9]*\).*/\1/p')
        dd if=output/sdcard.img bs=512 skip="$ustart" count=256 status=none > env.readback
        cmp -n 131072 env.readback input/env.bin
        # NIX_A and NIX_B are nixSlotMiB each and both hold the store image
        n=$(stat -L -c %s "${storeImage}/store.img")
        for p in 3 4; do
          test "$(sgdisk -i $p output/sdcard.img | sed -n 's/^Partition size: \([0-9]*\) sectors.*/\1/p')" = $(( ${toString nixSlotMiB} * 2048 ))
          pstart=$(sgdisk -i $p output/sdcard.img | sed -n 's/^First sector: \([0-9]*\).*/\1/p')
          cmp -n "$n" -i "$(( pstart * 512 )):0" output/sdcard.img "${storeImage}/store.img"
        done
        # check: each core's slot-A and slot-B boot.itb and vbmeta.itb and /secure, as in
        # the boot dir
        for f in ${
          lib.concatMapStrings (
            core:
            "${core}/slot-A/boot.itb ${core}/slot-A/vbmeta.itb ${core}/slot-B/boot.itb ${core}/slot-B/vbmeta.itb "
          ) cores
        }secure; do
          mcopy -i input/boot.vfat ::/$f fat.readback 2>/dev/null || { echo "missing /$f on the BOOT FAT" >&2; exit 1; }
          case $f in *.itb) test -s fat.readback || { echo "/$f on the BOOT FAT is empty" >&2; exit 1; } ;; esac
          cmp fat.readback "${bootDir}/$f" || { echo "/$f on the BOOT FAT differs from the boot dir's" >&2; exit 1; }
          rm fat.readback
        done
        cp output/sdcard.img "$out/sdcard.img"
        echo "file sd-image $out/sdcard.img" > "$out/nix-support/hydra-build-products"
      '';
in
lib.setFunctionArgs makeSdImageGpt (lib.functionArgs makeSdImageGpt)
// {
  passthru.tests = {
    # Partitioning, hybrid MBR and env blob against an 8 MiB fake store.
    sd-image-gpt = callPackage ./test.nix { };
    # A card ships its host's fip and signs exactly when the chain is on; cards is
    # { <prefix> = { image, arm, riscv }; }.
    sdcard-fip = { cards }: callPackage ./test-fip.nix { inherit cards; };
  };
}
