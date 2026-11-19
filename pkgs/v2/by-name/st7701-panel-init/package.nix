# Brings up the ST7701 DSI panel through the vendor mipi_tx driver.
{
  lib,
  stdenv,
  libgpiod,
  writeShellApplication,
  coreutils,
  drmDevice ? "/dev/dri/badge-panel",
}:
stdenv.mkDerivation {
  pname = "st7701-panel-init";
  version = "1.0";

  src = ./st7701-panel-init.c;

  dontUnpack = true;

  buildInputs = [ libgpiod ];

  buildPhase = ''
    runHook preBuild
    $CC -O2 -Wall -Wextra $src -o st7701-panel-init -lgpiod
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 st7701-panel-init $out/bin/st7701-panel-init
    runHook postInstall
  '';

  passthru.displayLink = writeShellApplication {
    name = "nix-badge-panel-display-link";
    runtimeInputs = [ coreutils ];
    runtimeEnv.DRM_DEVICE = drmDevice;
    text = builtins.readFile ./panel-display-link.sh;
  };

  meta = {
    description = "Bring-up of the ST7701 DSI panel through the vendor mipi_tx driver";
    mainProgram = "st7701-panel-init";
    platforms = lib.platforms.linux;
  };
}
