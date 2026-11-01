#!/usr/bin/env bash
# Recover the VPU when the codec island hangs. Reloading the codec stack resets
# it: cv181x_vcodec pulses the codec resets as it probes. A driver too stuck to
# unload needs them pulsed first (SW_RSTN_0 bits 3-5, active-low; display resets
# are untouched), through pk, which the kernel allows only when booted with
# iomem=relaxed: reset-simple owns that register.
set -u
P=${PK:-/home/badge/hdmi/ko/pk}

if out=$(sudo -n $P 0x03003000) && before=$(awk '{print $3}' <<< "$out") && [ -n "$before" ]; then
	echo "SW_RSTN_0 before: $before"
	sudo -n $P 0x03003000 $(( before & ~0x38 )) >/dev/null   # assert h264c/jpeg/h265c
	sleep 1
	sudo -n $P 0x03003000 "$before"              >/dev/null   # release
	echo "SW_RSTN_0 after:  $(sudo -n $P 0x03003000 | awk '{print $3}')"
else
	echo "SW_RSTN_0 not reachable (boot with iomem=relaxed for that); reloading only"
fi

for m in cvi_vc_driver cv181x_jpeg cv181x_vcodec; do
	printf 'rmmod %-16s ' "$m"; sudo -n rmmod "$m" 2>&1 && echo ok
done
sleep 2
for m in cv181x_vcodec cv181x_jpeg cvi_vc_driver; do
	printf 'modprobe %-16s ' "$m"; sudo -n modprobe "$m" 2>&1 && echo ok
done
sleep 3

echo 1 | sudo -n tee /sys/module/cvi_vc_driver/parameters/vcodec_mask >/dev/null
echo "vpu timeouts since load: $(sudo -n dmesg | grep -c vdi_wait_vpu_busy)"
