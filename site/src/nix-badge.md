# The nix-badge command

`nix-badge` is BadgeOS's own tool, written in Zig. Some of its subcommands are what the
badge's services run, and the rest are for you. Run it without arguments for a usage
summary.

## Commands for you

`nix-badge power` prints the system rail (VSEL, about 5 V on USB power) and the battery
pack's voltage with an estimate of how much charge is left. The pack is three AA
primaries, so there's no charging state.

`nix-badge core arm`, `nix-badge core riscv` and `nix-badge core status` set and read the
core-select latch (see [Switching CPU cores](cores.md)).

`nix-badge bling show` prints the LED ring's settings, and `sudo nix-badge bling set`
changes them in `/etc/nix-badge/leds.conf`, keeping whatever you don't pass:

| Flag | Setting |
|---|---|
| `--brightness 0-255` | Brightness |
| `--fps N` | Frame rate |
| `--count N` | Number of LEDs |
| `--speed-hz HZ` | SPI clock |
| `--bits 3\|4\|8` | SPI bits per LED data bit |
| `--eval PATH` | A Nix pattern (see [LED ring and OLED screens](bling.md)) |
| `--blob PATH` | A prerecorded animation to play instead of a pattern |

`nix-badge board-id` decodes the identity fused into the SoC. On its own it prints every
field, whether the badge is provisioned, and the state of the device key. `--serial` and
`--product` print a single field, and `--store-path` prints the Nix store path of the PCB
design that the badge was built from, which is also burned into its eFuses. With a field
flag it exits non-zero if that field isn't fused.

`sudo nix-badge mmio read ADDR` and `sudo nix-badge mmio write ADDR VALUE` read and write
32-bit physical registers. Be careful with it: reading a block that isn't clocked can hang
the whole SoC. The kernel never lets it at RAM, and lets it at a register a driver has claimed
(see `/proc/iomem`) only when the badge was booted with `iomem=relaxed` added to the kernel
command line by hand.

`nix-badge fix-selftest` and `nix-badge nix-selftest` smoke-test the two Nix evaluators
(see [Evaluators](bling.md#evaluators)). The upstream Nix one is only built on ARM.

## Commands the services run

| Command | Service | What it does |
|---|---|---|
| `nix-badge bling run` | `nix-badge-bling` | Drives the LED ring |
| `nix-badge oled` | `nix-badge-oled` | Runs the OLED screens and reads BUTTON |
| `nix-badge bootswap` | `nix-badge-bootswap` | Switches cores when BOOT is held for 3 seconds (see [Switching CPU cores](cores.md#switching-with-the-boot-button)) |
