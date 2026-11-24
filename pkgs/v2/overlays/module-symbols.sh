# module-symbols.sh TREE STRIP: discard debug and compiler-local symbols from the modules
# of the aggregated tree TREE with STRIP. The tree's links into the module packages become
# files.
set -eu
out=$1 strip=$2
scratch=$(mktemp -d)
mkdir "$scratch/modules"
# Dereference runtime links, without copying kernel development trees.
for version in "$out/lib/modules"/*; do
  target="$scratch/modules/${version##*/}"
  mkdir "$target"
  for entry in "$version"/*; do
    case "${entry##*/}" in build|source) continue ;; esac
    cp -rL "$entry" "$target/"
  done
done
chmod -R u+w "$scratch/modules"
while IFS= read -r -d "" module; do
  case "$module" in
    *.ko.xz) xz -dc "$module" > "$scratch/module.ko" ;;
    *.ko) cp "$module" "$scratch/module.ko" ;;
    *) echo "module-symbols.sh: no rule for the compression of $module" >&2; exit 1 ;;
  esac
  # A signature covers the original ELF bytes, including its symbol table.
  if tail -c 28 "$scratch/module.ko" | grep -q '~Module signature appended~'; then
    continue
  fi
  "$strip" --strip-debug --discard-locals "$scratch/module.ko"
  case "$module" in
    # The kernel's own flags, scripts/Makefile.modinst.
    *.ko.xz) xz --check=crc32 --lzma2=dict=1MiB -c "$scratch/module.ko" > "$module" ;;
    *.ko) cp "$scratch/module.ko" "$module" ;;
  esac
done < <(find "$scratch/modules" -type f \( -name '*.ko' -o -name '*.ko.xz' -o -name '*.ko.gz' -o -name '*.ko.zst' \) -print0)
rm -rf "$out/lib/modules"
mv "$scratch/modules" "$out/lib/modules"
rm -r "$scratch"
