# How BadgeOS boots

You don't need any of this to use the badge, but it's useful if you're building on BadgeOS
for other SG200x boards.

## The boot chain

1. **Mask ROM.** The SG2000 starts whichever core its boot strap selects (see
   [Switching CPU cores](cores.md)), and that core's mask ROM loads `fip.bin`, either from
   the SD card's first FAT partition or from the eMMC's first boot area.
2. **`fip.bin`.** We ship one *polyglot* firmware image that's valid for both cores. It
   holds the first-stage loader, followed by ARM Trusted Firmware BL31 and U-Boot for the
   A53, or OpenSBI and U-Boot for the C906. The images are built by
   [sophgone](https://github.com/NixVegas/sophgone).
3. **U-Boot** reads the BOOT button and BUTTON to pick a [profile](profiles.md), picks a
   system slot (A or B, see below), and loads two files for that slot from the boot
   partition: `/<core>/slot-<X>/boot.itb`, a FIT image with a kernel, a device tree and a
   boot script for each profile, and `vbmeta.itb`, which describes the slot's verified
   root. On an eMMC boot with a [data card](data-cards.md) in, `boot.itb` comes from
   the card's `BOOT` when the card has one for the slot.
4. **Linux** starts without an initrd. It sets up the root file system with dm-verity
   from the slot's store partition, which is a read-only squashfs, and runs
   `/init-<core>`.
5. **Stage 0**, a small script in the store image, mounts `USERDATA` (formatting it first
   on a [factory reset](profiles.md#factory-reset)), sets up the writable directories and
   the Nix store overlay, and starts the slot's NixOS system for this core.

## Storage layout

An SD card and an installed eMMC have the same partitions, found by name:

| # | Name | Contents |
|---|---|---|
| 1 | `BOOT` | FAT32, 512 MiB: `fip.bin`, the per-core slot directories with `boot.itb` and `vbmeta.itb`, and `secure` (whether the images are signed) |
| 2 | `UBOOT` | The U-Boot environment |
| 3 | `NIX_A` | Slot A, 3 GiB: a squashfs Nix store with the systems for both cores, verified with dm-verity |
| 4 | `NIX_B` | Slot B, 3 GiB: the same; a fresh card or eMMC has the same system in both slots |
| 5 | `USERDATA` | ext4: all writable state; grows to fill the card on first boot |

The partition table is GPT with a hybrid MBR, because the mask ROM finds the boot
partition through the MBR. On the eMMC, the firmware lives in the first hardware boot area
instead of in `BOOT`, and the U-Boot environment lives in the second one.

## A read-only system

The root file system is the verified squashfs, and nothing ever writes to it. Everything
that changes lives on `USERDATA` and is mounted over it. `/etc`, `/var`, `/home`, `/root`,
`/tmp` and `/nix/var` are bind mounts from `USERDATA`, and only `/nix/var` allows
executing files. The Nix store is an overlay store, with the squashfs store as its
read-only lower layer, and paths added later (by a deploy, for example) go into an upper
layer on `USERDATA` that belongs to the booted slot. A swap file on `USERDATA` (512 MiB on
an SD card, 256 MiB on the eMMC's smaller one) and compressed RAM swap (zram) help make up
for the small amount of memory.

## Data cards

On an eMMC boot with a [data card](data-cards.md) in, stage 0 mounts the eMMC's
`USERDATA` read-only at `/.lower-userdata` and the card's `EXT_USERDATA` at `/.userdata`.
`/etc`, `/var`, `/home` and `/root` are overlays of the card's directory over the eMMC's,
`/tmp` and the swap file are the card's alone, and the Nix store is three layers deep: the
card's upper layer over the eMMC slot's upper layer over the squashfs, each one a Nix
local-overlay store over the next.

U-Boot looks at the card only when the eMMC's own `boot.itb` for the slot says the
eMMC's system has data cards on, and only while the card's `EXT_USERDATA` marks its
`boot.itb` for that slot as current. If the card's image doesn't boot, the eMMC's boots
instead. When the card's does, U-Boot adds `nixbadge.cardfit=1` to the kernel command
line and stage 0 starts the card's generation; otherwise stage 0 starts the eMMC's, so the
kernel and the system always come from the same place. The card also records which eMMC
it was used with (the eMMC's CID, its `USERDATA` file system, and the system and Nix
database of each slot), and stage 0 checks that before using it.

## Slots and updates

The two store partitions are A/B slots managed by [RAUC](https://rauc.io) and U-Boot.
U-Boot's environment holds the boot order (`BOOT_ORDER`) and a counter of remaining tries
for each slot (`BOOT_A_LEFT`, `BOOT_B_LEFT`). An update writes the inactive slot and puts
it first in the boot order. Each boot of a slot uses up one try, and a system that comes
up successfully resets its counter. A slot that runs out of tries gets skipped, so a broken
update falls back to the previous system on its own (see [Updating](updating.md)).

## The U-Boot environment

`fw_printenv` and `fw_setenv` are installed. On a badge with an eMMC, their default
configuration in `/etc/fw_env.config` points at the eMMC's environment, even when the badge
booted from the SD card. To read or change the SD card's environment, pass its own
configuration:

```console
$ fw_printenv -c /etc/fw_env-sd.config
$ sudo fw_setenv -c /etc/fw_env-sd.config nixbadge_profile_user desktop
```

## Signed firmware and verified boot

Two options control signing, and they're independent of each other.

[`hardware.sg2k.firmware.secureBoot`](options/hardware.sg2k.firmware.md#opt-hardware.sg2k.firmware.secureBoot)
is for a part whose secure-boot fuses are burned. Its mask ROM checks an RSA signature
chain on `fip.bin` and refuses to boot an unsigned one.
[`hardware.sg2k.firmware.encryptedBoot`](options/hardware.sg2k.firmware.md#opt-hardware.sg2k.firmware.encryptedBoot)
also encrypts it, for parts that are fused to require that.

[`hardware.sg2k.secureBoot`](options/hardware.sg2k.md#opt-hardware.sg2k.secureBoot) turns
on the verified-boot chain. The U-Boot inside the signed firmware then only boots FIT
images signed with the key in
[`hardware.sg2k.fitKeyCert`](options/hardware.sg2k.md#opt-hardware.sg2k.fitKeyCert), and
the slot's `vbmeta.itb`, which pins the dm-verity root, is signed with it as well.

Signed images can only be built on a machine with the signing key.

Two private keys are committed to the repository on purpose, for tests only: the
sg1-image test key that the FIT signing tests use
(`pkgs/v2/by-name/nix-badge-fit-signing/test-key`), and the RAUC development key for the
test bundles (`pkgs/v2/by-name/nix-badge-rauc-dev-keyring`). A badge doesn't trust either
of them unless you ask it to, and the development keyring needs
`hardware.sg2k.rauc.trustDevKeyring` (see [Updating](updating.md#rauc-bundles)).

Verified boot raises the bar, but on this SoC it can't be a guarantee. The SG2000 mask ROM
copies the first boot stage before it checks the signature, and sophgone uses that to run
unsigned code on fused parts. Remember, immutable means it's broken f o r e v e r. The
[sophgone README](https://github.com/NixVegas/sophgone) has the details.

## The kernel

Each core runs a recent mainline kernel with the SG200x patch series from Armbian, a few
fixes of our own, the AIC8800 WiFi driver, and the vendor's display and video drivers
forward-ported to mainline for HDMI. The device trees for both cores live in the
repository and are built against the same kernel.
