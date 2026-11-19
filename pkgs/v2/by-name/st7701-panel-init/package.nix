# Brings up the ST7701 DSI panel through the vendor mipi_tx driver.
{
  lib,
  stdenv,
  libgpiod,
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

  meta = {
    description = "Bring-up of the ST7701 DSI panel through the vendor mipi_tx driver";
    mainProgram = "st7701-panel-init";
    platforms = lib.platforms.linux;
  };
}
