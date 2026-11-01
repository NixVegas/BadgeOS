# Microcode for the SG2000's CODA980 video codec. It runs on the VPU's own MCU, so
# the riscv64 rootfs copy serves both cores.
{
  lib,
  stdenvNoCC,
  fetchurl,
}:
let
  base =
    "https://raw.githubusercontent.com/milkv-duo/duo-buildroot-sdk/develop/"
    + "ramdisk/rootfs/common_glibc_riscv64/usr/share/fw_vcodec";
  coda980 = fetchurl {
    url = "${base}/coda980.bin";
    hash = "sha256-JAcGgKTObJVBv43PS8clNNWW4Ek3Q7umIGbMNxvnzi0=";
  };
  monet = fetchurl {
    url = "${base}/monet.bin";
    hash = "sha256-kLX495JTaSVa9jScO7icscKCGbh5GGJXRgaT3GarNFc=";
  };
in
stdenvNoCC.mkDerivation {
  pname = "soph-vpu-firmware";
  version = "cv181x";

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    dst="$out/lib/firmware/fw_vcodec"
    mkdir -p "$dst"
    # monet is the JPEG core: unused, but config.h names it.
    cp -f ${coda980} "$dst/coda980.bin"
    cp -f ${monet}   "$dst/monet.bin"
    runHook postInstall
  '';

  # cvi_vc_drv filp_open()s the blobs, which does not decompress.
  passthru.compressFirmware = false;

  meta = {
    description = "Chips&Media CODA980 VPU microcode for the Sophgo SG2000";
    license = lib.licenses.unfreeRedistributableFirmware;
  };
}
