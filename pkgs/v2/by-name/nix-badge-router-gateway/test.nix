# nix-badge-router-gateway against fake routes: the gateway and DNS options follow a
# default route on the uplink only, the file is rewritten only on a change, and only a
# change with --reload signals dnsmasq.
{ runCommand, nix-badge-router-gateway }:
runCommand "nix-badge-router-gateway-test" { } ''
  bin=${nix-badge-router-gateway}/bin/nix-badge-router-gateway
  fail() { echo "FAIL: $*"; cat opts calls 2>/dev/null; exit 1; }
  printf '#!%s\necho "$*" >> %s/calls\n' "$BASH" "$PWD" > systemctl
  chmod +x systemctl
  go() { ROUTER_GATEWAY_ROUTES=$PWD/routes ROUTER_GATEWAY_SYSTEMCTL=$PWD/systemctl $bin "$@"; }
  up=$(printf 'option:router,10.55.0.1\noption:dns-server,10.55.0.1')
  down=$(printf 'option:router\noption:dns-server')
  echo 'default via 192.168.3.1 dev wlan0 proto dhcp src 192.168.3.100 metric 600' > routes
  go wlan0 10.55.0.1 opts; [ "$(cat opts)" = "$up" ] || fail "up"
  [ "$(stat -c %a opts)" = 644 ] || fail "mode"
  : > routes; go wlan0 10.55.0.1 opts; [ "$(cat opts)" = "$down" ] || fail "no route"
  echo 'default via 10.0.0.1 dev eth0 metric 100' > routes; go wlan0 10.55.0.1 opts; [ "$(cat opts)" = "$down" ] || fail "another interface's route"
  echo 'default via 10.0.0.1 dev wlan01 metric 100' > routes; go wlan0 10.55.0.1 opts; [ "$(cat opts)" = "$down" ] || fail "prefix-named interface"
  : > calls; go --reload wlan0 10.55.0.1 opts; [ ! -s calls ] || fail "reload without a change"
  echo 'default via 192.168.3.1 dev wlan0' > routes; go --reload wlan0 10.55.0.1 opts
  [ "$(cat calls)" = 'kill --kill-whom=main --signal=SIGHUP dnsmasq.service' ] || fail "reload on change"
  rm opts; go wlan0 10.55.0.1 opts; [ "$(cat opts)" = "$up" ] || fail "missing file"
  rc=0; go wlan0 2>/dev/null || rc=$?; [ $rc = 2 ] || fail "usage"
  touch $out
''
