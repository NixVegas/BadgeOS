#!/usr/bin/env bash
# A/B test of the VDEC->VO pump: BLVO_PUMP=0 should stall DecodedFrame, 1 should not.
exec > /tmp/h264pump.out 2>&1
set -x

MW=/home/badge/hdmi/mw
KO=/home/badge/hdmi/ko
STREAM=scroller720.264
BIN=./blvo5

sudo -n pkill -x vofeed; sudo -n pkill -x blvo3; sudo -n pkill -x blvo4
sudo -n pkill -x blvo5
sleep 2

sudo -n /run/current-system/sw/bin/soph-display-load >/dev/null 2>&1
sudo -n modprobe cvi_vc_driver
sleep 1
P=$KO/pk
v=$(sudo -n $P 0x0A088000 | awk '{print $3}'); sudo -n $P 0x0A088000 $(( v | 0x40000 )) >/dev/null
sudo -n $KO/dsiup --lanes 2 --vpol 0 --hpol 0
sleep 1
sudo -n env LANES_REG=0x02 sh /tmp/lt-land1281.sh
c=$(sudo -n $P 0x0A088000 | awk '{print $3}'); sudo -n $P 0x0A088000 $(( c & ~0x60 )) >/dev/null
d=$(sudo -n $P 0x0A088000 | awk '{print $3}'); sudo -n $P 0x0A088000 $(( d | 0x10000 )) >/dev/null
sudo -n $P 0x03002860 0x40 >/dev/null; sudo -n $P 0x03002860 0x41 >/dev/null

# A verbose vcodec_mask slows the decoder ~20x.
echo 1 | sudo -n tee /sys/module/cvi_vc_driver/parameters/vcodec_mask >/dev/null

cd "$MW" || exit 1

# /proc/cvitek/vdec blocks while the decoder holds its lock.
vdecline() { timeout 5 sudo -n cat /proc/cvitek/vdec 2>/dev/null | grep -m1 DecodedFrame; }
dec() { vdecline | sed -n 's/.*DecodedFrame: \([0-9]*\).*/\1/p'; }

run_case() {            # $1 = tag, $2 = BLVO_PUMP, $3 = BLVO_BIND
	tag=$1; pump=$2; bind=$3
	sudo -n pkill -x blvo5; sleep 3
	sudo -n dmesg -C
	sudo -n env LD_LIBRARY_PATH="$MW/lib" BLVO_PUMP="$pump" BLVO_BIND="$bind" \
		$BIN "$STREAM" > "/tmp/h264pump.$tag.log" 2>&1 &
	sleep 6
	d6=$(dec);  sleep 5
	d11=$(dec); sleep 10
	d21=$(dec)
	line=$(vdecline)
	echo "RESULT $tag pump=$pump bind=$bind DecodedFrame t6=$d6 t11=$d11 t21=$d21"
	{
		echo "RESULT $tag pump=$pump bind=$bind DecodedFrame t6=$d6 t11=$d11 t21=$d21"
		echo "  proc: $line"
		grep -E 'pump:|pump exit|fed [0-9]+ frames' "/tmp/h264pump.$tag.log" | tail -4 | sed 's/^/  /'
	} >> /tmp/h264pump.result
	sudo -n pkill -x blvo5; sleep 3
}

: > /tmp/h264pump.result
{
	echo "libsys in use: $(md5sum "$MW/lib/libsys.so" 2>/dev/null)"
	echo "libsys.so.orig present: $(test -f "$MW/lib/libsys.so.orig" && echo yes || echo no)"
	echo "(BLVO_BIND=0 in both cases, so the CV180X bind patch is inert either way)"
} >> /tmp/h264pump.result
echo "=== A: no pump (expect a stall) ===" >> /tmp/h264pump.result
run_case nopump 0 0
echo "=== B: pump (expect DecodedFrame climbing) ===" >> /tmp/h264pump.result
run_case pump 1 0

set +x
{
	echo
	echo "=== verdict ==="
	grep "^RESULT" /tmp/h264pump.result
	echo
	echo "=== display still healthy? ==="
	echo -n "DISP_CFG "; sudo -n $KO/pk 0x0A088000
	echo -n "bridge DT "; sudo -n i2cget -y 2 0x49 0x04 2>/dev/null || echo "(i2cget unavailable)"
	grep CVI_VIP_SCL /proc/interrupts | head -1
} > /tmp/h264pump.verdict 2>&1

cd "$MW" && sudo -n env LD_LIBRARY_PATH="$MW/lib" BLVO_PUMP=1 BLVO_BIND=0 \
	$BIN "$STREAM" > /tmp/h264pump.live.log 2>&1 &
sleep 5
