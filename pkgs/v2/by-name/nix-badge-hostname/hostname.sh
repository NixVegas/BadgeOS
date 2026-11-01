# nix-badge-hostname NAME: the hostname, written to /etc/hostname and to the kernel. Once
# DEVICE_ID is burned, an SG1-NNNN serial appends its number (SG1-0001 gives NAME-01) and
# any other serial is appended in lower case.
if [ $# -ne 1 ]; then
  echo "usage: nix-badge-hostname NAME" >&2
  exit 2
fi
name=$1
if serial=$(nix-badge board-id --serial); then
  serial=$(printf %s "$serial" | tr '[:upper:]' '[:lower:]')
  case $serial in
    "" | *[!a-z0-9-]*) ;;
    sg1-[0-9][0-9][0-9][0-9]) name=$(printf '%s-%02d' "$name" "$((10#${serial#sg1-}))") ;;
    *) name="$name-$serial" ;;
  esac
fi
printf '%s\n' "$name" > "${HOSTNAME_ETC:-/etc/hostname}"
echo "$name" > "${HOSTNAME_KERNEL:-/proc/sys/kernel/hostname}"
