# nix-badge-install [--no-repartition]: --no-repartition fails rather than offering to
# reinstall an eMMC whose slots are too small for the new system.
# NIX_BADGE_INSTALL_CMDLINE and NIX_BADGE_INSTALL_UID stand in for /proc/cmdline
# and the caller's uid in the tests.
repartition=ask
for a in "$@"; do
  case $a in
    --no-repartition) repartition=no ;;
    *) echo "usage: nix-badge-install [--no-repartition]" >&2; exit 2 ;;
  esac
done

# Whole tokens, padded so "=10" cannot match.
cmdline=" $(cat "${NIX_BADGE_INSTALL_CMDLINE:-/proc/cmdline}") "
case $cmdline in
  *' nixbadge.bootmedium=1 '*) ;;
  *) echo "nix-badge-install: not booted from the SD card; boot the badge from its SD card first" >&2; exit 1 ;;
esac
if [ "${NIX_BADGE_INSTALL_UID:-$(id -u)}" != 0 ]; then
  echo "nix-badge-install: must run as root: sudo nix-badge-install" >&2
  exit 1
fi

ask() {
  # $1: prompt. Sets $answer; end of input aborts.
  printf '%s' "$1"
  IFS= read -r answer || { echo; echo "nix-badge-install: aborted" >&2; exit 1; }
}

yes_no() {
  # $1: prompt. Returns 0 for yes, 1 for no; re-asks on anything else.
  while :; do
    ask "$1"
    case $answer in
      yes) return 0 ;;
      no) return 1 ;;
      *) echo "Please enter yes or no." ;;
    esac
  done
}

# --detect exits 0 for an installed eMMC (updated, user data kept), 3 for "not
# installed" (erased), 4 for an installed eMMC whose slots are too small for the new
# system (erased, after its own question), 5 when this SD card's own system cannot be
# installed, and 1 when it refuses outright, as it does without an eMMC. Asked first,
# so a board with nothing to install to is refused before any question.
rc=0
nix-badge-emmc-update --detect || rc=$?
case $rc in
  0 | 3) ;;
  4)
    if [ "$repartition" = no ]; then
      echo "nix-badge-install: the new system does not fit this eMMC's store slots, and --no-repartition was given" >&2
      exit 1
    fi
    ;;
  1) echo "nix-badge-install: no eMMC to install to" >&2; exit 1 ;;
  5) echo "nix-badge-install: this SD card's system can't be installed (the reason is above)" >&2; exit 1 ;;
  *) echo "nix-badge-install: cannot tell whether the eMMC is installed" >&2; exit 1 ;;
esac

state=$(nix-badge board-id) || { echo "nix-badge-install: cannot read the eFuses" >&2; exit 1; }
provisioned=$(printf '%s\n' "$state" | sed -n 's/^provisioned: //p')
key=$(printf '%s\n' "$state" | sed -n 's/^device-key: //p')
fused_serial=$(printf '%s\n' "$state" | sed -n 's/^serial: *//p')

serial=
case $provisioned in
  yes)
    echo "This badge is already fused: $fused_serial"
    case $key in
      locked) ;;
      blank)
        echo "Its device key is not burned yet."
        if yes_no "Set it up now? [yes/no] "; then
          case $fused_serial in
            SG1-[0-9][0-9][0-9][0-9]) serial=$fused_serial ;;
            *) echo "The stored serial is not SG1-NNNN, so U-Boot cannot be asked to burn the key." ;;
          esac
        fi
        ;;
      *)
        # A key that is burned but not locked is never touched again.
        echo "Warning: its device key is burned but NOT locked ($key); it cannot be finished from here."
        ;;
    esac
    ;;
  no)
    echo "We are setting up the SoC for the first time."
    while [ -z "$serial" ]; do
      ask "Please enter the serial number, written on the ethernet port: "
      case $answer in
        '' | *[!0-9]*) continue ;;
      esac
      # Leading zeros are fine (00007 is 7); more than two digits after them is not.
      n=$answer
      while [ "${n#0}" != "$n" ]; do n=${n#0}; done
      case $n in
        '' | ???*) continue ;;
      esac
      [ "$n" -ge 2 ] && [ "$n" -le 25 ] || continue
      if yes_no "Is $n correct? This is permanent! [yes/no] "; then
        serial=$(printf 'SG1-%04d' "$n")
      fi
    done
    echo "Fuse settings will be applied at reboot."
    ;;
  *)
    echo "nix-badge-install: nix-badge board-id gave no provisioned: line" >&2
    exit 1
    ;;
esac

case $rc in
  0)
    mode=update
    nix-badge-emmc-update --plan
    yes_no "Update both eMMC slots now? Its user data is kept. [yes/no] " || { echo "nix-badge-install: nothing installed"; exit 1; }
    nix-badge-emmc-update --yes
    ;;
  4)
    mode=install
    echo "The new system does not fit this eMMC's store slots (an older, 2 GiB layout)."
    echo "Moving it to the 3 GiB layout reinstalls the eMMC and erases its user data."
    nix-badge-emmc-init --plan
    yes_no "Repartition the eMMC to the 3 GiB layout now? This erases its user data. [yes/no] " \
      || { echo "nix-badge-install: nothing installed"; exit 1; }
    nix-badge-emmc-init --yes
    ;;
  3)
    mode=install
    nix-badge-emmc-init --plan
    yes_no "Install to the eMMC now? This erases it. [yes/no] " || { echo "nix-badge-install: nothing installed"; exit 1; }
    nix-badge-emmc-init --yes
    ;;
esac

if [ -n "$serial" ]; then
  # The SD's env, the eMMC's (boot area 2), then the eMMC's UBOOT partition copy.
  fw_setenv -c /etc/fw_env-sd.config nixbadge_fuse_serial "$serial"
  fw_setenv nixbadge_fuse_serial "$serial"
  nix-badge-env-mirror
fi

# The card as a data card for the system just installed, which has them on when this one
# does (it is this one): the card stops booting and keeps what it holds.
card=no
case $cmdline in
  *' nixbadge.datacard=1 '*)
    echo
    echo "This SD card can also become a data card for the eMMC system: it then stops"
    echo "booting, keeps what is on it, and takes everything the badge writes."
    if yes_no "Turn this SD card into a data card for the eMMC system? [yes/no] "; then
      if nix-badge-make-data-card; then
        card=yes
      else
        echo "nix-badge-install: the SD card is not a data card (the reason is above); it still boots" >&2
      fi
    fi
    ;;
esac

echo
if [ "$mode" = update ]; then echo "Updated."; else echo "Installed."; fi
if [ -n "$serial" ]; then
  cat <<EOM
Set the builtins.currentSystem switch to Auto and reboot: the badge switches to
the RISC-V core, which fuses what is missing of the serial ($serial), the board
record and the device key, then switches back and resets itself. With the switch
on ARM the serial and board record are fused and the key waits for a RISC-V
boot; on RISC-V everything is fused. If you skip this, the serial and board
record are still fused on the next boot, and the device key is burned the next
time the badge boots the RISC-V core.
EOM
fi
if [ "$card" = yes ]; then
  echo "The SD card is a data card now: the badge boots from the eMMC with it in. The"
  echo "first boot runs without the card, the next one uses it."
else
  echo "To run the installed system, power off, remove the SD card and power on: the"
  echo "badge then boots from the eMMC."
fi
printf 'Press Enter to reboot. '
read -r _ || echo
systemctl reboot
