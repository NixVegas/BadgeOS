# The HDMI link

The SG2000 has no HDMI output of its own. The badge makes one from the SoC's MIPI-DSI
output with a Lontium LT8912B bridge (U16): the display engine (DISP) scans out a
frame, the DSI controller and D-PHY send it over two lanes, and the bridge turns that
into HDMI on HDMI1. Everything runs at 1280x720p60 RGB888.

Getting a stable picture out of that chain took a long time. This page is what we
learned, so you don't have to learn it again.

## What drives it

Which software owns the link depends on the profile (see [Profiles and
buttons](profiles.md)):

| Profile | DISP and DSI | The bridge |
|---|---|---|
| `desktop` | `soph_drm`, the KMS driver Sway runs on | mainline `lontium_lt8912b` |
| `video` | the vendor VDEC to VO path | `nix-badge-video`, over I2C; `lontium_lt8912b` is blacklisted |
| `default` | nothing | nothing: its device tree node is disabled |

The bridge's node is disabled outside the desktop profile because, with no DSI host
to attach to, the mainline driver defers its probe forever. Every retry asks for the
bridge's seven supplies again and logs each one, and the badge eventually ran out of
memory under the load.

In the desktop profile, `soph_drm` offers two modes, and both put a 1280x720p60 line
on the wire. At 1280x720 the video layer scans the compositor's buffer 1:1. At 640x360
the GOP overlay draws it and its own 2x scaler doubles it. The `lontium_lt8912b` patch
adds `force_720p`, so the bridge is always programmed for the 720p line whatever mode
the compositor picked.

## Power

HDMI only gets its 5 V when the badge is on USB power, so it doesn't work on batteries
alone.

The bridge has no hardware reset. Its RESET_N pin is only an RC circuit, and its 1.8 V
rail is always on, so a bridge that stops responding stays that way through a warm
reboot. If HDMI is black after `systemctl reboot` and was fine before, power-cycle the
badge.

## The bus

The bridge's control ports are on the SoC's `i2c-2` at 0x48, 0x49, 0x4a (audio) and
0x4b. The connector's DDC lines reach the same bus through two level shifters, so the
monitor's EDID EEPROM shows up there too, at 0x50:

```console
$ sudo i2cdetect -y -r 2
$ sudo i2ctransfer -f -y 2 w1@0x50 0x00 r128@0x50
```

The second command reads the first 128 bytes of the monitor's EDID, which start with
`0x00 0xff 0xff 0xff 0xff 0xff 0xff 0x00`.

If you run the vendor's Linux 5.10 image instead, its `soph_mipi_tx` driver switches
the IIC2 pads to GPIO, and the bridge then never answers on `i2c-2`. Mainline leaves
the pad mux alone.

## What it took

Each of these looked like a different fault, and each one is now handled in BadgeOS.
They're listed by what you'd see on the monitor, in case you're bringing up the link
some other way.

### A locked 720p signal, but black

The monitor says it has 1280x720 at 60 Hz, and the picture is a perfectly even black.
That's the sync polarity: the DISP and the bridge disagree about it, so the bridge
reads the blanking interval as the picture. The polarity is bits 5 and 6 (VS_POL and
HS_POL) of `DISP_CFG` at 0x0A088000, and which way they need to point depends on how
the bridge was programmed. Check this first whenever the signal locks and nothing
shows.

### Four lanes show nothing

With all four DSI lanes, the lanes wouldn't sync together and the monitor showed
nothing. Two lanes have room for 720p60 RGB888, so both paths use two.

### The picture leans

If every row is shifted about one pixel from the row above, the bridge's active width
is off by one. The badge programs 1281 instead of 1280 through the patched driver's
`hactive_offset` parameter, set by
[`hardware.sg2k.hdmi.hactiveOffset`](options/hardware.sg2k.hdmi.md#opt-hardware.sg2k.hdmi.hactiveOffset).
You can change it live in `/sys/module/lontium_lt8912b/parameters/hactive_offset`.

### Flashing

The DISPPLL is a spread-spectrum synthesizer, and left alone its frequency wanders
enough that the bridge's clock recovery loses lock now and then. The video path pins
its divider before the D-PHY comes up (the `disppll_fix_div` parameter of the patched
`cv181x_mipi_tx`); pinning it later doesn't help, because the bridge doesn't lock again
on its own.

### Streaks, a stretched picture, or "Not supported"

The badge's HDMI connector isn't exactly impedance matched, so it needs more TMDS
drive than the bridge's defaults give it. With upstream's values (0xb1, 0xb1 and 0x0e
in registers 0x31 to 0x33 of the bridge at 0x48) a direct connection streaks, shows a
stretched picture, and can come back as "unsupported" after a replug. BadgeOS writes
0xa1, 0xa1 and 0x03 instead, in both the patched `lontium_lt8912b` and the video
path. These values came from trying, not from a datasheet, and they hold for every
badge, since the cause is the board.

### Slips and blanks that depend on what's on screen

With the drive fixed, some content still upset the link: a run of near-white pixels
right next to near-black ones made the picture slip from that row down, or blanked
the monitor. It depends on what came earlier on the line, which points at the
analog link rather than at DSI. Sending limited-range RGB (16 to 235) instead of full
range makes it go away. `soph_drm` programs the DISP's output colour conversion that
way every time it turns the output on; its `rgb_limited` parameter turns it off.

## Audio

Sound goes to the monitor over HDMI: the SoC's I2S output feeds the bridge's audio
port at 0x4a, and the bridge has to be in HDMI mode, not DVI. Turn it on with
[`hardware.sg2k.hdmi.audio`](options/hardware.sg2k.hdmi.md#opt-hardware.sg2k.hdmi.audio).
The I2S controller runs from a fixed 24.576 MHz clock, which is what 48 kHz needs.

## Checking it

With a picture on screen, these are the values to compare against:

| Where | Value |
|---|---|
| `DISP_CFG` (0x0A088000) | 0x00049080 |
| DSI controller mode (0x0A08A000) | 0x00000004, and it stays set |
| bridge 0x49, register 0x04 | 0x3e (RGB888 input) |

The bridge's registers read over I2C (`i2cget -f -y 2 0x49 0x04`). The DISP and DSI
registers belong to the display drivers, so BadgeOS's kernel, which is built with
`STRICT_DEVMEM`, won't let [`nix-badge mmio`](nix-badge.md) read them; you need a kernel
without it.

Capture cards aren't a good test. Some refuse the badge's exact timing with an
"unsupported resolution" message even when a monitor shows a clean picture, so check
with a monitor before deciding the badge is at fault.
