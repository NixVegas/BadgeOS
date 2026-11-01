# Installing to the eMMC

The badge has its own eMMC storage. Installing BadgeOS there frees up the SD card slot
and gives you [A/B updates](updating.md#rauc-bundles) with automatic fallback. The
installer runs on a badge that's booted from its SD card.

## Run the installer

Boot the badge from a BadgeOS SD card and run this, on a console or over SSH:

```console
$ sudo nix-badge-install
```

The installer works in two steps.

The first time you run it, a badge whose identity isn't fused yet will ask for its serial
number, which is written on the Ethernet port:

```text
We are setting up the SoC for the first time.
Please enter the serial number, written on the ethernet port: 7
Is 7 correct? This is permanent! [yes/no] yes
Fuse settings will be applied at reboot.
```

The number becomes the serial `SG1-0007`. It gets burned into the SoC's eFuses, which
can't be changed afterwards, so make sure it's right. A badge that's already fused shows
its serial instead and skips this step.

Next, the installer looks at what's on the eMMC and prints its plan before doing
anything. A blank eMMC (or one without BadgeOS on it) gets the SD card's partition layout
and a copy of the SD card's system in both slots, which erases the eMMC. An eMMC that
already has BadgeOS gets updated instead: the SD card's system goes into both of its
slots, one after the other, and its `USERDATA` is kept.

Answer `yes` to go ahead. Then, if the system has data cards on, the installer asks
whether to turn the SD card into a [data card](#more-room). At the end it waits for Enter
and reboots.

## Fusing the identity

If you entered a serial number, the fuses are written by U-Boot over the next boots,
rather than by the installer. Before rebooting, set the
[`builtins.currentSystem` switch](cores.md#the-builtinscurrentsystem-switch) to AUTO. The
badge then starts on the RISC-V core, fuses the serial, the board record and the badge's
device key, switches back to ARM, and resets itself.

With the switch on ARM, the serial and board record are fused on the next boot, and the
device key waits until the first RISC-V boot. Once the serial is fused, the badge's
hostname gets its number, so `SG1-0007` becomes `nix-badge-07`, and its USB network
adapter reports the serial as well.

## Boot from the eMMC

If you kept the SD card as it was, power the badge off, take the card out, and power it
back on. With no bootable card in the slot, the badge boots from the eMMC. A bootable
card always takes priority, which is also how you get back to the installer later: boot a
newer card and run `nix-badge-install` again to update the eMMC from it while keeping its
user data. If you turned the card into a data card, leave it in. The badge is already
booting from the eMMC.

The eMMC has the same layout as the card (see [How BadgeOS
boots](under-the-hood.md#storage-layout)), with two system slots, A and B, and a
`USERDATA` partition. Nothing from the SD card's `USERDATA` is copied over, so you'll need
to set up your SSH keys and WiFi networks again on the eMMC system, unless the card stays
in as a data card.

## More room

The eMMC's `USERDATA` is small. A [data card](data-cards.md) in the SD slot gives an
eMMC badge more room for everything it writes, and leaves the eMMC as it was when the card
comes out.

The card you installed from can be that data card. When the system has data cards on,
`nix-badge-install` offers to [convert it](data-cards.md#from-a-badgeos-card) at the end.
That's also the easy way to keep your SSH keys and WiFi networks: they stay on the card,
and the eMMC system uses them whenever the card is in. The badge then reboots into the
eMMC with the card left in. The first boot doesn't use the card yet. The second one does.
