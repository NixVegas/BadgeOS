# Nothing the badge runs to map media buffers names /dev/mem: soph-mpi's libraries
# export ION memory through /dev/soph-ion, coda-cube does the same, and the desktop's
# coda-cube service leaves the codec reset to the kernel.
{
  pkgs,
  badgePkgs,
}:
let
  inherit (badgePkgs) soph-mpi coda-cube badge-coda-cube;
in
pkgs.runCommand "devmem-free" { } ''
  fail() { echo "FAIL: $*" >&2; exit 1; }
  for p in ${soph-mpi}/lib ${coda-cube} ${badge-coda-cube}; do
    if hits=$(grep -rlaE '/dev/mem([^a-z_-]|$)' "$p"); then
      fail "these name /dev/mem: $hits"
    fi
  done
  grep -qaF /dev/soph-ion ${soph-mpi}/lib/libsys.so || fail "libsys.so never opens /dev/soph-ion"
  if [ -e ${badge-coda-cube}/libexec/badge-coda-cube/soph-codec-reset ]; then
    fail "badge-coda-cube still installs soph-codec-reset"
  fi
  touch $out
''
