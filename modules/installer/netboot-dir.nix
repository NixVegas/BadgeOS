# What the badge serves of the installer: the kernel, the initrd, an iPXE script for
# them and the x86_64 iPXE binaries. netboot.ipxe names the system's init without
# depending on it, so the badge carries only the initrd, which holds the store.
{ config, pkgs, ... }:
let
  build = config.system.build;
  toplevel = builtins.unsafeDiscardStringContext "${build.toplevel}";
  netbootIpxe = pkgs.writeText "netboot.ipxe" ''
    #!ipxe
    kernel bzImage init=${toplevel}/init initrd=initrd ${toString config.boot.kernelParams} ''${cmdline}
    initrd initrd
    boot
  '';
in
{
  system.build.badgeNetboot = pkgs.runCommand "nix-badge-netboot" { } ''
    mkdir $out
    ln -s ${build.kernel}/${pkgs.stdenv.hostPlatform.linux-kernel.target} $out/bzImage
    ln -s ${build.netbootRamdisk}/initrd $out/initrd
    cp ${netbootIpxe} $out/netboot.ipxe
    cp ${pkgs.ipxe}/ipxe.efi ${pkgs.ipxe}/undionly.kpxe $out/
  '';
}
