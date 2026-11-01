#!/bin/sh
# LT8912B 1280x720@60: hactive 1281 (1280 shears), 2 lanes (D2/D3 are dead);
# the caller re-applies DDS once video flows. Failed writes are counted, not fatal.
#
# TMDS drive 0x48 0x31/0x32/0x33 = a1/a1/03 is empirical, not mainline's b1/b1/0e:
# this board's HDMI sink is not impedance matched. Do not change it back.
B=2; M=0x48; D=0x49
fail=0
w(){ i2cset -y $B $1 $2 $3 >/dev/null 2>&1 || fail=$((fail+1)); }

# Advisory probe: writes to a dead bus still ACK, only a read (chip ID 0x12) tells.
if probe=$(i2cget -y $B $M 0x00 2>&1); then
	echo "lt-land: LT8912B at $M ACKs on bus $B (0x00=$probe)"
else
	echo "lt-land: LT8912B at $M did NOT ACK the probe read: $probe"
fi
for kv in 08:ff 09:ff 0a:ff 0b:7c 0c:ff 42:04 31:a1 32:a1 33:03 37:00 38:22 60:82 39:45 3a:00 3b:00 44:31 55:44 57:01 5a:02 3e:d6 3f:d4 41:3c b2:00; do w $M 0x${kv%:*} 0x${kv#*:}; done
w $D 0x13 ${LANES_REG:-0x02}
for kv in 12:04 14:00 15:00 1a:03 1b:03; do w $D 0x${kv%:*} 0x${kv#*:}; done
# 1c:01 1d:05: hactive 1281
for kv in 10:01 11:08 18:28 19:05 1c:01 1d:05 2f:0c 34:72 35:06 36:ee 37:02 38:14 39:00 3a:05 3b:00 3c:dc 3d:00 3e:6e 3f:00; do w $D 0x${kv%:*} 0x${kv#*:}; done
w $D 0x70 0x00
w $M 0xab 0x03; w $M 0xb2 0x01
for kv in 4e:ff 4f:56 50:69 51:80 1f:5e 20:01 21:2c 22:01 23:fa 24:00 25:c8 26:00 27:5e 28:01 29:2c 2a:01 2b:fa 2c:00 2d:c8 2e:00 42:64 43:00 44:04 45:00 46:59 47:00 48:f2 49:06 4a:00 4b:72 4c:45 4d:00 52:08 53:00 54:b2 55:00 56:e4 57:0d 58:00 59:e4 5a:8a 5b:00 5c:34 1e:4f 51:00; do w $D 0x${kv%:*} 0x${kv#*:}; done
w $M 0x03 0x7f; sleep 0.02; w $M 0x03 0xff
sleep 0.3

hpd=$(i2cget -y $B $M 0xc1 2>&1) || hpd="READ FAILED: $hpd"
echo "lt-land: write failures=$fail  HPD 0xc1=$hpd"
[ "$fail" -eq 0 ]
