# Experimental RISC-V HDMI bring-up

This opt-in SG2000 DSI host drives a fixed 1280x720 RGB888 test pattern from
the display block's internal generator through the LT8912B to HDMI. On a warm
boot it produces vertical pinstripes. This host exposes no /dev/dri node, framebuffer,
modesetting or other mode; cold start and image payload are unverified.

The host is `pkgs/video/sophgo-dsi/src/sophgo-dsi.c`, with register provenance
in its comments. `pkgs/kernel/patches/sg2000-display.patch` carries the LT8912B
lifecycle and the clock fixes it depends on.

## Build

On an x86_64 Linux builder with Nix flakes enabled:

```sh
cfg=.#nixosConfigurations.duo-s-riscv-pinstripe-x86_64.config
nix build --cores 14 --max-jobs 1 "$cfg.system.build.toplevel"
```

Keep `flake.lock`: this configuration selects the patched kernel and matching
modules. For an existing RISC-V NixOS SD installation, deploy the build with
`nixos-rebuild` (26.05), replacing `BADGE` with its SSH address, then boot it:

```sh
nixos-rebuild boot --no-reexec --store-path "$(readlink -f result)" \
  --target-host badge@BADGE --sudo
```

The default SD image omits this driver. Testing used the installed kernel,
which retains additional clock patches; the reduced clock driver was only
compile-checked. A full rebuild and boot of this configuration are unverified.

## Badge smoke test

Boot the badge from this configuration with HDMI connected. The host binds
idle; nothing touches the display until, as root over SSH:

```sh
mainline-pinstripe test
```

It starts once, holds for 45 seconds, then stops. Expect pinstripes on HDMI,
`terminal=0 started=1 owned=1 mac=0x4 stage=idle error=0` while active, and a
final `terminal=0 started=0 owned=0 mac=0x0 stage=idle error=0`. `mac=0x4` is
the last observed DSI MAC acknowledgement of high-speed video; exit zero checks the lifecycle and
that acknowledgement, not the pixels. The helper refuses a second trial on the
same boot. After a failed stop or any other final state, do not unload or
retry: the driver keeps its resources until the board is power-cycled.

![Badge, HDMI dongle and capture laptop](assets/hdmi-capture.svg)

To record the output, connect a UVC capture dongle, find its node with
`v4l2-ctl --list-devices`, and run on the capture computer during the hold:

```sh
ffmpeg -f v4l2 -input_format mjpeg -video_size 1280x720 -framerate 60 \
  -i /dev/videoN -t 15 -c copy -n pinstripe.mkv
```

Two warm-boot trials each started, held and stopped cleanly, with pinstripes
in all 13 settled samples per recording. Judge frames after the first two
seconds; leave at least 20 seconds between recordings with the tested MS2130.

Thanks to Morgan Jones for the badge hardware and vendor-driver observations.
Illustration includes the [NixOS logo](https://github.com/NixOS/branding) by Simon Frankau, Tim Cuthbertson, Daniel Baker, and NixOS Project contributors, licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
