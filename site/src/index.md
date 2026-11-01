# BadgeOS

<video src="https://relive.nix.vegas/share/video/6ZE3in8vcoko7EtG8PC2CkG7d3_eyc68VTgMnGrKVRYsaTh9L_3VlNxZseOKXC4wUc8/9b6fcf04-9b25-4133-9e2a-2953fabfa123" poster="https://relive.nix.vegas/share/photo/6ZE3in8vcoko7EtG8PC2CkG7d3_eyc68VTgMnGrKVRYsaTh9L_3VlNxZseOKXC4wUc8/c0b11824-3348-4f01-b07d-90250e326d6c/preview" width="100%" autoplay muted loop playsinline>
<img src="https://relive.nix.vegas/share/photo/6ZE3in8vcoko7EtG8PC2CkG7d3_eyc68VTgMnGrKVRYsaTh9L_3VlNxZseOKXC4wUc8/c0b11824-3348-4f01-b07d-90250e326d6c/preview" alt="The Nix Vegas badge on a lanyard, its LED snowflake lit" width="100%">
</video>

<!-- @VERSION_NOTE@ -->

BadgeOS is [NixOS](https://nixos.org) for the Nix Vegas DEF CON badge, and for the
[Sipeed LicheeRV Nano](https://wiki.sipeed.com/hardware/en/lichee/RV_Nano/1_intro.html).
The badge is a small single board computer built around a
[Milk-V Duo Module 01](https://milkv.io/docs/duo/getting-started/duo-module-01), whose
Sophgo SG2000 has two very different CPUs in it, an ARM Cortex-A53 and a RISC-V C906.
The SD card has a complete NixOS install for each of them, and you pick which one
boots (see [Switching CPU cores](site/src/cores.md)). The Nano's SG2002 has the same two
cores, and a strap resistor on the board picks one (see
[The LicheeRV Nano](site/src/bsp.md#the-licheerv-nano)).

Everything on the badge comes from [one repository](https://github.com/NixVegas/BadgeOS)
and is built with Nix, including the kernel, the bootloader, the system for each core,
and even the LED patterns and OLED screens, which are small Nix functions that the badge
evaluates every frame.

## Where to start

If you just got a badge, [Getting started](site/src/getting-started.md) walks through booting it,
logging in, and getting it on a network, and [Profiles and buttons](site/src/profiles.md) covers
the desktop and the video player.

If you want to change what the LEDs and the OLED show, [LED ring and OLED
screens](site/src/bling.md) explains how the patterns and screens work and how to write your own
on the badge itself.

If you want to keep running BadgeOS without the SD card, [Installing to the
eMMC](site/src/emmc.md) moves it onto the badge's own storage, and [Updating](site/src/updating.md) covers
keeping it current afterwards.

If you're working on other SG200x hardware, [How BadgeOS boots](site/src/under-the-hood.md)
describes the storage layout and the boot chain, and [Using the NixOS
module](site/src/bsp.md) shows how to use BadgeOS as a board support package in your own flake.
[The SoM](site/src/som.md) covers the SG2000 itself, what doesn't work yet, and JTAG, and
[Contributing](site/src/contributing.md) covers working on BadgeOS itself.

If something isn't working, try [Troubleshooting](site/src/troubleshooting.md), and
[Security](site/src/security.md) covers the default login and what the badge exposes.

The [options reference](site/src/options/index.md) lists every option we declare, and there's a
[search page](site/src/options/search.md) for it too.

## The hardware

This is the short version; [The hardware](site/src/hardware.md) has the connectors, the pinouts
and what the silkscreen labels mean.

| Part | What BadgeOS does with it |
|---|---|
| SG2000: ARM Cortex-A53 and RISC-V C906 | Boots either one ([switching cores](site/src/cores.md)) |
| 24 WS2812 LEDs on SPI3 | Runs [Nix patterns](site/src/bling.md) on them from early boot |
| SAO connector, I2C OLED (SSD1306 or SH1106) | Status screens and effects, also [written in Nix](site/src/bling.md) |
| Sharp Memory Display header | The text console (`tty1`) |
| HDMI out, through an LT8912B MIPI-DSI bridge | Desktop and video [profiles](site/src/profiles.md), with HDMI audio |
| AIC8800 WiFi and Bluetooth | NetworkManager and BlueZ |
| 10/100 Ethernet | The badge's own network, routed out over WiFi, with [netboot](site/src/router.md) |
| USB-C | A USB network link to your computer on the same network, or a USB host port in the desktop profile |
| eMMC | An optional [install target](site/src/emmc.md) with A/B updates |
| BOOT, RESET and BUTTON | BOOT and BUTTON pick a profile at power-up, and BUTTON also drives the LEDs and screens |
| AA battery pack, voltage-sense ADCs | `nix-badge power` shows the rails and the battery |

The AA batteries are there because we accidentally ordered a lot of them for last year's
badge, and this one needed to use them somehow.

## Source

BadgeOS lives at [github.com/NixVegas/BadgeOS](https://github.com/NixVegas/BadgeOS)
under the LGPL-3.0. The bootloader builds and our SG2000 mask ROM research are in
[NixVegas/sophgone](https://github.com/NixVegas/sophgone), and the PCB is on
[git.nixos.lv](https://git.nixos.lv/NixVegas/pcb) since it doesn't fit on GitHub
anymore. Last year's ESP32-C6 badge has its own
[README](https://github.com/NixVegas/BadgeOS/blob/master/v1.md).
