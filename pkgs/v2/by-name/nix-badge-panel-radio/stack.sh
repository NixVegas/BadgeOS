# Bluetooth must not restore NetworkManager's remembered WiFi On state.
# The WiFi consumer enables it after the shared hardware is ready.
nmcli radio wifi off
for module in sdhci-cv181x aic8800_bsp aic8800_fdrv; do
    modprobe "$module"
done
