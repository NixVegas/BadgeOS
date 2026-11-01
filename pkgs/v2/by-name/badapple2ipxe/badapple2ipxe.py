#!/usr/bin/env python3
"""Compile a video into an iPXE script that plays it on the console.

Pipeline: ffmpeg decodes the input to a stream of grayscale frames at the target
size and frame rate; each pixel is thresholded to one of two characters; and an
iPXE script is emitted that draws each frame and waits between frames to hold the
frame rate.

Three iPXE realities shape the output (all verified against the iPXE source):

  * `echo` tokenises on whitespace and rejoins with single spaces, dropping
    leading indentation. The ONLY way to print exact spacing is to stash the
    bytes in a setting via `set X:hex ..` and print `${X:string}` (expansion
    happens after tokenising, so the value's spaces survive). Every drawn string
    goes through that.
  * There is no sub-second `sleep`, but `prompt`'s --timeout is in milliseconds
    (TICKS_PER_SEC=1024, so ~1ms resolution). `prompt --timeout <ms>` with no
    text is an invisible wait; it returns failure on timeout, which would abort
    the script, so it's swallowed with `|| echo -n`.
  * A found `goto` succeeds and only stops the current line, so `--loop` just
    wraps the frames in a label and jumps back.

By default only the rows that differ from the previous frame are redrawn, using
ANSI CUP (ESC[row;1H) to position each one. That is what makes a mostly-static
clip like Bad Apple feasible; `--no-delta` redraws whole frames instead.

Real frame rate is bounded by console throughput — a full 80-wide frame is
~80*H bytes, and at 115200 baud serial that alone is tens of milliseconds, so
pick a size/fps the link can actually sustain.
"""

import argparse
import shutil
import subprocess
import sys

ESC = "\x1b"


def to_hex(s: str) -> str:
    """Colon-separated hex of a string's bytes, for `set X:hex`."""
    return ":".join(f"{b:02x}" for b in s.encode("latin-1"))


def read_exact(stream, n: int) -> bytes:
    """Read exactly n bytes (a full frame) or fewer at EOF."""
    buf = bytearray()
    while len(buf) < n:
        chunk = stream.read(n - len(buf))
        if not chunk:
            break
        buf += chunk
    return bytes(buf)


def parse_args():
    p = argparse.ArgumentParser(
        description="Compile a video into an iPXE console animation script."
    )
    p.add_argument("--input", required=True, help="source video (anything ffmpeg reads)")
    p.add_argument("--output", default="-", help="output .ipxe file (default: stdout)")
    p.add_argument("--width", type=int, default=80, help="console columns (default 80)")
    p.add_argument("--height", type=int, default=48, help="console rows (default 48)")
    p.add_argument("--fps", type=float, default=10.0, help="target frames/sec (default 10)")
    p.add_argument(
        "--baud",
        type=int,
        default=0,
        help="if set, subtract each frame's transmit time (bytes*10/baud, 8N1) "
        "from its delay, so playback holds the target fps up to the link's limit "
        "and degrades to baud-limited on busy frames (e.g. --baud 115200)",
    )
    p.add_argument(
        "--overhead-ms",
        type=float,
        default=0.0,
        help="ms of per-frame iPXE processing (parse/hex-decode/echo/prompt) to "
        "ALSO subtract from each delay; raise it if playback drags (e.g. 20)",
    )
    p.add_argument("--threshold", type=int, default=128, help="0-255 luma cutoff (default 128)")
    p.add_argument("--fg", default="@", help="char for dark pixels (default '@')")
    p.add_argument("--bg", default=" ", help="char for light pixels (default space)")
    p.add_argument("--invert", action="store_true", help="swap dark/light mapping")
    p.add_argument("--no-delta", action="store_true", help="redraw whole frames, not just changed rows")
    p.add_argument("--loop", action="store_true", help="loop the animation forever")
    p.add_argument(
        "--after",
        choices=["shell", "boot", "reboot", "poweroff", "none"],
        default="shell",
        help="what to do when the animation ends (default: drop to iPXE shell)",
    )
    return p.parse_args()


