# Updating

There are three ways to put a newer BadgeOS on a badge, and which one you want depends on
where the badge boots from and who built the update.

| Method | Boots from | Keeps your data | Who it's for |
|---|---|---|---|
| [A new SD card image](#a-new-sd-card-image) | SD card or eMMC | eMMC: yes; a reflashed card: no | Everyone |
| [RAUC bundle](#rauc-bundles) | eMMC | Yes | Everyone, with a signed bundle |
| [deploy-rs](#deploy-rs) | SD card or eMMC | Yes | Developers with their own builds |

## A new SD card image

[Build and flash](getting-started.md#build-and-flash-the-sd-card-image) a card from the
newer BadgeOS. A badge that runs from its SD card just boots the new card, with a fresh
`USERDATA`.

For a badge that's installed to the eMMC, boot the new card and run the installer again:

```console
$ sudo nix-badge-install
```

It sees that the eMMC already has BadgeOS on it, and writes the card's system into both
of the eMMC's slots while keeping the eMMC's `USERDATA`. Then take the card out and
reboot.

## RAUC bundles

A badge installed to the eMMC has two system slots, A and B, and updates with
[RAUC](https://rauc.io). A bundle (`.raucb`) holds the store image, the boot images for
both cores, and the firmware. Install one with:

```console
$ sudo rauc install nix-badge-<version>.raucb
$ sudo systemctl reboot
```

RAUC writes the slot that isn't running and makes it the first choice for the next boot.
U-Boot gives each slot three tries, and a system that comes up marks itself as good. If
the new system fails to boot three times, U-Boot falls back to the other slot on its own.
`rauc status` shows both slots and which one is booted.

RAUC refuses to install while a [data card](data-cards.md) is in use, since the eMMC
is read-only then. It only says `Pre-install handler error`, and `journalctl -u rauc`
has the reason. Power off and take the card out first.

A badge only accepts bundles signed with the key it trusts, which is
[`hardware.sg2k.fitKeyCert`](options/hardware.sg2k.md#opt-hardware.sg2k.fitKeyCert). By
default that's our sg1-image certificate; set your own if you run your own update channel.

The repository also has a development key for the test bundles. Its private half is
committed on purpose, so a system only trusts it if it sets
`hardware.sg2k.fitKeyCert = null` and also turns on
[`hardware.sg2k.rauc.trustDevKeyring`](options/hardware.sg2k.rauc.md#opt-hardware.sg2k.rauc.trustDevKeyring).
With neither key set, the configuration fails to evaluate.

## deploy-rs

For your own builds, [deploy-rs](https://github.com/serokell/deploy-rs) builds a system on
your computer, copies it to the badge over SSH, and activates it. You'll need an SSH key
for the `badge` user ([Getting started](getting-started.md#add-an-ssh-key)) and the
badge's address. The nodes are cross-compiled from `x86_64-linux`, and the flake's
development shell has `deploy` in it:

```console
$ nix develop github:NixVegas/BadgeOS
$ deploy --hostname 10.55.0.1 github:NixVegas/BadgeOS#sg2k-arm
```

There's one node per core, `sg2k-arm` and `sg2k-riscv`. Always pass `--hostname` with
your badge's address, since the default in the flake points at one of our own badges.
Deploy the node for the core the badge is currently running (`nix-badge core status`
will tell you), because a deploy never switches cores, and each core has its own system
profile. To deploy your own changes, deploy from your checkout (`.#sg2k-arm`) or define
nodes in your own flake.

Activating a deploy installs the new generation's boot image into the slot the badge
booted from and refreshes the firmware on the boot partition. Deployed generations live
in the Nix store layer on `USERDATA`, so a [factory reset](profiles.md#factory-reset)
takes the badge back to the system in its slot.

With a [data card](data-cards.md) in use, a deploy goes to the card: the generation
lives on the card, and its boot image goes on the card's `BOOT`, which U-Boot boots while
the card is in. The eMMC and its firmware stay as they are. A card without a `BOOT`
partition can't take a deploy, and the activation says so.

When the badge boots the card's image, `/proc/cmdline` has `nixbadge.cardfit=1` in it.
If U-Boot can't load or start that image, it boots the eMMC's instead. If the deployed
system itself misbehaves, take the card out, and the eMMC's system boots as before.
