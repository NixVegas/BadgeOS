#!/bin/sh
# Re-apply the LT8912B DDS block once video flows, as mainline does.
B=2; M=0x48; D=0x49
fail=0
w(){ i2cset -y $B $1 $2 $3 >/dev/null 2>&1 || fail=$((fail+1)); }
for kv in 4e:ff 4f:56 50:69 51:80 1e:4f 51:00; do w $D 0x${kv%:*} 0x${kv#*:}; done
w $M 0x03 0x7f; sleep 0.02; w $M 0x03 0xff
[ "$fail" -eq 0 ] || echo "lt-dds: $fail i2c write(s) failed -- bridge may not be ACKing"
[ "$fail" -eq 0 ]
