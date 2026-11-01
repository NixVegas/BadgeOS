# Getting started

## Build and flash the SD card image

The SD card image is the flake's default package, and it cross-compiles from either an
`x86_64-linux` or an `aarch64-linux` machine. The first build takes a while.

```console
$ nix build github:NixVegas/BadgeOS#sg2k-sdcard
$ ls -l result/sdcard.img
```

The image is about 6.8 GiB, so you'll want a card of 8 GB or more. Write it to the
whole card rather than a partition, and double check the device name with `lsblk` first,
since everything on it will be overwritten:

```console
$ sudo dd if=result/sdcard.img of=/dev/sdX bs=4M conv=fsync status=progress
```

For a Sipeed LicheeRV Nano, build `licheerv-nano-sdcard` instead, which has a system for
each of its cores, or `licheerv-nano-sdcard-riscv` or `licheerv-nano-sdcard-arm` for just one. A
strap resistor on the Nano picks its core, and it ships set for RISC-V (see
[The LicheeRV Nano](bsp.md#the-licheerv-nano)). The rest of this page is about the badge.

## First boot

Put the card in and power the badge on. You don't need to hold any buttons, which gets you
the [default profile](profiles.md). The first boot does a bit of one-time setup: the
`USERDATA` partition grows to fill the card and gets a 512 MiB swap file, `/etc/nix-badge`
is filled with the default [LED patterns and OLED screens](bling.md), and the hostname
becomes `nix-badge`, or `nix-badge-07` for serial `SG1-0007` once the serial number is
fused (see [Installing to the eMMC](emmc.md)).

The LED ring starts animating early in boot. ARM is the default core and the faster of
the two, and on RISC-V everything comes up noticeably later, especially the desktop (see
[Switching CPU cores](cores.md)).

When the badge boots from an SD card, the login shell will remind you that it can be
installed to the eMMC. You don't have to do this, and BadgeOS runs fine from the card.

## Log in

There are two local consoles, the serial console at 115200 8N1, and the Sharp Memory
Display on the front header if you have one fitted, which shows the kernel messages and a
login prompt on `tty1`.

Log in as `badge`, which has passwordless `sudo`. The initial passwords for `badge` and
`root` come from `initialPassword` in
[`modules/sg2k/common.nix`](https://github.com/NixVegas/BadgeOS/blob/master/modules/sg2k/common.nix),
so change yours with `passwd` after logging in for the first time. `root` can only log in
on a console. The login prompt also shows the badge's IPv4 addresses on `eth0` and
`wlan0`.

## Add an SSH key

SSH only accepts keys, so add yours from a console:

```console
$ mkdir -p ~/.ssh && chmod 700 ~/.ssh
$ cat >> ~/.ssh/authorized_keys
(paste the contents of your id_ed25519.pub, then press Ctrl-D)
$ chmod 600 ~/.ssh/authorized_keys
```

Your home directory is on `USERDATA`, so the key survives reboots and updates, though a
[factory reset](profiles.md#factory-reset) will remove it.

## WiFi

WiFi is managed by NetworkManager. You can connect with `nmcli`, and `--ask` makes it
prompt for the password so it doesn't end up in your shell history:

```console
$ nmcli device wifi list
$ nmcli --ask device wifi connect "Your SSID"
```

`nmtui` does the same thing in a text UI. Saved networks are kept on `USERDATA`, so the
badge reconnects after a reboot.

> [!TIP]
> On a WPA3 (SAE) network, a profile made with `nmtui` can refuse to associate because it
> set `802-11-wireless-security.auth-alg` to `open`. You can clear it with
> `nmcli connection modify "Your SSID" 802-11-wireless-security.auth-alg ""`.

Bluetooth is powered on at boot, and you can pair things with `bluetoothctl`.

## Ethernet

In the default profile, the Ethernet port is part of the badge's own network: the badge
hands out addresses to whatever you plug in and routes it out over WiFi (see [Router and
netboot](router.md)). In the desktop profile it's a plain network port, and NetworkManager
does DHCP on `eth0`.

## USB networking

In the default profile, the USB-C port is a USB device, so if you plug it into your
computer the badge shows up as a USB network adapter (CDC-NCM). The badge serves DHCP and
DNS on that link:

| | Address |
|---|---|
| Badge | `10.55.0.1/24` |
| Your computer | from `10.55.0.100` to `10.55.0.200` |

Once your key is on the badge, you can log in over it:

```console
$ ssh badge@10.55.0.1
```

The USB link is part of the badge's own network, along with the Ethernet port. While the
badge's WiFi is connected, it offers itself as your computer's gateway, so your computer
reaches the internet through the badge; until then, your computer keeps using its own
uplink (see [Router and netboot](router.md)). The addresses are set by the
[`badge.lan`](options/badge.lan.md) options.

The desktop profile turns the port into a USB host for a keyboard and mouse instead, so
the USB link isn't there, and you'll need Ethernet or WiFi to reach the badge.

## Finding the badge on the network

The console login prompt shows the `eth0` and `wlan0` addresses. If you have an OLED
attached, the `net` screen shows them too (long-press BUTTON to get to it), and from a shell
you can always run `ip -brief address`.

## Next steps

Next, see [Profiles and buttons](profiles.md) for the desktop, the video player and the
factory reset, [LED ring and OLED screens](bling.md) to change what the badge shows, and
[Installing to the eMMC](emmc.md) to run BadgeOS without the SD card.
