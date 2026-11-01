# RAUC's pre-install handler. While a data card is in use (stage 0 mounted the eMMC's
# USERDATA read-only at /.lower-userdata), an install, which writes the eMMC's slots, is
# refused. PRE_INSTALL_MOUNTINFO stands in for /proc/self/mountinfo in tests.
if awk '$5 == "/.lower-userdata" { found = 1 } END { exit !found }' "${PRE_INSTALL_MOUNTINFO:-/proc/self/mountinfo}"; then
  echo "RAUC installs are not allowed while a data card is in use: power off, take the card out and boot again to install" >&2
  exit 1
fi