def main() -> int:
    args = parse_args()
    if not shutil.which("ffmpeg"):
        sys.exit("error: ffmpeg not found on PATH")
    if len(args.fg.encode("latin-1")) != 1 or len(args.bg.encode("latin-1")) != 1:
        sys.exit("error: --fg/--bg must each be a single byte character")

    W, H = args.width, args.height
    frame_bytes = W * H
    period_ms = max(1, round(1000.0 / args.fps))

    # dark pixel -> fg, light pixel -> bg (Bad Apple: white background -> space);
    # --invert swaps. `dark`/`light` are the chars chosen per pixel below.
    dark, light = (args.fg, args.bg)
    if args.invert:
        dark, light = light, dark

    vf = f"fps={args.fps},scale={W}:{H}:flags=area,format=gray"
    ff = subprocess.Popen(
        ["ffmpeg", "-v", "error", "-i", args.input, "-vf", vf,
         "-f", "rawvideo", "-pix_fmt", "gray", "-"],
        stdout=subprocess.PIPE,
    )

    body: list[str] = []
    prev: list[str] | None = None
    nframes = 0
    total_out = 0
    while True:
        buf = read_exact(ff.stdout, frame_bytes)
        if len(buf) < frame_bytes:
            break
        rows = [
            "".join(dark if buf[y * W + x] < args.threshold else light for x in range(W))
            for y in range(H)
        ]

        # The exact strings this frame draws (each becomes a hex setting + echo).
        if args.no_delta:
            # Home, then the whole frame as one string (rows joined by newlines).
            strings = [f"{ESC}[H" + "\n".join(rows)]
        elif prev is None:
            # First frame: position and draw every row.
            strings = [f"{ESC}[{y + 1};1H{row}" for y, row in enumerate(rows)]
        else:
            # Delta: redraw only rows that changed, positioned by CUP.
            strings = [
                f"{ESC}[{y + 1};1H{row}"
                for y, (row, old) in enumerate(zip(rows, prev))
                if row != old
            ]
        for s in strings:
            body.append(f"set F:hex {to_hex(s)}")
            body.append("echo -n ${F:string}")

        # Console bytes actually emitted this frame (drives the baud compensation).
        out_bytes = sum(len(s.encode("latin-1")) for s in strings)
        total_out += out_bytes
        # Target frame time = transmit + iPXE overhead + sleep = period. Subtract
        # both the serial transmit (if --baud) and the per-frame processing cost.
        xmit_ms = round(out_bytes * 10 * 1000 / args.baud) if args.baud else 0
        delay = max(1, period_ms - xmit_ms - round(args.overhead_ms))
        body.append(f"prompt --timeout {delay} || echo -n")
        prev = rows
        nframes += 1

    ff.wait()
    if nframes == 0:
        sys.exit("error: ffmpeg produced no frames (check --input / ffmpeg output)")

    out = sys.stdout if args.output == "-" else open(args.output, "w")
    w = out.write
    w("#!ipxe\n")
    baud_note = f", baud-paced for {args.baud}" if args.baud else ""
    w(f"# Generated by badapple2ipxe: {W}x{H} @ {args.fps}fps ({period_ms}ms period"
      f"{baud_note}), {nframes} frames.\n")
    w("# Real frame rate is bounded by console/serial throughput, not the delay.\n")
    w("set E:hex 1b\n")
    w("echo -n ${E:string}[2J\n")  # clear once (ESC[2J: the only ED variant iPXE's EFI console accepts)
    if args.loop:
        w(":play\n")
    for line in body:
        w(line + "\n")
    if args.loop:
        w("goto play\n")
    trailer = {
        "shell": "echo\nshell\n",
        "boot": "chain netboot.ipxe\n",
        "reboot": "reboot\n",
        "poweroff": "poweroff\n",
        "none": "",
    }[args.after]
    w(trailer)
    if out is not sys.stdout:
        out.close()

    print(
        f"badapple2ipxe: {nframes} frames, {W}x{H}, {args.fps}fps, "
        f"{total_out} console bytes{f', baud={args.baud}' if args.baud else ''}"
        f"{' [delta]' if not args.no_delta else ''}{' [loop]' if args.loop else ''}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
