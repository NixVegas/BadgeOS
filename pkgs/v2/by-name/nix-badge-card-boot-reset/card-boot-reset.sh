# nix-badge-card-boot-reset: stage 0 reset the data card's Nix layer for the slots listed
# in /.userdata/.nixbadge-card-boot-reset; their boot images on the card's BOOT
# (/boot-card) would boot generations that are gone, so they go too, then the list.
# CARD_BOOT_RESET_MARKER and CARD_BOOT_RESET_BOOT stand in for the two paths in tests.
marker=${CARD_BOOT_RESET_MARKER:-/.userdata/.nixbadge-card-boot-reset}
boot=${CARD_BOOT_RESET_BOOT:-/boot-card}
[ -f "$marker" ] || exit 0
while read -r s; do
  case $s in
    A | B) ;;
    *) continue ;;
  esac
  for d in "$boot"/*/slot-"$s"; do
    [ -d "$d" ] || continue
    rm -f "$d/boot.itb" "$d/boot.itb.new" "$d/boot.itb.prev" "$d/boot.itb.prev.new"
    echo "dropped the boot image in $d: the data card's Nix layer for slot $s was reset"
  done
done < <(sort -u "$marker")
sync
rm -f "$marker"
