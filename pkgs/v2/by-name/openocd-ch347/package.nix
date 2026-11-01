# OpenOCD with the CH347 JTAG driver (newer than nixpkgs' 0.12.0), for the badge's DEBUG
# port (J1), with the badge's configs on its search path:
#   openocd -f badge/c906.cfg       the RISC-V core
#   openocd -f badge/a53.cfg        the ARM core, over SWD
#   openocd -f badge/wdt-reset.cfg  reset a hung SoC
{ pkgs }:
pkgs.openocd.overrideAttrs (o: {
  version = "unstable-2741efc6";
  src = pkgs.fetchFromGitHub {
    owner = "openocd-org";
    repo = "openocd";
    rev = "2741efc60ae03e2a5fea707685df59a3c4256437";
    hash = "sha256-B2VKz9RBxM2/2nGvlxCqEuo+9oEDdDfjG1zXrQFPs4c=";
    fetchSubmodules = true;
  };
  nativeBuildInputs = (o.nativeBuildInputs or [ ]) ++ [
    pkgs.autoreconfHook
    pkgs.which
    pkgs.git
    pkgs.texinfo
  ];
  configureFlags = (o.configureFlags or [ ]) ++ [
    "--enable-ch347"
    "--disable-doxygen-html"
  ];
  postInstall = (o.postInstall or "") + ''
    install -Dm644 -t $out/share/openocd/scripts/badge ${./scripts}/*.cfg
  '';
})
