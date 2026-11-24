# The panel's touch menu: swaybar's status command, which starts and closes the
# registered apps and settings as systemd units.
{
  lib,
  stdenv,
  pkg-config,
  json_c,
  makeWrapper,
  sway,
  systemd,
}:
stdenv.mkDerivation {
  pname = "badge-touch-bar";
  version = "1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Makefile
      ./bar.h
      ./main.c
      ./apps.c
      ./state.c
      ./sway.c
      ./units.c
      ./bar.c
      ./process.c
      ./tests/state.c
    ];
  };

  nativeBuildInputs = [
    pkg-config
    makeWrapper
  ];
  buildInputs = [ json_c ];
  doCheck = stdenv.buildPlatform.canExecute stdenv.hostPlatform;
  checkTarget = "check";

  installPhase = ''
    runHook preInstall
    install -Dm755 badge-touch-bar $out/libexec/badge-touch-bar
    makeWrapper $out/libexec/badge-touch-bar $out/bin/badge-touch-bar \
      --prefix PATH : ${
        lib.makeBinPath [
          sway
          systemd
        ]
      }
    runHook postInstall
  '';

  meta = {
    description = "Touch menu and managed app controller for the panel desktop";
    mainProgram = "badge-touch-bar";
    platforms = lib.platforms.linux;
  };
}
