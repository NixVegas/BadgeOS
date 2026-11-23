# test.c with the sanitizers: the WiFi QR parser, and a QR code through the scanner's reader.
{
  runCommandCC,
  pkg-config,
  zxing-cpp,
  qrencode,
}:
runCommandCC "badge-camera-test"
  {
    src = ./.;
    nativeBuildInputs = [ pkg-config ];
    buildInputs = [
      zxing-cpp
      qrencode
    ];
  }
  ''
    san="-fsanitize=address,undefined"
    $CC -O2 -Wall -Wextra -Werror $san -I$src $($PKG_CONFIG --cflags libqrencode) \
      -c $src/test.c $src/wifiqr.c $src/convert.c
    $CXX -O2 -Wall -Wextra -Werror $san -I$src -c $src/qrread.cc
    $CXX $san *.o -o camera-qr $($PKG_CONFIG --libs libqrencode) -lZXing
    ./camera-qr
    touch $out
  ''
