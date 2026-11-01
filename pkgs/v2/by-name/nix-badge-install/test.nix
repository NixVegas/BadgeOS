# nix-badge-install against stubs that log their argv, with scripted answers on stdin.
{
  lib,
  runCommand,
  writeShellScriptBin,
  nix-badge-install,
}:
let
  # $STUB_PROVISIONED: yes or no; $STUB_KEY: the device-key state (locked when
  # provisioned, blank otherwise, unless set)
  nix-badge = writeShellScriptBin "nix-badge" ''
    echo "nix-badge $*" >> "$LOG"
    if [ "$STUB_PROVISIONED" = yes ]; then
      echo 'store-path: /nix/store/dchav4nca8fzz7lcc9zadjxjcrvs920p-nix-badge-board-2.0-20260706-07f6efc'
      echo 'product:    nix-badge-board 2.0 (20260706, 07f6efc)'
      echo 'serial:     SG1-0003'
    else
      echo 'store-path: (USER unprovisioned)'
      echo 'product:    (USER unprovisioned)'
      echo 'serial:     (DEVICE_ID unprovisioned)'
    fi
    echo "provisioned: $STUB_PROVISIONED"
    if [ -n "''${STUB_KEY:-}" ]; then
      echo "device-key: $STUB_KEY"
    elif [ "$STUB_PROVISIONED" = yes ]; then
      echo 'device-key: locked'
    else
      echo 'device-key: blank'
    fi
  '';
  logger = name: writeShellScriptBin name ''echo ${name} "$@" >> "$LOG"'';
  # $STUB_DETECT: what --detect exits with (3, not installed, unless set; 4 needs a
  # repartition; 5 the SD's own system is unusable)
  nix-badge-emmc-update = writeShellScriptBin "nix-badge-emmc-update" ''
    echo "nix-badge-emmc-update $*" >> "$LOG"
    if [ "$1" = --detect ]; then exit "''${STUB_DETECT:-3}"; fi
  '';
  installer = nix-badge-install.override {
    inherit nix-badge nix-badge-emmc-update;
    nix-badge-emmc-init = logger "nix-badge-emmc-init";
    nix-badge-env-mirror = logger "nix-badge-env-mirror";
    nix-badge-make-data-card = logger "nix-badge-make-data-card";
    systemd = logger "systemctl";
    ubootTools = logger "fw_setenv";
  };
