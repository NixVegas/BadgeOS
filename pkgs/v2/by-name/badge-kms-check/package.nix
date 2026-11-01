# Atomic KMS checks of soph_drm's primary plane (they need DRM master, so stop the
# compositor), and a check that soph_ion refuses to export non-ION memory.
{
  lib,
  stdenv,
  libdrm,
  pkg-config,
  soph-ion-uapi,
}:
stdenv.mkDerivation {
  pname = "badge-kms-check";
  version = "1.0";

  src = ./badge-kms-check.c;

  dontUnpack = true;

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [
    libdrm
    soph-ion-uapi
  ];

  buildPhase = ''
    runHook preBuild
    $CC -O2 -Wall -Wextra $src -o badge-kms-check \
      $($PKG_CONFIG --cflags --libs libdrm) -lm
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 badge-kms-check $out/bin/badge-kms-check
    runHook postInstall
  '';

  meta = {
    description = "Atomic KMS format, colour and flip checks for soph_drm, and soph_ion export checks";
    mainProgram = "badge-kms-check";
    platforms = lib.platforms.linux;
  };
}
