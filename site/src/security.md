# Security

BadgeOS is set up for hacking on a badge at a conference, not for keeping secrets.

## Logins

The default login is `badge` with the password `nixbadge`, and it's printed on the back of
the badge. `root` starts with the same password. Change both with `passwd` (and
`sudo passwd root`) after you first log in.

`badge` is in the `wheel` group and can use `sudo` without a password, so a shell as
`badge` is a root shell. SSH only accepts keys, and `root` can't log in over SSH at all,
so the passwords only matter on the serial console and the Sharp display.

## The network

The NixOS firewall is on. From the network, the badge only listens for SSH (port 22). In
the default profile it's also a [router](router.md): it serves DHCP, DNS, TFTP and HTTP on
its Ethernet and USB ports, never on WiFi, and it forwards traffic from those ports out to
WiFi but nothing from WiFi in. Its HTTP serves this manual, the netboot files and a
[binary cache](cache.md) that signs nothing: packages carry the signatures they came with,
so the badge can't vouch for one even if it wanted to. The music player daemon only
listens on localhost. Bluetooth is powered on at boot.

## Physical access

Anyone holding the badge can plug into the DEBUG port and get the serial console, along
with JTAG for the RISC-V core (see [JTAG](som.md#jtag)). If the passwords haven't been
changed, the console is a root shell.

A [data card](data-cards.md) takes everything the badge writes, `/etc` included, so
whoever can write to the card can change the system the way they could by writing to
`USERDATA`. A card with a `BOOT` partition also holds the kernel U-Boot boots. With
verified boot on, U-Boot still only boots images signed with the key it trusts. The
card's files also win over the eMMC's: a password changed with the card out, say because
it leaked, is the old one again whenever the card is in. Change it with the card in too.

## Updates and boot

A badge only installs RAUC bundles signed with the key it trusts, which is our sg1-image
key unless you set your own, and the development key in the repository is only trusted if
you explicitly ask for it (see [Updating](updating.md#rauc-bundles)).

Verified boot is available, but on the SG2000 it can't be a guarantee, because the mask ROM
has a bug that lets unsigned code run on fused parts (see [Signed firmware and verified
boot](under-the-hood.md#signed-firmware-and-verified-boot)).
