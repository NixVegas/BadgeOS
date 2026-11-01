# Bad Apple!! as an iPXE console animation, for the netboot menu: the video the OLED
# blob is made from, at a size and rate a 115200 baud serial console keeps up with.
{
  runCommand,
  badapple2ipxe,
  badapple,
}:
runCommand "badapple.ipxe" { nativeBuildInputs = [ badapple2ipxe ]; } ''
  badapple2ipxe --input ${badapple.video} \
    --width 64 --height 24 --fps 12 --baud 115200 --overhead-ms 20 \
    --after none --output $out
  [ "$(head -n1 $out)" = '#!ipxe' ]
''
