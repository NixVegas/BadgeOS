#!/bin/sh
set +e
io(){ echo "$1" | sudo tee /sys/kernel/debug/lt8912b_bringup/io >/dev/null; }
echo "== restore transmitting state (fb + burst15 + pattern + MAC HS) =="
echo 1 | sudo tee /sys/kernel/debug/lt8912b_bringup/bringup >/dev/null
io "m phy 0x14 0xffffff00 0x05200600"
io "m phy 0x74 0x000003ff 0x00000000"
io "m scl 0x8000 0x0000f001 0x00004000"      # fmt RGB_PACKED, disp_from_sc=0
io "w scl 0x8034 0x90000000"; io "w scl 0x8038 0x00000000"
io "w scl 0x8054 0x00000000"; io "w scl 0x8058 0x02cf04ff"
io "m scl 0x804c 0xffffffff 0xf0000f00"       # pitch 3840 + burst 15
io "w scl 0x8098 0x03ff03ff"; io "m scl 0x809c 0x000003ff 0x000003ff"
io "m scl 0x8094 0x1f000016 0x07000002"       # colorbar
io "m scl 0x8000 0x80 0x80"; io "m scl 0x8000 0x00010000 0x00010000"
io "w phy 0x44 0x1f1f1f1f"; io "w scl 0xa000 0"; io "w phy 0x44 0x00000000"; io "w scl 0xa000 4"
sleep 0.4
io "r phy 0x2c"; sudo dmesg | grep -iE "io r phy\+0x002c" | tail -1
echo "== sweep HS_0 dialect: bit29=continuous, bit26=EoTp =="
for hs0 in 0x22000000 0x02000000 0x06000000 0x26000000; do
  io "m scl 0xa004 0x3f000000 $hs0"   # write dialect bits (keep fmt 30/31=0)
  io "w scl 0xa000 0"; io "w scl 0xa000 4"        # re-trigger MAC HS
  sudo i2cset -y 2 0x48 0x03 0x7f; sleep 0.05; sudo i2cset -y 2 0x48 0x03 0xff
  sleep 0.5
  printf "  HS_0=%s -> 9c=%s 9d=%s 9e=%s 9f=%s | DDS0e=%s\n" $hs0 \
    "$(sudo i2cget -y 2 0x48 0x9c)" "$(sudo i2cget -y 2 0x48 0x9d)" \
    "$(sudo i2cget -y 2 0x48 0x9e)" "$(sudo i2cget -y 2 0x48 0x9f)" \
    "$(sudo i2cget -y 2 0x49 0x0e)"
done
