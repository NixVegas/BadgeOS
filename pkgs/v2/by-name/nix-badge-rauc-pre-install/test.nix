# The pre-install handler against fake mount tables: refused with a data card in use
# (/.lower-userdata mounted), allowed without one.
{ runCommand, nix-badge-rauc-pre-install }:
runCommand "nix-badge-rauc-pre-install-test" { } ''
  bin=${nix-badge-rauc-pre-install}/bin/nix-badge-rauc-pre-install
  case1='29 1 179:35 / / ro - squashfs /dev/root ro
  31 29 179:37 / /.userdata rw,nosuid,nodev,noatime - ext4 /dev/mmcblk1p5 rw'
  printf '%s\n' "$case1" > case1
  printf '%s\n' "$case1" '40 29 179:37 / /.lower-userdata ro,nosuid,nodev,noatime - ext4 /dev/mmcblk1p5 ro' \
    | sed 's|/.userdata rw,nosuid,nodev,noatime - ext4 /dev/mmcblk1p5|/.userdata rw,nosuid,nodev,noatime - ext4 /dev/mmcblk0p2|' > case3
  # a path that only starts with /.lower-userdata is no data card
  printf '%s\n' "$case1" '41 29 0:50 / /.lower-userdata-x rw - tmpfs tmpfs rw' > lookalike
  rc=0; PRE_INSTALL_MOUNTINFO=$PWD/case3 $bin > out 2> err || rc=$?
  [ $rc = 1 ] && grep -q '^RAUC installs are not allowed while a data card is in use' err \
    || { echo "case 3 not refused (exit $rc)"; cat out err; exit 1; }
  for m in case1 lookalike; do
    PRE_INSTALL_MOUNTINFO=$PWD/$m $bin || { echo "$m refused"; exit 1; }
  done
  touch $out
''
