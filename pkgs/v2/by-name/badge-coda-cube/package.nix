# coda-cube on the desktop, in a badge-coda-cube@USER system service: it opens the
# codec as root and drops to USER before sway. polkit lets USER start and stop it.
{
  lib,
  stdenvNoCC,
  bash,
  coreutils,
  kmod,
  shellcheck-minimal,
  systemd,
  coda-cube,
}:
let
  libexec = "${placeholder "out"}/libexec/badge-coda-cube";
in
stdenvNoCC.mkDerivation {
  pname = "badge-coda-cube";
  version = "1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./badge-coda-cube.sh
      ./badge-coda-cube.rules
      (./. + "/badge-coda-cube@.service")
      ./cleanup.sh
      ./codec-up.sh
      ./session.sh
    ];
  };

  strictDeps = true;

  nativeBuildInputs = [ shellcheck-minimal ];
  # for patchShebangs
  buildInputs = [ bash ];

  dontBuild = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 codec-up.sh ${libexec}/codec-up
    install -Dm755 session.sh ${libexec}/session
    install -Dm755 cleanup.sh ${libexec}/cleanup
    install -Dm755 badge-coda-cube.sh $out/bin/badge-coda-cube
    substituteInPlace ${libexec}/codec-up \
      --replace-fail @path@ ${
        lib.makeBinPath [
          coreutils
          kmod
        ]
      }
    substituteInPlace ${libexec}/session ${libexec}/cleanup \
      --replace-fail @path@ ${
        lib.makeBinPath [
          coreutils
          coda-cube
        ]
      }
    substituteInPlace $out/bin/badge-coda-cube \
      --replace-fail @path@ ${
        lib.makeBinPath [
          coreutils
          systemd
        ]
      }
    install -Dm644 badge-coda-cube@.service $out/lib/systemd/system/badge-coda-cube@.service
    substituteInPlace $out/lib/systemd/system/badge-coda-cube@.service \
      --replace-fail @libexec@ ${libexec}
    install -Dm644 badge-coda-cube.rules $out/share/polkit-1/rules.d/50-badge-coda-cube.rules
    # the scripts as installed, with their PATHs in
    shellcheck $out/bin/badge-coda-cube ${libexec}/{codec-up,session,cleanup}
    runHook postInstall
  '';

  meta = {
    description = "Runs coda-cube zero-copy on the user's sway session, with the codec loaded and reset";
    mainProgram = "badge-coda-cube";
    inherit (coda-cube.meta) platforms;
  };
}
