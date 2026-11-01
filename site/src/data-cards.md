# Data cards

The eMMC is small, and its `USERDATA` is smaller. A *data card* fixes that. Put a microSD
card in a badge [installed to the eMMC](emmc.md), and everything the badge writes goes to
the card. What was on the eMMC's `USERDATA` is still there underneath, read-only. Take
the card out and the badge is exactly as it was before the card went in.

Any SD card works, as long as its GPT has an ext4 partition named `EXT_USERDATA`. That
name is the whole trick. A BadgeOS card calls its partition `USERDATA`, so a card the
badge boots from is never mistaken for a data card. A badge booted from an SD card can't
use a data card either, since there's only one slot.

## Make a data card

### From a BadgeOS card

If you installed the eMMC from an SD card, you already have one. When `nix-badge-install`
finishes, it asks:

```text
Turn this SD card into a data card for the eMMC system? [yes/no]
```

Say yes, and it renames the card's `USERDATA` to `EXT_USERDATA` and empties its `BOOT`,
so the badge stops booting from the card. Then it reboots into the eMMC with the card
still in. The first boot runs on the eMMC alone while it sets itself up. The card joins
in from the second.

Everything the card's system wrote comes along: passwords, WiFi networks, SSH keys and
home directories. Its Nix store doesn't, so the card starts over from the eMMC's. The
card keeps its (now empty) `BOOT`, so you can [deploy](updating.md#deploy-rs) with it in,
and its `NIX_A` and `NIX_B` partitions stay on it, unused.

Said no? Boot the card again and run `sudo nix-badge-install`. It updates the eMMC from
the card, keeps the eMMC's user data, and asks again.

A data card doesn't boot, so it's no longer the card to reinstall from. Flashing it again
turns it back into a BadgeOS card, and erases it.

### From a blank card

You'll need a computer with a card reader. This erases the card, so check its name with
`lsblk` first. A USB reader shows it as `/dev/sdX`, and a built-in one as `/dev/mmcblkN`,
whose partitions are `/dev/mmcblkNp1` and so on. If you're missing a tool,
`nix shell nixpkgs#gptfdisk nixpkgs#dosfstools nixpkgs#e2fsprogs` has them all.

We recommend giving the card a FAT32 partition named `BOOT` too, so you can
[deploy](updating.md#deploy-rs) to the badge with the card in:

```console
$ sudo sgdisk --zap-all /dev/sdX
$ sudo sgdisk -n 1:0:+512M -t 1:0700 -c 1:BOOT -n 2:0:0 -c 2:EXT_USERDATA /dev/sdX
$ sudo mkfs.vfat -F 32 -n BOOT /dev/sdX1
$ sudo mkfs.ext4 -L EXT_USERDATA /dev/sdX2
```

If you only want the space:

```console
$ sudo sgdisk --zap-all /dev/sdX
$ sudo sgdisk -n 0:0:0 -c 0:EXT_USERDATA /dev/sdX
$ sudo mkfs.ext4 -L EXT_USERDATA /dev/sdX1
```

## Use it

Power the badge off, put the card in, and power it on. The login message tells you when
a card is in use:

```text
Data card in use: writes go to /dev/mmcblk0p5; the eMMC is read-only.
```

The partition depends on the card (`p5` is a converted BadgeOS card). The boot info
screen on the OLED says so too, and `/run/nix-badge/storage` reads `card` followed by the
card's partition.

Power off before you take the card out, too. The card holds `/etc`, `/home`, the swap
file and the newest layer of the Nix store, so pulling it from a running badge pulls
those out from under it. A card that goes in while the badge is running does nothing
until the next boot.

Nothing reaches the eMMC's `USERDATA` or its system slots while the card is in use.
Deploys made with the card in live on the card, and boot again whenever it's back, as
long as the eMMC's system didn't change in the meantime (see below). RAUC won't install
a bundle while a card is in use, so take the card out to
[update with a bundle](updating.md#rauc-bundles).

## Things to know

- A card belongs to the badge it was first used in. Another badge won't use it, and
  says why on the console, but a factory reset on that badge still formats it. To move
  a card to another badge, factory reset with the card in, or reformat its
  `EXT_USERDATA` on a computer.
- Files on the card win. A password, WiFi network or SSH key changed with the card out
  comes back as the card's older copy whenever the card is in, so make changes with the
  card in.
- That includes the SSH host keys. A card made from a BadgeOS card brings its old
  system's keys, so the badge has one host key with the card in and another without it.
  Your SSH client will complain when you switch. That's expected.
- If the eMMC's Nix store changed while the card was out (an update, a deploy, a garbage
  collection, a factory reset, even a `nix shell`), the card's Nix store is emptied at
  the next boot with it in, along with any deploy it held. Its other files stay.
- The first boot of a newly installed or updated eMMC system ignores the card while it
  sets up the eMMC's side, and says so. The next boot uses the card.
- A [factory reset](profiles.md#factory-reset) with a card in formats the card, not the
  eMMC.
- [The badge's cache](cache.md) lives on the card too. With a card in, the laptops on the
  badge's network get their packages from the badge; without one, straight from the
  internet.
- Early in every boot, stage 0 (the small script that sets up storage, see
  [How BadgeOS boots](under-the-hood.md)) looks for the card once. If the card isn't
  there yet (it isn't seated, or it's slow to show up), the badge carries on without it
  and says nothing, so if the login message doesn't mention the card, reseat it and
  reboot.
- Data cards are on by default on badges with an eMMC. Set
  [`hardware.sg2k.externalStorage.enable`](options/hardware.sg2k.externalStorage.md#opt-hardware.sg2k.externalStorage.enable)
  to `false` to turn them off, and U-Boot ignores a card's boot images too.

When a card isn't used, [Troubleshooting](troubleshooting.md#data-cards) lists the
reasons stage 0 gives. [How BadgeOS boots](under-the-hood.md#data-cards) describes what
gets mounted where.
