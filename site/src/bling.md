# LED ring and OLED screens

The badge's 24-LED ring and the optional OLED panel are driven by pure Nix. Every LED
pattern and every OLED screen is a Nix function from the badge's state to a frame, and the
`nix-badge` daemons evaluate it frame after frame with an evaluator built into the daemon.
You can write your own on the badge itself and see them a second later.

## Where the content lives

At boot, `/etc/nix-badge` is filled with links to the default content:

| Path | Contents |
|---|---|
| `/etc/nix-badge/bling.d/` | LED patterns, `NN-name.nix`, cycled in name order |
| `/etc/nix-badge/oled.d/` | OLED screens, `NN-name.nix`, cycled in name order |
| `/etc/nix-badge/lib/` | Shared code for screens, imported as `<nix-badge/lib/...>` |
| `/etc/nix-badge/leds.conf` | The ring's current settings, written by `nix-badge bling set` |

The directory is meant to be edited in place. The links get refreshed on every boot, but a
regular file you put there is never overwritten, so you can also replace a default by
copying it over its link and editing the copy. `/etc` is on `USERDATA`, so your files
survive updates, though a [factory reset](profiles.md#factory-reset) will remove them.

## The button marked BUTTON

While the OLED engine is running, BUTTON controls both:

| Press | Action |
|---|---|
| short (under 0.4 s) | Next LED pattern from `bling.d` |
| long (0.4 s to 5 s) | Next OLED screen |
| hold for 5 s or more | Switch the evaluator between fix and Nix ([below](#evaluators)) |

The OLED engine is what reads the button, and it exits when no panel is attached, so
without an OLED you'll need to change patterns with `nix-badge bling set` instead.

## LED patterns

A pattern is a function of a `scope` attribute set that returns one colour per LED and the
time until the next frame:

```nix
scope: {
  bitmap = [ /* one 0xRRGGBB integer per LED */ ];
  nextMs = 33; # milliseconds until the next frame
}
```

`scope.width` is the number of LEDs (24), `scope.height` is 1, `scope.t` is a millisecond
clock, and the rest of the fields hold the badge's state (see [the scope](#the-scope)
below).

Here's a pattern that swaps red and blue halves twice a second. Save it as
`/etc/nix-badge/bling.d/70-police.nix`:

```nix
# Red and blue halves that swap twice a second.
scope:
let
  half = scope.width / 2;
  flip = (scope.t / 500) - (scope.t / 1000) * 2 == 1;
  red = 255 * 65536;
  blue = 255;
in
{
  bitmap = builtins.genList (
    i: if (i < half) != flip then red else blue
  ) scope.width;
  nextMs = 50;
}
```

Check that it evaluates, then put it on the ring:

```console
$ nix eval --impure --expr \
    '(import /etc/nix-badge/bling.d/70-police.nix) { t = 600; width = 24; }'
$ sudo nix-badge bling set --eval /etc/nix-badge/bling.d/70-police.nix
```

The LED service notices the change to `leds.conf` and switches within a frame. Since the
file is in `bling.d`, it's also part of the short-press cycle now. A pattern that fails to
evaluate gets dropped, and the ring falls back to a dim blue fill until you set another
one.

`nix-badge bling set` also changes the ring's other settings, and `nix-badge bling show`
prints the current ones:

```console
$ sudo nix-badge bling set --brightness 32 --fps 60
$ nix-badge bling show
```

## OLED screens

A screen has the same shape as a pattern, but its bitmap is the panel's memory. A 128x64
panel is 8 pages of 128 bytes, each byte is a column of 8 pixels, and each integer in
`bitmap` packs 4 of those bytes, little-endian. That means a screen returns
`width * height / 32` integers, which is 256 for a 128x64 panel and 128 for a 128x32 one. A
screen can also return `wantsScan = true` to ask for a WiFi and Bluetooth scan while it's
being shown, which is what the scan screens do.

You'll rarely need to pack bytes by hand, since `<nix-badge/lib/draw.nix>` draws text,
lines, rectangles and bars onto a surface and packs it for you. Save this as
`/etc/nix-badge/oled.d/80-hello.nix`:

```nix
# A name tag with the uptime underneath.
scope:
let
  d = import <nix-badge/lib/draw.nix> { inherit (scope) width height; };
  small = d.spleen5x8;
  s0 = d.drawText d.empty 0 0 "HELLO";
  s1 = small.drawText s0 0 (d.height - small.height) "up ${toString scope.uptimeS}s";
in
{
  bitmap = d.pack s1;
  nextMs = 1000;
}
```

`d.drawText` uses the 12x22 Sun Gallant font, and `d.spleen5x8` and `d.spleen8x16` are
smaller Spleen faces with the same `drawText` and `textWidth`. The library also has
`setPixel`, `hline`, `vline`, `rect`, `fillRect` and `drawBar`, and the default screens in
`/etc/nix-badge/oled.d` are good examples of how to use them.

Check that it evaluates, then restart the engine, which reads `oled.d` when it starts:

```console
$ nix eval --impure -I nix-badge=/etc/nix-badge --expr \
    '(import /etc/nix-badge/oled.d/80-hello.nix) { width = 128; height = 64; uptimeS = 42; }'
$ sudo systemctl restart nix-badge-oled
```

A screen that fails to compile is skipped and the others still load. The engine's log
(`journalctl -u nix-badge-oled`) says which one failed and why.

## The scope

Both kinds of program get these fields, though a pattern won't use all of them:

| Field | Meaning |
|---|---|
| `t` | Milliseconds on a monotonic clock |
| `frameIndex` | Frame counter, rising by one each frame |
| `width`, `height` | Panel size in pixels, or the LED count and 1 |
| `batteryMv`, `batteryPct` | Battery pack voltage and charge estimate |
| `vselMv` | The system supply rail, near 5000 on USB power |
| `onUsb` | Whether USB power is present |
| `load1` | One-minute load average (a float) |
| `cpuPct`, `memPct` | CPU and memory use, in percent |
| `uptimeS` | Seconds since boot |
| `strap` | The core the boot strap selects: 1 ARM, 2 RISC-V, 0 unknown |
| `backend` | The evaluator running this program: 0 fix, 1 Nix |
| `fps` | The measured frame rate |
| `nixosVersion`, `kernelVersion` | Strings for the running system (screens) |
| `ethName`, `ethIp`, `wlanName`, `wlanIp` | Network interfaces and their IPv4 addresses (screens) |

## Evaluators

There are two evaluators that can run these programs. The default is
[fix](https://github.com/psyclyx/fix), an embedded Nix evaluator written in Zig that runs
on both cores. The other is the upstream Nix evaluator through its C API, which is only
linked on ARM, so asking for it on RISC-V falls back to fix.

Holding BUTTON for 5 seconds switches the OLED engine between them, and the choice is
remembered in `/etc/nix-badge/oled.backend`. The defaults come from the
[`badge.oled.backend`](options/badge.oled.md#opt-badge.oled.backend) and
[`badge.bling.backend`](options/badge.bling.md#opt-badge.bling.backend)
options.

## Writing fast programs

Your program runs every frame on a small CPU.

Anything that doesn't depend on `scope` should be hoisted into a `let` above the lambda,
since a table built inside the function gets rebuilt on every frame. The default effects
do this with their lookup tables and fonts.

Stick to builtins so that both evaluators can run your program. There's no nixpkgs `lib`
on the badge, but integer helpers like `mod` are in `<nix-badge/lib/oled.nix>` and
`draw.nix`. Colours, coordinates and the clock are all integers, so keep your math in
integers too.

Only ask for frames as often as you need them, since `nextMs` sets the frame rate, and a
clock only needs one frame a second.

The demoscene effects in `/etc/nix-badge/oled.d` (`70-xor` to `76-rotozoom`) and the Bad
Apple player in `10-badapple.nix` are good examples of fast screens.

## In your NixOS configuration

The same programs can be set declaratively:

```nix
{
  badge.bling.evalPattern = ./my-pattern.nix;
  badge.oled.evalScreens = [ ./my-screen.nix ];
}
```

[`badge.bling`](options/badge.bling.md) also sets the LED count, the SPI timing and
the brightness, and [`badge.oled`](options/badge.oled.md) sets the panel size, the
controller and the button.
