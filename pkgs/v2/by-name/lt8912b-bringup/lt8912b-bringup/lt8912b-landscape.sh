#!/bin/sh
# LT8912B init for 1280x720@60 landscape, RGB888, over i2c bus 2 (M=0x48 main,
# D=0x49 MIPI/DDS). hactive is 1281 (1c:01 1d:05): at 1280 the picture shears.
set -e
B=2; M=0x48; D=0x49
w(){ i2cset -y $B $1 $2 $3; }

lt_common(){
  for kv in 08:ff 09:ff 0a:ff 0b:7c 0c:ff 42:04 31:b1 32:b1 33:0e 37:00 38:22 \
            60:82 39:45 3a:00 3b:00 44:31 55:44 57:01 5a:02 3e:d6 3f:d4 41:3c b2:00; do
    w $M 0x${kv%:*} 0x${kv#*:}
  done
  LANECNT=${LANES_REG:-0x00}; w $D 0x13 $LANECNT
  for kv in 12:04 14:00 15:00 1a:03 1b:03; do w $D 0x${kv%:*} 0x${kv#*:}; done
}
lt_dds(){
  for kv in 4e:ff 4f:56 50:69 51:80 1f:5e 20:01 21:2c 22:01 23:fa 24:00 25:c8 26:00 \
            27:5e 28:01 29:2c 2a:01 2b:fa 2c:00 2d:c8 2e:00 42:64 43:00 44:04 45:00 \
            46:59 47:00 48:f2 49:06 4a:00 4b:72 4c:45 4d:00 52:08 53:00 54:b2 55:00 \
            56:e4 57:0d 58:00 59:e4 5a:8a 5b:00 5c:34 1e:4f 51:00; do
    w $D 0x${kv%:*} 0x${kv#*:}
  done
}
lt_latch(){ w $M 0xab 0x03; w $M 0xb2 0x01; lt_dds; w $M 0x05 0xfb; sleep 0.02; w $M 0x05 0xff; w $M 0x03 0x7f; sleep 0.02; w $M 0x03 0xff; }

# HDMI TX PLL and enable (mainline's misnamed lt8912_write_lvds_config).
lt_lvds(){
  w $M 0x44 0x30; w $M 0x51 0x05
  w $M 0x50 0x24; w $M 0x51 0x2d; w $M 0x52 0x04
  w $M 0x69 0x0e; w $M 0x69 0x8e; w $M 0x6a 0x00
  w $M 0x6c 0xb8; w $M 0x6b 0x51
  w $M 0x04 0xfb; w $M 0x04 0xff
  w $M 0x7f 0x00; w $M 0xa8 0x13
  w $M 0x02 0xf7; w $M 0x02 0xff; w $M 0x03 0xcf; w $M 0x03 0xff
}

echo "[lt8912b] common + landscape 1280x720@60"
lt_common
for kv in 10:01 11:08 18:28 19:05 1c:01 1d:05 2f:0c 34:72 35:06 36:ee 37:02 38:14 \
          39:00 3a:05 3b:00 3c:dc 3d:00 3e:6e 3f:00; do
  w $D 0x${kv%:*} 0x${kv#*:}
done
w $D 0x70 0x00		# test-pattern generator off
lt_latch
lt_lvds
sleep 0.3
echo -n "[lt8912b] HPD (M 0xc1): "; i2cget -y $B $M 0xc1
echo "[lt8912b] done"
