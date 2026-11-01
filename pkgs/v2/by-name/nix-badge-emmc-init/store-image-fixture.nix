# A store image as nix-badge-store-squashfs makes one: a 4 KiB-padded squashfs with its
# dm-verity tree appended. Over 128 data blocks, so the tree has two levels. Shared by
# the emmc-init and emmc-update tests.
{
  runCommand,
  squashfsTools,
  cryptsetup,
}:
runCommand "emmc-store-image-fixture"
  {
    nativeBuildInputs = [
      squashfsTools
      cryptsetup
    ];
  }
  ''
    mkdir -p s/nix/store/x "$out"
    awk 'BEGIN { srand(1); for (i = 0; i < 200000; i++) printf "%08x", int(rand() * 4294967296) }' > s/nix/store/x/blob
    mksquashfs s sq -comp zstd -all-root -noappend -no-xattrs
    d=$(( $(stat -c %s sq) / 4096 ))
    [ "$d" -gt 128 ]
    veritysetup format --no-superblock --hash=sha256 --data-block-size=4096 --hash-block-size=4096 \
      --data-blocks=$d --hash-offset=$(( d * 4096 )) sq sq
    cp sq "$out/store.img"
  ''
