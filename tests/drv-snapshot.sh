#!/usr/bin/env bash
# drv-snapshot.sh <flake-ref> <out-file>: "<kind>.<attr> <value>" lines, sorted, for every
# output a badge or board depends on. QUICK=1: the x86_64-cross systems and the badge cards
# and bundle only. One capped evaluator per line group: run it alone.
set -uo pipefail
ref=$1
out=$2

ev() { systemd-run --user --scope -q --expand-environment=no -p MemoryMax=10G -- nix eval --max-jobs 0 "$@" 2>/dev/null || echo EVAL-ERROR; }
names() { ev --json "$1" --apply builtins.attrNames | tr -d '[]"' | tr ',' ' '; }
quick() { [ -n "${QUICK:-}" ]; }

facts='c: "toplevel ${c.config.system.build.toplevel.drvPath}\nkernel ${c.config.boot.kernelPackages.kernel.drvPath}\ndtb ${c.config.hardware.deviceTree.package.drvPath}\nwarnings ${builtins.toJSON c.config.warnings}\n"'

{
  for c in $(names "$ref#nixosConfigurations"); do
    if quick && [[ $c != *-x86_64 ]]; then continue; fi
    r=$(ev --raw "$ref#nixosConfigurations.$c" --apply "$facts")
    if [ "$r" = EVAL-ERROR ]; then echo "toplevel.$c EVAL-ERROR"; else printf '%s\n' "$r" | sed "s/^\([a-z]*\) /\1.$c /"; fi
  done
  for sys in x86_64-linux aarch64-linux; do
    if quick && [ "$sys" != x86_64-linux ]; then continue; fi
    for a in $(names "$ref#packages.$sys"); do
      if quick && ! [[ $a =~ ^((duo-s|sg2k|badge1)-sdcard|badge1-bundle)$ ]]; then continue; fi
      echo "packages.$sys.$a $(ev --raw "$ref#packages.$sys.$a.drvPath")"
    done
    if quick; then continue; fi
    for a in $(names "$ref#checks.$sys"); do
      echo "checks.$sys.$a $(ev --raw "$ref#checks.$sys.$a.drvPath")"
    done
  done
  if ! quick; then
    # Every derivation under hydraJobs, however deep the groups go.
    jobs=$(ev --raw "$ref#hydraJobs" --apply 'let
      go = p: v:
        if (v.type or "") == "derivation" then [ p ]
        else if builtins.isAttrs v then builtins.concatLists (map (n: go (p + "." + n) v.${n}) (builtins.attrNames v))
        else [ ];
    in s: builtins.concatStringsSep "\n" (map (p: builtins.substring 1 (-1) p) (go "" s))')
    for a in $jobs; do
      echo "hydra.$a $(ev --raw "$ref#hydraJobs.$a.drvPath")"
    done
    for n in $(names "$ref#deploy.nodes"); do
      echo "deploy.$n $(ev --raw "$ref#deploy.nodes.$n.profiles.system.path.drvPath")"
    done
  fi
} | sort > "$out"
grep -c . "$out"
