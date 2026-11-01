# banner2ipxe.sh BANNER: iPXE commands that clear the screen and print BANNER as it is.
# iPXE's echo collapses whitespace, but a setting expands after tokenising, so each
# line goes through a hex-encoded setting. ESC[2J is the only erase iPXE's EFI
# console takes; ESC[H homes the cursor on serial consoles.
set -eu
printf 'set L:hex 1b:5b:32:4a:1b:5b:48\n'
printf 'echo -n ${L:string}\n'
while IFS= read -r line; do
  if [ -z "$line" ]; then
    printf 'echo\n'
  else
    hex=$(printf '%s' "$line" | od -An -v -tx1 | tr -s ' \n' ':' | sed 's/^:*//;s/:*$//')
    printf 'set L:hex %s\n' "$hex"
    printf 'echo ${L:string}\n'
  fi
done < "$1"
