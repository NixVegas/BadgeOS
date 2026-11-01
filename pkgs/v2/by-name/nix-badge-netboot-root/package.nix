# The trees the badge serves for netboot: tftp/ for a PXE ROM (the iPXE binaries and the
# script iPXE's EFI build looks for first) and boot/ over HTTP (the menu, Bad Apple and
# the installer). dnsmasq's TFTP root holds copies, not links out of it.
{
  lib,
  runCommand,
  callPackage,
}:
let
  makeNetbootRoot =
    {
      # bzImage, initrd, netboot.ipxe, ipxe.efi and undionly.kpxe
      netboot,
      # The text shown before the menu.
      banner,
      # badapple.ipxe
      badapple,
    }:
    runCommand "nix-badge-netboot-root" { } ''
      mkdir -p $out/tftp $out/boot
      bash ${./banner2ipxe.sh} ${banner} > banner.ipxe
      { printf '#!ipxe\n\n'; cat banner.ipxe; printf '\nautoboot\n'; } > $out/tftp/autoexec.ipxe
      { printf '#!ipxe\n\n'; cat banner.ipxe; printf '\n'; cat ${./menu.ipxe}; } > $out/boot/menu.ipxe
      cp ${netboot}/ipxe.efi ${netboot}/undionly.kpxe $out/tftp/
      cp ${netboot}/ipxe.efi $out/boot/
      cp ${badapple} $out/boot/badapple.ipxe
      ln -s ${netboot}/netboot.ipxe ${netboot}/bzImage ${netboot}/initrd $out/boot/
    '';
in
lib.setFunctionArgs makeNetbootRoot (lib.functionArgs makeNetbootRoot)
// {
  passthru.tests.root = callPackage ./test.nix { };
}
