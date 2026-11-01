# nix-badge-cache-gc with the free space and nix-store stood in.
{
  runCommand,
  runtimeShell,
  nix-badge-cache-gc,
}:
runCommand "nix-badge-cache-gc-test" { } ''
  bin=${nix-badge-cache-gc}/bin/nix-badge-cache-gc
  fail() { echo "FAIL: $*"; cat calls 2>/dev/null; exit 1; }
  printf '#!${runtimeShell}\necho "$*" >> %s/calls\n' "$PWD" > nix-store
  chmod +x nix-store
  run() { rm -f calls; CACHE_GC_AVAIL=$1 CACHE_GC_NIX_STORE=$PWD/nix-store $bin "''${@:2}" > out; }
  gib=$((1024 * 1024 * 1024))
  # 5 GiB free: over the 4 GiB floor, nothing collected
  run $((5 * gib)); [ ! -e calls ] || fail "collected with 5 GiB free"
  # 3 GiB free: collect up to 8 GiB free
  run $((3 * gib)); [ "$(cat calls)" = "--gc --max-freed 5368709120" ] || fail "3 GiB free"
  grep -q . out || fail "said nothing"
  # the floor and the target are MiB arguments
  run $((3 * gib)) 2048; [ ! -e calls ] || fail "collected over a 2048 MiB floor"
  run $((1 * gib)) 2048 3072; [ "$(cat calls)" = "--gc --max-freed $((2 * gib))" ] || fail "custom floor and target"
  touch $out
''
