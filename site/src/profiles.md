# Profiles and buttons

Every BadgeOS generation has three boot profiles, and U-Boot picks one based on the
buttons you hold at power-up.

| Hold at power-up | Profile | What you get |
|---|---|---|
| nothing | `default` | LED ring, OLED screens, router and netboot |
| BOOT (S1) | `desktop` | Sway on HDMI with games and a demo; the USB port is a host |
| BUTTON (S3) | `video` | A full-screen H.264 clip player on HDMI |
| BOOT and BUTTON | `default`, after a [factory reset](#factory-reset) | A fresh `USERDATA` partition |

Hold the button while you switch the badge on, and keep holding it until the status LED
stops blinking, since U-Boot reads the buttons at the end of its short countdown. (The
verified-boot U-Boot has no countdown and reads them right away.) The buttons only pick a
profile at power-up. Once Linux is running, BUTTON drives the LEDs and screens, and
holding BOOT for 3 seconds [switches cores](cores.md#switching-with-the-boot-button).

All three profiles are part of the same generation and share `USERDATA`, so your files,
keys and WiFi networks are there in all of them.

## default

This is the everyday profile. The LED ring animates from early boot, and the optional
OLED shows status screens and effects (see [LED ring and OLED screens](bling.md)). The
USB-C port is a USB device that gives your computer a [network link to the
badge](getting-started.md#usb-networking), and with the Ethernet port it makes up the
badge's own [routed network](router.md). BUTTON changes the LED pattern with a
short press, the OLED screen with a long press, and the evaluator if you hold it for 5
seconds.

## desktop

This runs Sway on the HDMI output at 1280x720, logged in as `badge`. The SG2000 has no 3D
GPU, so the compositor draws with pixman and OpenGL programs run on llvmpipe on the CPU.
The USB-C port becomes a USB host for a keyboard, mouse or hub, and the OLED engine is
turned off.

The desktop comes with:

- `badge-demo`, "Nix Fixes This", a 640x360 CPU-rendered demoscene production with a
  chiptune (<kbd>Esc</kbd> quits)
- `badge-quake3`, ioquake3 with the Quake III demo data, tuned for llvmpipe at 640x360
- `badge-doom`, crispy-doom with the Freedoom WADs
- the `foot` terminal

With a keyboard attached:

| Keys | Action |
|---|---|
| <kbd>Super</kbd>+<kbd>Return</kbd> | Open a terminal |
| <kbd>Super</kbd>+<kbd>Shift</kbd>+<kbd>Q</kbd> | Close the focused window |
| <kbd>Super</kbd>+<kbd>Shift</kbd>+<kbd>E</kbd> | Exit Sway |
| <kbd>Super</kbd>+<kbd>Shift</kbd>+<kbd>M</kbd> | Put the output back in the desktop mode |

The games switch the output to a 640x360 mode, which has a quarter of the pixels to draw,
and put it back when they exit. Sound goes to the monitor over HDMI.

The desktop is configured by the [`badge.graphics`](options/badge.graphics.md) options,
and [`badge.desktop.enable`](options/badge.desktop.md) controls whether the profile gets
built at all.

## video

This is a clip player for HDMI that uses the SG2000's hardware H.264 decoder and its video
output path directly, without a compositor. It plays every `*.264` or `*.h264` file in
`/var/lib/nix-badge-video` in name order. A short press of BUTTON skips to the next clip,
and a press of 600 ms or longer goes back to the previous one.

The clips have to be raw H.264 Annex-B streams without audio. You can convert a video on
your computer with ffmpeg and copy it over from any profile, then boot into the video
profile:

```console
$ ffmpeg -i in.mp4 -an -c:v libx264 -bsf:v h264_mp4toannexb -f h264 clip.264
$ scp clip.264 badge@10.55.0.1:
$ ssh badge@10.55.0.1 'sudo mkdir -p /var/lib/nix-badge-video && sudo mv clip.264 /var/lib/nix-badge-video/'
```

The player owns BUTTON in this profile, so the OLED engine is off. The
[`badge.video`](options/badge.video.md) options set the folder, the frame rate and the
long-press time.

## Factory reset

Holding BOOT and BUTTON together at power-up boots the default profile with a request to
reset, and `USERDATA` is reformatted before anything mounts it. That removes everything
you've changed, including your home directory and SSH keys, saved WiFi networks, edits
under `/etc` (`/etc/nix-badge` included), and anything a deploy added to the Nix store.
The system on the read-only store partition isn't touched.

This is useful when a change to `/etc` stops the badge from booting properly, or before
you give the badge to someone else.

With a [data card](data-cards.md) in the slot, the reset formats the card's
`EXT_USERDATA` instead, and the eMMC keeps everything. Take the card out first if you want
to reset the eMMC.

## Changing the button mapping

U-Boot reads the profile names from its environment, in `nixbadge_profile_default`,
`nixbadge_profile_boot` and `nixbadge_profile_user` (U-Boot and the rest of the software
call BUTTON the USER button). An unset or invalid name falls back to the built-in one, and
a profile that the generation doesn't have falls back to `default`. You can change them
from Linux with `fw_setenv`, though which environment that edits depends on where the
badge booted from (see [How BadgeOS boots](under-the-hood.md#the-u-boot-environment)).
