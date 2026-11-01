# Harmonia with the Nix Vegas stream-through patch (substitute on miss, from the systems
# repo) and the badge's own changes to it (badge.patch). Its Rust tests run wherever the
# build can execute them.
{
  lib,
  stdenv,
  harmonia,
  applyPatches,
  rustPlatform,
  nix,
  curl,
}:
let
  src = applyPatches {
    name = "nix-badge-harmonia-src";
    inherit (harmonia) src;
    patches = [
      ./stream-through.patch
      ./badge.patch
    ];
  };
in
harmonia.overrideAttrs (prev: {
  pname = "nix-badge-harmonia";
  inherit src;
  # The patches add in-tree path dependencies: Cargo.lock is the patched source's, kept
  # here so that evaluation builds nothing.
  cargoDeps = rustPlatform.importCargoLock { lockFile = ./Cargo.lock; };
  doCheck = stdenv.buildPlatform.canExecute stdenv.hostPlatform;
  cargoTestFlags = [
    "--package"
    "harmonia-cache"
  ];
  # The tests run a nix-daemon on a store under $TMPDIR, and upstream's use curl.
  nativeCheckInputs = (prev.nativeCheckInputs or [ ]) ++ [
    nix
    curl
  ];
  preCheck = ''
    export HOME=$TMPDIR
  '';
  meta = prev.meta // {
    description = "Harmonia with the Nix Vegas stream-through patch";
    platforms = lib.platforms.linux;
  };
})
