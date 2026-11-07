# The LicheeRV Nano's device tree for each core, plain and with each fragment: memory,
# model, pin controller, reserved regions, GPIO names, and the nodes the fragments switch
# or add.
{ pkgs }:
let
  dtbOf =
    core: args:
    "${
      pkgs.sg2k-dtb.override (
        {
          board = "licheerv-nano";
          inherit core;
        }
        // args
      )
    }/sophgo/sg2002-licheerv-nano.dtb";
  checks = core: ''
    check ${core} ${dtbOf core { }} \
      ${dtbOf core { dtsFragments = [ "licheerv-nano-no-wifi.dtsi" ]; }} \
      ${dtbOf core { dtsFragments = [ "licheerv-nano-no-ethernet.dtsi" ]; }} \
      ${dtbOf core { usbHost = true; }} \
      ${dtbOf core { dtsFragments = [ "licheerv-nano-dsi-panel.dtsi" ]; }}
  '';
in
pkgs.runCommand "dtb-licheerv-nano" { nativeBuildInputs = [ pkgs.dtc ]; } ''
  fail() { echo "FAIL: $core: $*" >&2; exit 1; }
  # is <dtb> <node> <property> <want> [fdtget type]
  is() {
    got=$(fdtget ''${5:+-t $5} "$1" "$2" "$3" 2>&1) || fail "$2 $3: $got"
    [ "$got" = "$4" ] || fail "$2 $3 is '$got', not '$4'"
  }

  # check <core> <plain> <no-wifi> <no-ethernet> <usb-host> <dsi-panel>
  check() {
    core=$1 d=$2
    dtc -I dtb -O dts -o plain.dts $d 2> /dev/null
    is $d /memory@80000000 reg "80000000 10000000" x
    is $d / model "LicheeRV Nano"
    is $d /soc/pinctrl@3001000 compatible sophgo,sg2002-pinctrl
    is $d /reserved-memory/region@8fe00000 reg "8fe00000 200000" x
    if grep -q ramoops plain.dts; then fail "the tree has a ramoops node"; fi
    if grep -q cvi_vpss plain.dts; then fail "the tree has a cvi_vpss node"; fi

    # porta's line names, one per line, from the property's bytes
    for b in $(fdtget -t bx $d /soc/gpio@3020000/gpio-controller@0 gpio-line-names); do
      printf "\\x$b"
    done | tr '\0' '\n' > porta.names
    [ "$(sed -n 15p porta.names)" = user-led ] || fail "porta 14 is '$(sed -n 15p porta.names)', not user-led"
    [ "$(sed -n 27p porta.names)" = wifi-poweron ] || fail "porta 26 is '$(sed -n 27p porta.names)', not wifi-poweron"
    [ "$(sed -n 31p porta.names)" = user-btn ] || fail "porta 30 is '$(sed -n 31p porta.names)', not user-btn"

    is $d /soc/mmc@4320000 compatible cvitek,cv181x-sdio
    is $d /soc/mmc@4320000 status okay
    is $3 /soc/mmc@4320000 status disabled
    is $d /soc/ethernet@4070000 status okay
    is $4 /soc/ethernet@4070000 status disabled
    is $d /soc/usb@4340000 dr_mode peripheral
    is $5 /soc/usb@4340000 dr_mode host
    is $d /soc/serial@4150000 status disabled

    p=$6
    is $p /backlight compatible pwm-backlight
    is $p /soc/pwm@3062000 status okay
    is $p /soc/cvi_vpss interrupt-names sc
    is $p /soc/i2c@4040000 status okay
    is $p /soc/i2c@4040000/touchscreen@5a compatible hynitron,cst340
    is $p /soc/i2c@4040000/touchscreen@5a interrupts "3 2" x
    for b in $(fdtget -t bx $p /soc/gpio@5021000/gpio-controller@0 gpio-line-names); do
      printf "\\x$b"
    done | tr '\0' '\n' > porte.names
    [ "$(sed -n 1p porte.names)" = lcd-reset ] || fail "porte 0 is '$(sed -n 1p porte.names)', not lcd-reset"
    [ "$(sed -n 4p porte.names)" = tp-irq ] || fail "porte 3 is '$(sed -n 4p porte.names)', not tp-irq"
    [ "$(sed -n 5p porte.names)" = tp-reset ] || fail "porte 4 is '$(sed -n 5p porte.names)', not tp-reset"
  }

  ${checks "riscv"}
  is $d /reserved-memory/mmode_resv0@80000000 reg "80000000 80000" x
  is $p /soc/cvi_vpss interrupts "19 4" x

  ${checks "arm"}
  is $d /cpus/cpu@0 compatible arm,cortex-a53
  is $d /soc/interrupt-controller@1f01000 compatible arm,cortex-a15-gic
  is $d /soc/watchdog@3010000 reg "3010000 1000" x
  is $p /soc/cvi_vpss interrupts "0 9 4" x
  # every interrupt is in the GIC's three cells
  if grep -E 'interrupts = <0x[0-9a-f]+ 0x[0-9a-f]+>;' plain.dts; then
    fail "an interrupt is not in the GIC's form"
  fi
  touch $out
''
