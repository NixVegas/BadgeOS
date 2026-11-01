# nix-badge-hostname against a fake nix-badge: no serial keeps the name, an SG1-NNNN serial
# appends its number (at least two digits), any other serial is appended in lower case, and
# one with other characters is left out.
{
  runCommand,
  writeShellScriptBin,
  nix-badge-hostname,
}:
let
  fakeNixBadge = writeShellScriptBin "nix-badge" ''
    [ "$*" = "board-id --serial" ] || exit 3
    [ -e "$SERIAL_FILE" ] || exit 1
    cat "$SERIAL_FILE"
  '';
  bin = "${nix-badge-hostname.override { nix-badge-noeval = fakeNixBadge; }}/bin/nix-badge-hostname";
in
runCommand "nix-badge-hostname-test" { } ''
  fail() { echo "FAIL: $*"; cat etc kernel 2>/dev/null; exit 1; }
  export SERIAL_FILE=$PWD/serial HOSTNAME_ETC=$PWD/etc HOSTNAME_KERNEL=$PWD/kernel
  check() { [ "$(cat etc)" = "$1" ] && [ "$(cat kernel)" = "$1" ] || fail "$2"; }
  ${bin} nix-badge; check nix-badge "no serial"
  printf SG1-0001 > serial; ${bin} nix-badge; check nix-badge-01 "an SG1 serial"
  printf SG1-0009 > serial; ${bin} nix-badge; check nix-badge-09 "an SG1 serial with an 8 or 9"
  printf SG1-0123 > serial; ${bin} nix-badge; check nix-badge-123 "a three-digit SG1 serial"
  printf sg1-0042 > serial; ${bin} nix-badge; check nix-badge-42 "an SG1 serial in lower case"
  printf SG1-01 > serial; ${bin} nix-badge; check nix-badge-sg1-01 "a short SG1 serial"
  printf ABC-12 > serial; ${bin} nix-badge; check nix-badge-abc-12 "another serial"
  printf 'SG1_0001' > serial; ${bin} nix-badge; check nix-badge "a serial with an underscore"
  : > serial; ${bin} nix-badge; check nix-badge "an empty serial"
  rc=0; ${bin} 2>/dev/null || rc=$?; [ $rc = 2 ] || fail "usage"
  touch $out
''
