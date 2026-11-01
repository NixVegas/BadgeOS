# This year's badge (SG2000): every package under by-name, with the kernel and the
# firmware inputs in scope.
{
  sophgone,
  autopenOverlay,
  nixpkcsOverlay,
}:
final: prev:
# Attribute names come from readDir alone (prev.lib), or the overlay recurses.
prev.lib.packagesFromDirectoryRecursive {
  callPackage = prev.newScope {
    # A default; configurations build each package against their own kernel.
    kernel = prev.linuxPackages_latest.kernel;
    inherit sophgone autopenOverlay nixpkcsOverlay;
  };
  directory = ./by-name;
}
// {
  # nix-badge without the Nix C API: fix evaluates, and the C API's static link is slow.
  nix-badge-noeval = final.nix-badge.override { nixEval = false; };

  # Parallel `make install` races libcanberra-multi's relink against -lcanberra.
  libcanberra = prev.libcanberra.overrideAttrs {
    enableParallelInstalling = false;
  };
}
