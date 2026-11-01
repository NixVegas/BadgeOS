#!/usr/bin/env bash
# Display bring-up with the vendor middleware (cvi_mpi) as the producer.
set -u
P=/home/badge/hdmi/ko/pk
MW=/home/badge/hdmi/mw
S=sudo

echo "== modules =="
$S /run/current-system/sw/bin/soph-display-load 2>&1 | tail -3 || {
  echo "soph-display-load not on PATH; falling back to manual insmod"; }
lsmod | grep -cE '^(soph_ion_compat|cv181x_sys|cv181x_base|cv181x_vpss|cv181x_rgn|cv181x_vo|cv181x_mipi_tx|soph_dispsrc) ' | xargs echo "modules loaded:"

echo "== SHRD_SEL (bit18) =="
v=$($S $P 0x0A088000 | awk '{print $3}'); $S $P 0x0A088000 $(( v | 0x40000 )) >/dev/null

echo "== DSI up: 2 lanes, positive sync =="
$S /home/badge/hdmi/ko/dsiup --lanes 2 --vpol 0 --hpol 0
sleep 1

echo "== bridge 720p60, hactive 1281, 2-lane =="
$S env LANES_REG=0x02 sh /tmp/lt-land1281.sh

echo "== DISP sync polarity: clear VS_POL|HS_POL, force update =="
c=$($S $P 0x0A088000 | awk '{print $3}'); $S $P 0x0A088000 $(( c & ~0x60 )) >/dev/null
d=$($S $P 0x0A088000 | awk '{print $3}'); $S $P 0x0A088000 $(( d | 0x10000 )) >/dev/null
echo -n "  DISP_CFG now: "; $S $P 0x0A088000

echo "== pin disppll SSC synthesizer divider =="
$S $P 0x03002860 0x40 >/dev/null; $S $P 0x03002860 0x41 >/dev/null

echo "== producer: vofeed (NV21 colour bars into VO) =="
cd $MW && $S env LD_LIBRARY_PATH=$MW/lib ./vofeed > /tmp/vofeed.log 2>&1 &
sleep 4
tail -20 /tmp/vofeed.log

echo "== DDS re-apply with video flowing =="
$S sh /tmp/lt-dds.sh
sleep 1

echo "== state =="
for r in 0x0A088000 0x0A08804c 0x0A088058 0x0A088034 0x0A08A000 0x03002860; do $S $P $r; done
echo -n "bridge DSI data type 0x49:0x04 = "; $S i2cget -y 2 0x49 0x04
echo -n "bridge HPD 0x48:0xc1 = "; $S i2cget -y 2 0x48 0xc1
