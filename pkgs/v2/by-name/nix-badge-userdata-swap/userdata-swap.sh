# nix-badge-userdata-swap [FILE [MIB]]: make the swap file on USERDATA if it is missing or
# the wrong size, then format it. Without MIB it is 256 MiB on the eMMC's own USERDATA,
# which is small, and 512 MiB on an SD card's: the one booted from, or a data card (stage 0
# then has the eMMC's read-only at /.lower-userdata). An allocation that fails leaves no
# partial file behind: ext4 keeps what fallocate got before running out, which fills
# USERDATA. NIXBADGE_BOOTMEDIUM comes from the kernel command line (systemd.setenv);
# SWAP_MOUNTINFO, SWAP_FALLOCATE and SWAP_MKSWAP stand in for the real ones.
swap=${1:-/.userdata/swap}
if [ -n "${2:-}" ]; then
  mib=$2
elif [ "${NIXBADGE_BOOTMEDIUM:-}" = 0 ] \
  && ! awk '$5 == "/.lower-userdata" { found = 1 } END { exit !found }' "${SWAP_MOUNTINFO:-/proc/self/mountinfo}"; then
  mib=256
else
  mib=512
fi
have=$(stat -c %s "$swap" 2>/dev/null || echo 0)
if [ "$have" != $((mib * 1048576)) ]; then
  rm -f "$swap"
  if ! "${SWAP_FALLOCATE:-fallocate}" -l "${mib}M" "$swap"; then
    rm -f "$swap"
    echo "no room for the ${mib} MiB swap file on $(dirname "$swap"); none made" >&2
    exit 1
  fi
  chmod 0600 "$swap"
fi
"${SWAP_MKSWAP:-mkswap}" "$swap"
