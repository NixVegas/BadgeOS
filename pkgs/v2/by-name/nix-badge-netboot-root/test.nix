# The served tree over fake inputs: real files for TFTP, the banner kept byte for byte,
# the menu without the CTF flag, and /boot pointing at the netboot directory.
{
  runCommand,
  writeText,
  nix-badge-netboot-root,
}:
let
  netboot = runCommand "fake-netboot" { } ''
    mkdir $out
    printf bz > $out/bzImage
    printf rd > $out/initrd
    printf nb > $out/netboot.ipxe
    printf efi > $out/ipxe.efi
    printf kpxe > $out/undionly.kpxe
  '';
  root = nix-badge-netboot-root {
    inherit netboot;
    banner = writeText "banner" "  NIX\n\nVEGAS\n";
    badapple = writeText "badapple.ipxe" "#!ipxe\necho apple\n";
  };
in
runCommand "nix-badge-netboot-root-test" { } ''
  fail() { echo "FAIL: $*"; exit 1; }
  r=${root}
  [ "$(ls $r/tftp | tr '\n' ' ')" = "autoexec.ipxe ipxe.efi undionly.kpxe " ] || fail "tftp entries"
  for f in ipxe.efi undionly.kpxe autoexec.ipxe; do [ -f $r/tftp/$f ] && [ ! -L $r/tftp/$f ] || fail "tftp/$f not a regular file"; done
  [ "$(cat $r/tftp/ipxe.efi)" = efi ] && [ "$(cat $r/tftp/undionly.kpxe)" = kpxe ] || fail "tftp binaries"
  for s in $r/tftp/autoexec.ipxe $r/boot/menu.ipxe; do
    [ "$(head -n1 $s)" = '#!ipxe' ] || fail "$s header"
    grep -qx 'set L:hex 1b:5b:32:4a:1b:5b:48' $s || fail "$s clear"
    grep -qx 'set L:hex 20:20:4e:49:58' $s || fail "$s keeps leading spaces"
    grep -qx 'echo' $s || fail "$s blank line"
    grep -qx 'set L:hex 56:45:47:41:53' $s || fail "$s second line"
  done
  [ "$(tail -n1 $r/tftp/autoexec.ipxe)" = autoboot ] || fail "autoexec ends in autoboot"
  grep -qx 'prompt --timeout 5000 Press any key to play Bad Apple, or wait to boot NixOS... || goto boot' $r/boot/menu.ipxe || fail "prompt"
  grep -qx 'chain badapple.ipxe || goto boot' $r/boot/menu.ipxe || fail "badapple chain"
  grep -qx 'chain netboot.ipxe' $r/boot/menu.ipxe || fail "netboot chain"
  ! grep -qi flag $r/boot/menu.ipxe || fail "CTF flag left in the menu"
  [ "$(cat $r/boot/netboot.ipxe)$(cat $r/boot/bzImage)$(cat $r/boot/initrd)" = nbbzrd ] || fail "netboot files"
  [ "$(cat $r/boot/badapple.ipxe)" = "$(printf '#!ipxe\necho apple')" ] || fail "badapple"
  [ -f $r/boot/ipxe.efi ] && [ ! -L $r/boot/ipxe.efi ] && [ "$(cat $r/boot/ipxe.efi)" = efi ] || fail "HTTP ipxe.efi"
  touch $out
''
