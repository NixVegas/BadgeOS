#!/usr/bin/env bash
# Single live run: full display recipe first, then one pump producer.
# blvo5's teardown stops the DISP timing generator, so the recipe goes first.
exec > /tmp/h264live.out 2>&1
set -x
MW=/home/badge/hdmi/mw
KO=/home/badge/hdmi/ko
P=$KO/pk

sudo -n pkill -x blvo5; sudo -n pkill -x vofeed; sudo -n pkill -x blvo4
sleep 3

sudo -n /run/current-system/sw/bin/soph-display-load >/dev/null 2>&1
sudo -n modprobe cvi_vc_driver
sleep 1
v=$(sudo -n $P 0x0A088000 | awk '{print $3}'); sudo -n $P 0x0A088000 $(( v | 0x40000 )) >/dev/null
sudo -n $KO/dsiup --lanes 2 --vpol 0 --hpol 0
sleep 1
sudo -n env LANES_REG=0x02 sh /tmp/lt-land1281.sh
c=$(sudo -n $P 0x0A088000 | awk '{print $3}'); sudo -n $P 0x0A088000 $(( c & ~0x60 )) >/dev/null
d=$(sudo -n $P 0x0A088000 | awk '{print $3}'); sudo -n $P 0x0A088000 $(( d | 0x10000 )) >/dev/null
sudo -n $P 0x03002860 0x40 >/dev/null; sudo -n $P 0x03002860 0x41 >/dev/null
echo 1 | sudo -n tee /sys/module/cvi_vc_driver/parameters/vcodec_mask >/dev/null

cd "$MW" || exit 1
sudo -n env LD_LIBRARY_PATH="$MW/lib" BLVO_PUMP=1 BLVO_BIND=0 \
	./blvo5 scroller720.264 > /tmp/h264live.log 2>&1 &
sleep 12

# Re-apply the bridge DDS once video flows, as mainline does.
sudo -n sh /tmp/lt-dds.sh 2>/dev/null || true
sleep 3

set +x
{
	echo "=== decoder ==="
	timeout 5 sudo -n cat /proc/cvitek/vdec 2>/dev/null | grep -m1 DecodedFrame
	echo "=== pump ==="
	grep -E 'pump: got' /tmp/h264live.log | tail -1
	echo "=== display ==="
	echo -n "DISP_CFG  "; sudo -n $P 0x0A088000
	echo -n "DISP_SIZE "; sudo -n $P 0x0A088058
	echo -n "bridge DT "; sudo -n i2cget -y 2 0x49 0x04 2>/dev/null || echo "?"
	grep CVI_VIP_SCL /proc/interrupts | head -1
} > /tmp/h264live.result 2>&1
