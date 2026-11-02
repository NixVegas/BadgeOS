# Troubleshooting

## The serial console

Most problems are easier to understand from the serial console. Plug the DEBUG port into
your computer, and the CH347 on the badge shows up as a USB serial port (`/dev/ttyACM0`
or similar on Linux). It runs at 115200 8N1:

```console
$ nix run nixpkgs#tio -- /dev/ttyACM0
```

You'll see U-Boot, the kernel and a login prompt, and you can log in there even when the
network is down.

## Slow isn't broken

A few things take long enough that it's tempting to pull the power, which can make things
worse:

- A warm reboot on the ARM core can take two or three minutes to come back.
- The RISC-V core boots much more slowly than ARM, and the desktop can take several
  minutes to come up there.
- The first boot of a new card grows `USERDATA` to fill the card and makes a swap file.

## The badge doesn't boot

If the badge stopped booting after you changed something under `/etc`, a [factory
reset](profiles.md#factory-reset) puts `USERDATA` back the way it was on a fresh card.

If the SD card itself is the problem, [flash it again](getting-started.md#build-and-flash-the-sd-card-image),
writing the whole card rather than a partition.

A badge installed to the eMMC falls back to its other slot by itself after three failed
boots (see [Updating](updating.md#rauc-bundles)). If neither slot boots, a bootable SD card
always takes priority over the eMMC, so you can boot a BadgeOS card and run
`sudo nix-badge-install` again to update the eMMC from it.

## Data cards

When a badge doesn't use its [data card](data-cards.md), stage 0 says why on the
console as it boots, in a line starting with `stage-0:` (`sudo dmesg | grep stage-0`
shows it later):

- `no EXT_USERDATA partition`: no GPT partition is named `EXT_USERDATA`. A file system
  labelled `EXT_USERDATA` doesn't count, and neither does a BadgeOS card's `USERDATA`.
  A slow card can say this too, when its partitions show up late, so reboot once before
  you reformat anything.
- `set up on another badge`: the card belongs to a different badge. A factory reset with
  the card in makes it this badge's, and so does reformatting its `EXT_USERDATA`, both
  at the cost of what's on it.
- `has not booted this image without the card yet`: the eMMC's system is new. Nothing's
  wrong, and the next boot uses the card.
- `the eMMC has no USERDATA partition` or `the eMMC's USERDATA does not mount
  read-only`: the problem is on the eMMC side. Take the card out and boot without it.
- `e2fsck -p` or `does not mount as ext4`: check the card's file system on a computer with
  `fsck.ext4`.

If stage 0 says nothing about the card at all, it never saw one. Reseat the card and
reboot.

A few `stage-0:` lines about the card are routine, not errors. `holds slot A Nix state
from before it was a data card` shows up the first time a card made from a BadgeOS card
is used, and `resetting the card's Nix layer` after the eMMC's system changed while the
card was out. If that card held a deploy, you also get `boot image for slot A belonged
to the Nix layer just reset`: that boot runs the eMMC's system on the card's kernel, and
the next one is all eMMC.

`nixbadge.cardfit=1 but no data card is in use` means U-Boot booted the kernel from the
card's `BOOT`, but stage 0 couldn't use the card after all, so the eMMC's system is
running on the card's kernel. Fix the card, or take it out, and reboot.

`/run/nix-badge/storage` says what the badge is using: `emmc`, `sd`, or `card` and the
card's partition.

`sudo rauc install` failing with `Pre-install handler error: Child process exited with
code 1` means a data card is in use, and RAUC won't touch the eMMC under it.
`journalctl -u rauc` has the full message. Power off, take the card out, boot, and
install again.

SSH warning that the badge's host key changed after you put a card in or took it out?
A card made from a BadgeOS card brings that card's host keys along, so the badge has a
different key with and without it. That's expected.

## The badge stops responding

If the console is dead and the badge doesn't answer on the network, power-cycle it. If you
had the A53's SWD wiring set up, you can also reset it through the watchdog without
touching the power (see [Resetting a hung badge](som.md#resetting-a-hung-badge)).

Starting OpenOCD kills the CH347's serial console until you reset the USB device with
`nix shell nixpkgs#usbutils -c usbreset 1a86:55dd`, which can look like a hang if you
don't know about it.

## A button or another feature doesn't work

Some v2.0 badges have cold solder joints on the SoM, where the Duo Module 01's castellated
pads meet the badge. If a button or anything else doesn't work, that's a good first
suspect. Look along the module's edges with a loupe or a microscope, and touch up any joint
that looks dull or never flowed onto its pad with a fine-tipped iron and a little flux.

## HDMI

HDMI only gets its 5 V when the badge is on USB power, so it doesn't work on batteries
alone. If HDMI stays black after a warm reboot, power-cycle the badge: the HDMI bridge has
no reset line and stays powered across a reboot, so it can keep a bad state. [The HDMI
link](hdmi.md) covers the other ways it fails and what each one looks like.

## USB

The USB port is a USB device in the default profile and a host in the desktop profile, so
the [USB network link](getting-started.md#usb-networking) only exists in the default one.
Host mode needs power coming in through the DEBUG port, since the batteries can't supply
5 V to whatever you plug in.

## WiFi

If a WPA3 network refuses to associate with a profile made in `nmtui`, see the tip in
[Getting started](getting-started.md#wifi).

## The laptop installs from the internet, not the badge

[The badge's cache](cache.md) only runs with a data card in, or on an SD boot, and only
in the default profile. From the laptop, `curl http://10.55.0.1/nix-cache-info` should
answer `Priority: 30`. A 404 means it isn't running, and the install carries on without
it, just slower. With less than 4 GiB free on the card, the badge passes packages through
but stops keeping them, so the next laptop is slow too; it collects garbage on its own
within five minutes.

## Something on my wired network got an address from the badge

In the default profile the badge is a [router](router.md), and its Ethernet port is the
badge's own network, so it hands out addresses to whatever it's plugged into. To join a
wired network as a client, set
[`badge.router.upstream`](options/badge.router.md#opt-badge.router.upstream) to
`"ethernet"`, or boot the [desktop profile](profiles.md#desktop).
