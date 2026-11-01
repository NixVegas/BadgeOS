# The badge's device trees, both cores: the codec island's three resets (RST_H264C,
# RST_JPEG, RST_H265C) belong to the vcodec node, whose driver pulses them before the
# first codec register access, and to no other node.
{
  pkgs,
  systems,
}:
let
  inherit (pkgs) lib;
  dtbOf = sys: "${sys.config.hardware.deviceTree.package}/${sys.config.hardware.deviceTree.name}";
in
pkgs.runCommand "dtb-codec-resets" { nativeBuildInputs = [ pkgs.dtc ]; } ''
  fail() { echo "FAIL: $*" >&2; exit 1; }
  for d in ${lib.concatMapStringsSep " " dtbOf (lib.attrValues systems)}; do
    rst=$(fdtget -t u "$d" /soc/reset-controller@3003000 phandle) \
      || fail "$d: the reset controller has no phandle"
    got=$(fdtget -t u "$d" /soc/vcodec resets 2>&1) || fail "$d: /soc/vcodec has no resets: $got"
    want="$rst 3 $rst 4 $rst 5"
    [ "$got" = "$want" ] || fail "$d: /soc/vcodec resets are '$got', not '$want'"
    for n in jpu cvi_vc_drv; do
      if fdtget "$d" /soc/$n resets > /dev/null 2>&1; then
        fail "$d: /soc/$n has resets too"
      fi
    done
  done
  touch $out
''
