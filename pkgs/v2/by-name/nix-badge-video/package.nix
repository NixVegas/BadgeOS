# A folder of H.264 clips on HDMI over the VDEC -> VO path, advanced with the USER button.
{
  lib,
  stdenv,
  soph-mpi,
  makeWrapper,
  bash,
  coreutils,
  findutils,
  gawk,
  i2c-tools,
  kmod,
  # Where the driver looks for clips when invoked with no argument.
  videoDir ? "/var/lib/nix-badge-video",
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "nix-badge-video";
  version = "0-unstable-2026-09-20";

  dontUnpack = true;

  strictDeps = true;
  nativeBuildInputs = [ makeWrapper ];
  buildInputs = [ soph-mpi ];

  playerSrc = ../soph-display/scripts/badge_landscape_vo.c;
  dsiupSrc = ../soph-display/scripts/dsiup.c;
  btnwaitSrc = ./btnwait.c;
  driverSrc = ./nix-badge-video.sh;
  ltLandSrc = ../soph-display/scripts/lt-land1281.sh;
  ltDdsSrc = ../soph-display/scripts/lt-dds.sh;

  buildPhase = ''
    runHook preBuild

    # Without -D__CV181X__ cvi_mpi's headers describe a CV180X, which has no VO.
    $CC -O2 -Wall -Wextra -D__CV181X__ \
      -I${soph-mpi}/include \
      ${finalAttrs.playerSrc} -o blvo \
      -L${soph-mpi}/lib -Wl,-rpath,${soph-mpi}/lib \
      -l:libvo.so -l:libvdec.so -l:libsys.so -lpthread -lm

    $CC -O2 -Wall -Wextra ${finalAttrs.dsiupSrc} -o dsiup
    $CC -O2 -Wall -Wextra ${finalAttrs.btnwaitSrc} -o btnwait

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/share/nix-badge-video
    install -m755 blvo    $out/bin/nix-badge-video-blvo
    install -m755 dsiup   $out/bin/nix-badge-video-dsiup
    install -m755 btnwait $out/bin/nix-badge-video-btnwait
    install -m755 ${finalAttrs.ltLandSrc} $out/share/nix-badge-video/lt-land1281.sh
    install -m755 ${finalAttrs.ltDdsSrc}  $out/share/nix-badge-video/lt-dds.sh

    substitute ${finalAttrs.driverSrc} $out/bin/nix-badge-video \
      --subst-var-by out $out \
      --subst-var-by videodir ${videoDir}
    # systemd's PATH has no bash, and the shebang resolves before wrapProgram's PATH.
    sed -i "1s|.*|#!${bash}/bin/bash|" $out/bin/nix-badge-video
    chmod +x $out/bin/nix-badge-video

    # PATH is a prefix so the system's soph-display-load stays reachable.
    wrapProgram $out/bin/nix-badge-video \
      --prefix PATH : ${
        lib.makeBinPath [
          bash
          coreutils
          findutils
          gawk
          i2c-tools
          kmod
        ]
      }

    runHook postInstall
  '';

  meta = {
    description = "H.264 clip player for the badge's HDMI, advanced with the USER button";
    platforms = lib.platforms.linux;
    mainProgram = "nix-badge-video";
  };
})
