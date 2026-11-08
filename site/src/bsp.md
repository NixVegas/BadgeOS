# Using the NixOS module

BadgeOS is also a board support package for the Sophgo SG200x family, as a set of NixOS
modules. That covers the kernel and device trees, the boot firmware and boot images, the
A/B storage layout, WiFi, the display, and the badge's own peripherals. It's one module
that does nothing until you enable it.

The flake exposes `nixosModules.v2` (also available as `nixosModules.default`), which is
the board support package itself, and `overlays.v2` (also `overlays.default`) with its
packages, which the module adds to `nixpkgs.overlays` on its own. There's also
`overlays.v1` with the firmware for last year's ESP32-C6 badge, which needs the
[nixpkgs-esp-dev](https://github.com/mirrexagon/nixpkgs-esp-dev) overlay applied as well.

## In your flake

BadgeOS builds on NixOS 26.05, so follow its nixpkgs:

```nix
{
  inputs = {
    badgeos.url = "github:NixVegas/BadgeOS";
    nixpkgs.follows = "badgeos/nixpkgs-2605";
  };

  outputs =
    { nixpkgs, badgeos, ... }:
    {
      nixosConfigurations.my-badge = nixpkgs.lib.nixosSystem {
        modules = [
          badgeos.nixosModules.default
          {
            hardware.sg2k.enable = true;
            # The board, "nix-badge" by default; the system runs on its first core
            # (ARM on the badge) unless nixpkgs.hostPlatform says otherwise.
            hardware.sg2k.board = "nix-badge";

            # Your own configuration.
            networking.hostName = "my-badge";
          }
        ];
      };
    };
}
```

`hardware.sg2k.enable` enables the whole board support package. Set
`nixpkgs.hostPlatform` to `"riscv64-linux"` for the badge's C906 core (the Nano runs on
its C906 unless you set `"aarch64-linux"` for its A53), and `nixpkgs.buildPlatform` to
cross-build from your machine.

## Boards and hardware

`hardware.sg2k.board` picks the board, either `nix-badge` (our badge, an SG2000) or
`licheerv-nano` (the Sipeed LicheeRV Nano, an SG2002). Both chips have an ARM and a
RISC-V core, and BadgeOS builds a system for each. The board turns on the hardware it
has, and you can turn any of it off with `hardware.sg2k.emmc.enable`, `ethernet.enable`,
`wifi.enable` (with `wifi.bluetooth`), `hdmi.enable` (with `hdmi.audio`),
`ledRing.enable`, `oled.enable`, `sharpPanel.enable` and `coreSelect.enable`. When a
piece of hardware is off, the services, drivers and images that use it are left out. On
the badge, `ethernet.enable` doesn't do anything yet, and turning WiFi off leaves its
SDIO controller enabled in the device tree.

### The LicheeRV Nano

The Nano runs one of its two cores, and a small (0201) strap resistor on the board decides
which one at power-on. It ships set for the RISC-V core, and to boot the ARM core you
move the resistor to its other position with a soldering iron. There's no switch or
latch like the badge's, so the core can't be changed from Linux or with a button, and
`coreSelect.enable` stays off.

There are three SD card images for the Nano:

| Package | Systems on the card | `fip.bin` |
|---|---|---|
| `licheerv-nano-sdcard` | ARM and RISC-V | The polyglot fip, for either core |
| `licheerv-nano-sdcard-riscv` | RISC-V | The RISC-V fip |
| `licheerv-nano-sdcard-arm` | ARM | The ARM fip |

The two-core card has a system for each core and the polyglot fip, so it's the one to use
if you're going to move the resistor. A one-core card builds only one system, and it only
boots when the resistor selects its core. Every Nano system installs the polyglot fip
when it's deployed or updated, so a one-core card's `fip.bin` becomes the polyglot after
its first update. The `licheerv-nano-bundle` update carries both cores, like the two-core
card, so installing it on a one-core card adds the other core.

```console
$ nix build github:NixVegas/BadgeOS#licheerv-nano-sdcard
```

Write it to a card the same way as the badge's (see [Getting started](getting-started.md)).
The firmware on its own is in `licheerv-nano-fip` (the polyglot), `licheerv-nano-fip-arm`
and `licheerv-nano-fip-riscv`, and the two systems deploy as `licheerv-nano-arm` and
`licheerv-nano-riscv` (see [Updating](updating.md)).

The MaixCAM is a Nano on a carrier with an ST7701 368x552 DSI panel and a Hynitron CST340
touchscreen. `hardware.sg2k.dsiPanel.enable` turns them on: the device tree gets the
panel, its backlight and the touchscreen, the fip releases the touchscreen's pads from the
RTC power sequencer, and `st7701-panel-init` brings the panel up at boot on colour bars.
The touchscreen is an ordinary input device.

### Other boards

If your board is close to one of these but not quite the same, everything a board file
sets is only a default, including `soc`, `cores`, `memory.sizeMiB`, `dtb.name`,
`dtb.package` and `firmware.fips`, so you can set your own values and they'll take over.
A `dtb.package` needs to support `.override { kernel; usbHost; }`, and `firmware.fips`
needs a `fipArm` or `fipRiscv` for each core in `cores`, and a `fipPolyglot` when there
are two. A new board should get its own value of `hardware.sg2k.board` and a board file
in `modules/sg2k/boards`, and we're happy to take patches for that.

## What you can change

Everything the badge configures is an option, and the options are documented in the
[options reference](options/index.md) and on the [search page](options/search.md). A
custom board will usually set some of the following:

- the LED ring's LED count and SPI timing, or turn it off
- the OLED panel's size and controller, or turn the engine off
- the USB role, and the addresses that the USB network link uses
- whether the desktop and video profiles get built
- signed firmware and verified boot, for fused parts
