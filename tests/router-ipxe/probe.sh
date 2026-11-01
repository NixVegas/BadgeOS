#!/bin/sh
# udhcpc script for the router test's probes: record what a lease offered, configure nothing.
case "$1" in
  bound | renew)
    printf 'router=%s\ndns=%s\nboot_file=%s\n' "$router" "$dns" "$boot_file" > /tmp/lease
    ;;
esac
