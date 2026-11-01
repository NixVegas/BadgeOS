# nix-badge-storage-mode: records what stage 0 mounted, in /run/nix-badge: store.conf, the
# Nix daemon's store line (its NIX_CONFIG includes it), and storage: emmc, sd, or
# "card <device>" when a data card is in use (stage 0 then mounted /.lower-userdata).
# STORAGE_MODE_CMDLINE, STORAGE_MODE_MOUNTINFO and STORAGE_MODE_RUN stand in for
# /proc/cmdline, /proc/self/mountinfo and /run/nix-badge in tests.
cmdline=${STORAGE_MODE_CMDLINE:-/proc/cmdline}
mountinfo=${STORAGE_MODE_MOUNTINFO:-/proc/self/mountinfo}
run=${STORAGE_MODE_RUN:-/run/nix-badge}

slot=A; medium=""
for o in $(< "$cmdline"); do
  case $o in
    rauc.slot=B) slot=B ;;
    nixbadge.bootmedium=*) medium=${o#nixbadge.bootmedium=} ;;
  esac
done
# the source of the mount at $1, if anything is mounted there
source_of() { awk -v m="$1" '$5 == m { sub(/.* - /, ""); print $2; exit }' "$mountinfo"; }

if [ -n "$(source_of /.lower-userdata)" ]; then
  store=$(store_url_tier2 "$slot")
  mode="card $(source_of /.userdata)"
else
  store="local-overlay://?lower-store=$(nb_urlenc "local?root=/nix/.ro-store&read-only=true")&upper-layer=/.userdata/nix/upper"
  if [ "$medium" = 1 ]; then mode=sd; else mode=emmc; fi
fi
mkdir -p "$run"
printf 'store = %s\n' "$store" > "$run/store.conf.new" && mv -f "$run/store.conf.new" "$run/store.conf"
printf '%s\n' "$mode" > "$run/storage.new" && mv -f "$run/storage.new" "$run/storage"
