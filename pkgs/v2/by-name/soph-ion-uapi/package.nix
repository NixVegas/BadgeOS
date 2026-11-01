# The uapi header of /dev/soph-ion, the dma-buf exporter in soph-display's ION shim.
{
  lib,
  stdenvNoCC,
}:
stdenvNoCC.mkDerivation {
  pname = "soph-ion-uapi";
  version = "1.0";

  src = ./soph_ion.h;

  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    install -Dm444 $src $out/include/soph_ion.h
    runHook postInstall
  '';

  meta = {
    description = "Userspace API header of the soph_ion dma-buf exporter (/dev/soph-ion)";
    license = lib.licenses.gpl2Only;
    platforms = lib.platforms.linux;
  };
}
