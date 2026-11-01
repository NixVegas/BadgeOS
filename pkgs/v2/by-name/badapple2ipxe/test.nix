# badapple2ipxe on a one-second synthetic clip: an iPXE script that draws hex-encoded
# rows and waits between frames.
{
  runCommand,
  ffmpeg-headless,
  badapple2ipxe,
}:
runCommand "badapple2ipxe-clip"
  {
    nativeBuildInputs = [
      ffmpeg-headless
      badapple2ipxe
    ];
  }
  ''
    fail() { echo "FAIL: $*"; exit 1; }
    ffmpeg -hide_banner -loglevel error -nostdin -f lavfi -i testsrc=size=64x24:rate=12:duration=1 clip.mp4
    badapple2ipxe --input clip.mp4 --width 16 --height 4 --fps 4 --baud 115200 --overhead-ms 20 --after none --output out.ipxe
    [ "$(head -n1 out.ipxe)" = '#!ipxe' ] || fail "no #!ipxe"
    grep -q '^set [A-Za-z0-9_]*:hex ' out.ipxe || fail "no hex-encoded rows"
    grep -q 'prompt --timeout' out.ipxe || fail "no frame waits"
    touch $out
  ''
