# firmware.sh SRC DST: copy the firmware for WiFi chips and GPUs from SRC to DST, keeping
# paths. NVIDIA's is left out: about 100 MiB compressed, more than the badge can spare.
set -eu
src=$1 dst=$2
mkdir -p "$dst"
cd "$src"
for d in intel/iwlwifi mediatek ath10k ath11k ath12k rtw88 rtw89 rtlwifi brcm cypress \
  i915 xe amdgpu radeon; do
  if [ -e "$d" ]; then
    mkdir -p "$dst/$(dirname "$d")"
    cp -a "$d" "$dst/$d"
  fi
done
for f in iwlwifi-*; do
  [ -e "$f" ] && cp -a "$f" "$dst/"
done
exit 0
