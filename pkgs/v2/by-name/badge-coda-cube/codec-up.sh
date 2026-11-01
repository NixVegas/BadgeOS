#!/usr/bin/env bash
# Load the codec modules, once per boot. cv181x_vcodec pulses the codec island's
# resets as it probes, which a warm reboot needs; a reset under a live driver
# would hang it, so a loaded stack is left alone.
set -euo pipefail
PATH=@path@

if [ -e /sys/module/cvi_vc_driver ]; then
	echo "codec-up: cvi_vc_driver is loaded already"
	exit 0
fi
for m in cv181x_vcodec cv181x_jpeg cvi_vc_driver; do
	modprobe "$m"
done
# errors only
echo 1 > /sys/module/cvi_vc_driver/parameters/vcodec_mask
echo "codec-up: codec modules loaded"
