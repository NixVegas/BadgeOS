# panel-touch-test.c against the touch-control core that 0001 adds, compiled for the
# build machine: the core is one header with no game around it.
{ buildPackages }:
buildPackages.runCommandCC "panel-touch-tests" { } ''
  patch -p1 < ${./0001-panel-touch.patch}
  $CC -std=c99 -Wall -Wextra -Werror -I. ${./panel-touch-test.c} -lm -o panel-touch-test
  ./panel-touch-test
  touch $out
''
