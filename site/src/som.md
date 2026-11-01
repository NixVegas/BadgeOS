# The SoM

The badge is built around a [Milk-V Duo Module
01](https://milkv.io/docs/duo/getting-started/duo-module-01), a small castellated module
with a Sophgo SG2000, an AIC8800 for WiFi and Bluetooth, and eMMC on it. Milk-V publishes
the module's hardware files in
[milkv-duo/duo-files](https://github.com/milkv-duo/duo-files/tree/main/duo-module-01).

## The SG2000

The SG2000 has more cores in it than you'd expect:

- an ARM Cortex-A53 and a RISC-V C906, both at 1 GHz, of which one runs Linux depending on
  the [core switch](cores.md)
- a second, smaller C906 at 700 MHz that can run alongside either of them
- an 8051 microcontroller
- 512 MB of DRAM in the same package
- a 0.5 TOPS (INT8) TPU, and H.264/H.265 encode and decode (the [video
  profile](profiles.md#video) uses the H.264 decoder)

Sophgo's documentation for it is in
[sophgo/sophgo-doc](https://github.com/sophgo/sophgo-doc/tree/main/SG200X), including the
technical reference manual (the [v1.02
TRM](https://github.com/sophgo/sophgo-doc/releases/download/sg2000-trm-v1.02/sg2000_trm_en_v1.02.pdf)
is the newest we know of). Sophgo tracks its mainline kernel work on the
[sophgo/linux wiki](https://github.com/sophgo/linux/wiki), and the vendor display and video
drivers that BadgeOS's HDMI support and video player are ported from are in
[sophgo/osdrv](https://github.com/sophgo/osdrv) and
[sophgo/cvi_mpi](https://github.com/sophgo/cvi_mpi). Our own notes on the boot ROM are in
[sophgone](https://github.com/NixVegas/sophgone).

## Limitations

There's still plenty left to do on this chip:

- Battery life is short. You'll get a few hours out of a set of AAs at best, because
  Linux isn't using any of the SoC's low-power modes yet.
- The little C906 isn't used yet. We want to try running the LED ring's SPI on it, and to
  get Linux into the lower-power modes.
- The MIPI camera input isn't wired up on the badge. The MIPI display output (DSI) is,
  and goes to the HDMI bridge.
- The TPU isn't up under BadgeOS. It works under Milk-V's Debian image, but its drivers
  still need to be forward-ported to the mainline kernel.
- The RISC-V core is noticeably slower than the ARM one (see [Switching CPU
  cores](cores.md)).

## JTAG

The two big cores are debugged in different ways, and both go through the CH347 behind
the DEBUG port. BadgeOS packages OpenOCD with the CH347 driver as `openocd-ch347` (the
OpenOCD in nixpkgs is too old to have it), along with configs for the badge, so you can run
it on the computer the DEBUG port is plugged into:

```console
$ nix run github:NixVegas/BadgeOS#openocd-ch347 -- -f badge/c906.cfg
```

The configs live in
[`pkgs/v2/by-name/openocd-ch347/scripts`](https://github.com/NixVegas/BadgeOS/tree/master/pkgs/v2/by-name/openocd-ch347/scripts).
Starting OpenOCD reconfigures the CH347, which kills its serial console until you reset
the USB device (`nix shell nixpkgs#usbutils -c usbreset 1a86:55dd`), so it's best not to
rely on the console while you're debugging.

### RISC-V

The C906's JTAG is the ordinary four-wire kind (TCK, TMS, TDI, TDO and TRST), and the
badge wires it to the CH347, so the DEBUG port is all you need. It only answers while the
badge is booted on the RISC-V core. Use `badge/c906.cfg`. Examining the core can be flaky,
so if `init` fails, try again or lower the adapter speed. Memory access while Linux is
running is fiddly, since the MMU is on.

### ARM

The A53 uses the SG2000's two-wire debug mode, which is ARM's SWD (a standard SW-DP, not
cJTAG). Its two pins are the MIPI_TX_1 pair, which the badge uses for DSI lane 1 to the
HDMI bridge, so they aren't wired to the CH347 and you'll need to add two wires:

1. On the running ARM system, switch the pads over to the debug port. The pin controller
   owns these registers, so this needs a boot with `iomem=relaxed` added to the kernel
   command line by hand:
   ```console
   $ sudo nix-badge mmio write 0x030011AC 0
   $ sudo nix-badge mmio write 0x030011B0 0
   ```
   This lasts across a warm reset but not a power cycle, and takes that DSI lane away
   from the HDMI bridge while it's set.
2. Wire MIPI_TX_1N to the CH347's TMS (SWDIO), MIPI_TX_1P to its TCK (SWCLK), and
   connect ground. J2's TMS (pin 5) and TCK (pin 2) are the CH347's side of those lines
   (see [The hardware](hardware.md#the-other-headers)).

Then use `badge/a53.cfg`. Besides the core itself, it sets up `a53.axi`, which reads and
writes physical memory without halting the core. The first connection after power-up
sometimes fails to read the debug port's IDR, and running it again works.

### Resetting a hung badge

When the console is dead but the chip is still powered, the SG2000's watchdog can reset
it, as long as the SWD wiring and pad mux above were set up before the badge hung.
`badge/wdt-reset.cfg` reads the watchdog and `RTC_EN_WDT_RST_REQ`, the register that turns
its request into a chip reset (it has to read 1), and with `FIRE` set it arms the watchdog
for an immediate reset:

```console
$ nix run github:NixVegas/BadgeOS#openocd-ch347 -- -f badge/wdt-reset.cfg
$ nix run github:NixVegas/BadgeOS#openocd-ch347 -- -c "set FIRE 1" -f badge/wdt-reset.cfg
```
