#!/bin/busybox sh
# The test netboot's /init: say on the serial console that it booted, then power off.
/bin/busybox mkdir -p /dev
/bin/busybox mount -t devtmpfs devtmpfs /dev
/bin/busybox echo BADGE-NETBOOT-OK > /dev/ttyS0
/bin/busybox poweroff -f
