# Switching CPU cores

The SG2000 has two application processors, and it runs one of them at a time:

| Core | Nix system | Notes |
|---|---|---|
| ARM Cortex-A53 | `aarch64-linux` | The default, and the faster of the two |
| RISC-V T-Head C906 | `riscv64-linux` | Slower; the desktop takes minutes longer to come up |

A hardware strap decides which core runs at power-on. A BadgeOS card has a complete
system for each core, and its single `fip.bin` boots whichever one the strap selects (see
[How BadgeOS boots](under-the-hood.md)), so switching cores only takes a reboot. On a
LicheeRV Nano the strap is a resistor, so switching means moving it (see
[The LicheeRV Nano](bsp.md#the-licheerv-nano)).
The software backend below can request RISC-V while the board remains strapped to ARM.

## The `builtins.currentSystem` switch

The badge's core switch is labelled `builtins.currentSystem`. Yes, really, this is not a
joke. It has three positions: two of them force the ARM (`aarch64-linux`) or the RISC-V
(`riscv64-linux`) core, and the third, AUTO, takes the choice from a latch that software
can set, which is what the commands below use.

## Switching from Linux

Check the current selection, latch the other core, and reboot with the switch on AUTO:

```console
$ nix-badge core status
strap readback: 0 (arm)
$ nix-badge core riscv
core-select latch set to riscv
strap readback: 1 (riscv)
$ sudo systemctl reboot
```

`nix-badge core arm` switches back. The latch is driven through GPIO lines, and the
`badge` user is in the `gpio` group, so this doesn't need `sudo`. If the strap still
reads the old core after `nix-badge core`, the switch isn't set to AUTO.

## Switching with the BOOT button

With the switch on AUTO, holding BOOT for 3 seconds while the badge is running latches the
other core and reboots into it. A short press does nothing.

## What differs between the cores

Both systems are built from the same configuration, but each core has its own kernel,
device tree and boot image, under `/boot/arm` and `/boot/riscv`. Each core also keeps its
own system profile (`system-arm` and `system-riscv`), so deploying to one core never
removes the other core's generation, and a deploy never switches cores.

We don't recommend building on the badge on either core. Build on your computer and
deploy instead (see [Updating](updating.md)).

The pure-Nix LED patterns and screens run on either evaluator, but the upstream Nix C API
evaluator is only available on ARM (see [LED ring and OLED screens](bling.md#evaluators)).

## Software selection on the Nano

Set `hardware.sg2k.coreSelect.enable` with `coreSelect.backend = "software"` to build the
unsigned polyglot firmware, which can pass the boot to the other core from the SD card.
The board stays strapped to ARM and needs both cores' payloads in both SD slots.
Deploying the generation installs its firmware the usual way, through the bootloader.
Secure boot isn't supported with this backend.

The reboot helper runs as root. Before it changes a boot marker, it checks that BOOT is
the SD card's FAT partition, that the board booted from the card, that the installed
firmware is this generation's, and that every payload is there. It saves the old request
and pending files in a new `/boot/core-reboot-*.orig` directory, flushes the card and
reboots. If a step fails it puts the old markers back, and it refuses a second request
while one is running.

A RISC-V request is for the next boot only. The firmware keeps its pending marker as a
guard against a failed boot, and nothing in BadgeOS marks the RISC-V boot good, so the
next plain reboot comes up on ARM. To boot RISC-V again, request it again; the new
request archives the old pending marker.

Request a core and reboot through its guarded service:

```console
$ sudo systemctl start badge-core-reboot@riscv.service
$ sudo systemctl start badge-core-reboot@arm.service
```

To go back to ARM, start `badge-core-reboot@arm.service` rather than rebooting: it clears
both markers. A plain reboot from RISC-V also comes up on ARM, but through the firmware's
failed-boot guard, and the markers stay on the card until the next request.
