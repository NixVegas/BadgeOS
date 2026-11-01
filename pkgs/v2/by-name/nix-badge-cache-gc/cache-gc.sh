# nix-badge-cache-gc [MIN_FREE_MIB [TARGET_FREE_MIB]]: when the store's filesystem has less
# than MIN_FREE_MIB free (4096), collect garbage until it has TARGET_FREE_MIB (8192).
min=${1:-4096}
target=${2:-8192}
mib=$((1024 * 1024))

avail=${CACHE_GC_AVAIL:-$(df --output=avail -B1 /.userdata | tail -n 1)}
avail=${avail// /}
if [ "$avail" -ge $((min * mib)) ]; then
  exit 0
fi

free=$((target * mib - avail))
echo "$((avail / mib)) MiB free, under $min MiB: collecting up to $((free / mib)) MiB"
"${CACHE_GC_NIX_STORE:-nix-store}" --gc --max-freed "$free"