in
runCommand "nix-badge-install-test" { } ''
  bin=${lib.getExe installer}
  printf 'console=ttyS0 nixbadge.bootmedium=1 rauc.external nixbadge.datacard=1\n' > sd
  printf 'console=ttyS0 nixbadge.bootmedium=1 rauc.external\n' > sdnocards
  printf 'console=ttyS0 nixbadge.bootmedium=0\n' > emmc
  printf 'console=ttyS0 nixbadge.bootmedium=10\n' > ten
  fail() { echo "FAIL: $*"; cat out err log 2>/dev/null; exit 1; }
  # run <cmdline> <uid> <provisioned> <stdin> [arg ...]: exit status in $rc
  run() {
    : > log
    rc=0
    c=$1 u=$2 p=$3 i=$4
    shift 4
    printf "$i" | LOG=$PWD/log STUB_PROVISIONED=$p NIX_BADGE_INSTALL_CMDLINE=$PWD/$c \
      NIX_BADGE_INSTALL_UID=$u "$bin" "$@" > out 2> err || rc=$?
  }

  # not an SD boot (also not a substring match), and not root: refused, nothing run
  for c in emmc ten; do
    run $c 0 no ""
    [ $rc = 1 ] && grep -q 'not booted from the SD card' err && [ ! -s log ] || fail "$c boot not refused"
  done
  run sd 1000 no ""
  [ $rc = 1 ] && grep -q 'must run as root: sudo nix-badge-install' err && [ ! -s log ] || fail "non-root not refused"

  # already fused: no serial prompt, no fuse mention, no fw_setenv; a blank eMMC
  # (detect exits 3): the emmc-init plan, one confirmation, install, reboot
  run sd 0 yes 'yes\nno\n\n'
  [ $rc = 0 ] || fail "provisioned run failed"
  grep -q 'already fused: SG1-0003' out || fail "provisioned serial not shown"
  grep -q 'serial number\|Fuse settings\|currentSystem' out && fail "fuse talk on a fused badge"
  [ "$(cat log)" = "$(printf '%s\n' 'nix-badge-emmc-update --detect' 'nix-badge board-id' 'nix-badge-emmc-init --plan' \
    'nix-badge-emmc-init --yes' 'systemctl reboot')" ] || fail "provisioned call order"
  grep -q 'Install to the eMMC now? This erases it. \[yes/no\] ' out && grep -qx 'Installed.' out \
    || fail "erase path prompt or closing line"
  grep -q 'remove the SD card' out || fail "closing text without a data card"

  # the card becomes a data card: asked (again after a bad answer), converted after the
  # install, then the reboot, with the closing words for an eMMC boot with the card in
  run sd 0 yes 'yes\nmaybe\nyes\n\n'
  [ $rc = 0 ] || fail "data card run failed"
  [ "$(grep -o 'Turn this SD card into a data card for the eMMC system? \[yes/no\] ' out | wc -l)" = 2 ] \
    || fail "data card prompt"
  [ "$(cat log)" = "$(printf '%s\n' 'nix-badge-emmc-update --detect' 'nix-badge board-id' 'nix-badge-emmc-init --plan' \
    'nix-badge-emmc-init --yes' 'nix-badge-make-data-card' 'systemctl reboot')" ] || fail "data card call order"
  grep -q 'boots from the eMMC with it in' out && ! grep -q 'remove the SD card' out || fail "data card closing text"
  # ... not offered when the system has data cards off
  run sdnocards 0 yes 'yes\n\n'
  [ $rc = 0 ] && ! grep -q 'data card' out && ! grep -q make-data-card log && grep -q 'remove the SD card' out \
    || fail "offered with data cards off"

  # blank: rejected serials (0, 1, 26, abc, empty, 100) re-prompt; 00007 is 7, and
  # "no" goes back to the serial; 07, a bad answer re-asks, yes; then the install,
  # both envs, the mirror, the reboot
  run sd 0 no '0\n1\n26\nabc\n\n100\n00007\nno\n07\nmaybe\nyes\nyes\nno\n\n'
  [ $rc = 0 ] || fail "blank run failed"
  head -n1 out | grep -qx 'We are setting up the SoC for the first time.' || fail "first-time line"
  [ "$(grep -o 'Please enter the serial number, written on the ethernet port: ' out | wc -l)" = 8 ] \
    || fail "serial prompts: $(grep -o 'Please enter the serial number' out | wc -l), want 8"
  [ "$(grep -o 'Is 7 correct? This is permanent! \[yes/no\] ' out | wc -l)" = 3 ] || fail "confirm prompts"
  [ "$(grep -o 'Please enter yes or no\.' out | wc -l)" = 1 ] || fail "bad answer not re-asked once"
  grep -q 'Fuse settings will be applied at reboot\.$' out || fail "fuse line"
  grep -q 'switch to Auto and reboot' out && grep -q 'serial (SG1-0007)' out || fail "closing text does not explain the fuse step"
  [ "$(cat log)" = "$(printf '%s\n' 'nix-badge-emmc-update --detect' 'nix-badge board-id' 'nix-badge-emmc-init --plan' \
    'nix-badge-emmc-init --yes' \
    'fw_setenv -c /etc/fw_env-sd.config nixbadge_fuse_serial SG1-0007' \
    'fw_setenv nixbadge_fuse_serial SG1-0007' 'nix-badge-env-mirror' 'systemctl reboot')" ] \
    || fail "blank call order"

  # fused, device key blank: offered; yes -> the stored serial goes to both envs
  # after the install, so U-Boot burns the key
  STUB_KEY=blank run sd 0 yes 'maybe\nyes\nyes\nno\n\n'
  [ $rc = 0 ] && grep -q 'device key is not burned yet' out \
    && [ "$(grep -o 'Set it up now? \[yes/no\] ' out | wc -l)" = 2 ] || fail "blank key not offered"
  grep -q 'switch to Auto and reboot' out || fail "key-only closing text"
  [ "$(cat log)" = "$(printf '%s\n' 'nix-badge-emmc-update --detect' 'nix-badge board-id' 'nix-badge-emmc-init --plan' \
    'nix-badge-emmc-init --yes' \
    'fw_setenv -c /etc/fw_env-sd.config nixbadge_fuse_serial SG1-0003' \
    'fw_setenv nixbadge_fuse_serial SG1-0003' 'nix-badge-env-mirror' 'systemctl reboot')" ] \
    || fail "blank key call order"
  # ... no -> the eMMC install only
  STUB_KEY=blank run sd 0 yes 'no\nyes\nno\n\n'
  [ $rc = 0 ] && ! grep -q fw_setenv log && grep -q 'emmc-init --yes' log || fail "declined key still set the env"
  # burned but not locked: a warning, no offer, no env
  STUB_KEY=set-unlocked run sd 0 yes 'yes\nno\n\n'
  [ $rc = 0 ] && grep -q 'burned but NOT locked' out && ! grep -q 'Set it up now' out && ! grep -q fw_setenv log \
    || fail "set-unlocked key"

  # an installed eMMC (detect exits 0): the update plan, its own confirmation, the
  # update, never emmc-init; then the reboot
  STUB_DETECT=0 run sd 0 yes 'maybe\nyes\nno\n\n'
  [ $rc = 0 ] || fail "update run failed"
  [ "$(grep -o 'Update both eMMC slots now? Its user data is kept\. \[yes/no\] ' out | wc -l)" = 2 ] \
    || fail "update prompt (asked twice after a bad answer)"
  grep -q 'This erases it' out && fail "erase prompt on an installed eMMC"
  grep -qx 'Updated\.' out || fail "update closing line"
  [ "$(cat log)" = "$(printf '%s\n' 'nix-badge-emmc-update --detect' 'nix-badge board-id' \
    'nix-badge-emmc-update --plan' 'nix-badge-emmc-update --yes' 'systemctl reboot')" ] \
    || fail "update call order"
  # ... with blank eFuses: the update, then the serial in both envs and the mirror
  STUB_DETECT=0 run sd 0 no '9\nyes\nyes\nno\n\n'
  [ $rc = 0 ] && [ "$(cat log)" = "$(printf '%s\n' 'nix-badge-emmc-update --detect' 'nix-badge board-id' \
    'nix-badge-emmc-update --plan' 'nix-badge-emmc-update --yes' \
    'fw_setenv -c /etc/fw_env-sd.config nixbadge_fuse_serial SG1-0009' \
    'fw_setenv nixbadge_fuse_serial SG1-0009' 'nix-badge-env-mirror' 'systemctl reboot')" ] \
    || fail "update with serial call order"
  # ... declined: nothing written, no reboot
  STUB_DETECT=0 run sd 0 yes 'no\n'
  [ $rc = 1 ] && grep -q 'nothing installed' out && ! grep -q 'fw_setenv\|systemctl\|--yes\|emmc-init' log \
    || fail "declined update still wrote"
  # no eMMC (detect refuses, exit 1): refused before the eFuses are read or anything
  # is asked
  STUB_DETECT=1 run sd 0 no ""
  [ $rc = 1 ] && [ "$(cat err)" = 'nix-badge-install: no eMMC to install to' ] \
    && ! grep -q 'serial number' out && [ "$(cat log)" = 'nix-badge-emmc-update --detect' ] \
    || fail "no-emmc not refused first"
  # the SD's own system is unusable (detect exits 5): said as such, before anything is
  # asked, not as a missing eMMC
  STUB_DETECT=5 run sd 0 no ""
  [ $rc = 1 ] && [ "$(cat err)" = "nix-badge-install: this SD card's system can't be installed (the reason is above)" ] \
    && [ "$(cat log)" = 'nix-badge-emmc-update --detect' ] || fail "an unusable SD system not reported"
  # detect failing otherwise (exit 2): a stop, also before anything is asked
  STUB_DETECT=2 run sd 0 yes 'yes\n\n'
  [ $rc = 1 ] && grep -q 'cannot tell whether the eMMC is installed' err \
    && [ "$(cat log)" = 'nix-badge-emmc-update --detect' ] \
    || fail "detect failure not a stop"

  # the new system does not fit an old layout's slots (detect exits 4): the reinstall
  # is offered, naming the erased user data; yes -> emmc-init, as for a blank eMMC
  STUB_DETECT=4 run sd 0 yes 'yes\nno\n\n'
  [ $rc = 0 ] && grep -q 'does not fit this eMMC' out \
    && grep -q 'Repartition the eMMC to the 3 GiB layout now? This erases its user data\. \[yes/no\] ' out \
    && grep -qx 'Installed.' out || fail "repartition offer"
  [ "$(cat log)" = "$(printf '%s\n' 'nix-badge-emmc-update --detect' 'nix-badge board-id' 'nix-badge-emmc-init --plan' \
    'nix-badge-emmc-init --yes' 'systemctl reboot')" ] || fail "repartition call order"
  # ... no -> nothing written
  STUB_DETECT=4 run sd 0 yes 'no\n'
  [ $rc = 1 ] && grep -q 'nothing installed' out && ! grep -q 'fw_setenv\|systemctl\|--yes' log \
    || fail "declined repartition still wrote"
  # ... --no-repartition: a stop before anything is asked
  STUB_DETECT=4 run sd 0 yes 'yes\n\n' --no-repartition
  [ $rc = 1 ] && grep -q 'does not fit this eMMC.*--no-repartition' err \
    && [ "$(cat log)" = 'nix-badge-emmc-update --detect' ] || fail "--no-repartition did not stop"
  # --no-repartition leaves an update that fits alone
  STUB_DETECT=0 run sd 0 yes 'yes\nno\n\n' --no-repartition
  [ $rc = 0 ] && grep -q 'nix-badge-emmc-update --yes' log || fail "--no-repartition stopped an update"
  # any other argument: usage, nothing run
  run sd 0 yes "" --bogus
  [ $rc = 2 ] && grep -q '^usage: nix-badge-install' err && [ ! -s log ] || fail "usage"

  # declining the eMMC install: nothing written, no reboot
  run sd 0 no '25\nyes\nno\n'
  [ $rc = 1 ] && ! grep -q 'fw_setenv\|systemctl\|--yes' log || fail "declined install still wrote"

  # end of input at any prompt aborts instead of looping
  run sd 0 no '5\n'
  [ $rc = 1 ] && grep -q aborted err && ! grep -q 'emmc-init' log || fail "EOF not an abort"

  # a failing emmc-init stops before the envs and the reboot
  installerFails=${
    lib.getExe (
      nix-badge-install.override {
        inherit nix-badge nix-badge-emmc-update;
        nix-badge-emmc-init = writeShellScriptBin "nix-badge-emmc-init" ''
          echo "nix-badge-emmc-init $*" >> "$LOG"; [ "$1" = --plan ]
        '';
        nix-badge-env-mirror = logger "nix-badge-env-mirror";
        nix-badge-make-data-card = logger "nix-badge-make-data-card";
        systemd = logger "systemctl";
        ubootTools = logger "fw_setenv";
      }
    )
  }
  : > log
  rc=0
  printf '7\nyes\nyes\n' | LOG=$PWD/log STUB_PROVISIONED=no NIX_BADGE_INSTALL_CMDLINE=$PWD/sd \
    NIX_BADGE_INSTALL_UID=0 "$installerFails" > out 2> err || rc=$?
  [ $rc != 0 ] && grep -q 'emmc-init --yes' log && ! grep -q 'fw_setenv\|systemctl' log \
    || fail "emmc-init failure did not stop the install"

  # a conversion that fails is said so; the install stands, the card still boots, and the
  # badge reboots as without one
  cardFails=${
    lib.getExe (
      nix-badge-install.override {
        inherit nix-badge nix-badge-emmc-update;
        nix-badge-emmc-init = logger "nix-badge-emmc-init";
        nix-badge-env-mirror = logger "nix-badge-env-mirror";
        nix-badge-make-data-card = writeShellScriptBin "nix-badge-make-data-card" ''
          echo "nix-badge-make-data-card $*" >> "$LOG"; exit 1
        '';
        systemd = logger "systemctl";
        ubootTools = logger "fw_setenv";
      }
    )
  }
  : > log
  rc=0
  printf 'yes\nyes\n\n' | LOG=$PWD/log STUB_PROVISIONED=yes NIX_BADGE_INSTALL_CMDLINE=$PWD/sd \
    NIX_BADGE_INSTALL_UID=0 "$cardFails" > out 2> err || rc=$?
  [ $rc = 0 ] && grep -q 'the SD card is not a data card' err && grep -q 'remove the SD card' out \
    && [ "$(tail -n1 log)" = 'systemctl reboot' ] || fail "a failed conversion"

  echo PASS > $out
''
