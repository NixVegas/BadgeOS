# Patches on top of nixpkgs for the badge's graphics stack. Each package's patch
# list is pkgs/patches/<name>/default.nix, applied in order after nixpkgs' own.
#
# withPixman: also patch pixman. false keeps a closure on nixpkgs' pixman, so it
# does not rebuild everything that links pixman.
{
  withPixman ? true,
}:
final: prev:
let
  addPatches =
    pkg: patches:
    pkg.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ patches;
    });
in
{
  # sway-unwrapped calls wlroots_0_20.override, which keeps these patches.
  wlroots_0_20 = addPatches prev.wlroots_0_20 (import ./wlroots);
  sway-unwrapped = addPatches prev.sway-unwrapped (import ./sway);

  # On the badge, prev.sdl3 is already trimmed (overlays/graphics.nix); the patches
  # go on top of that. sdl2-compat runs on this sdl3, so SDL2 apps get them too.
  sdl3 = addPatches prev.sdl3 (import ./sdl3);

  # blitters-test and lowlevel-blt-bench built against this set's pixman, to
  # run on the badge itself.
  pixman-badge-tests = final.callPackage ./pixman/tests.nix { };

  # The pixman renderer's NV12 to XRGB8888 converter (wlroots 0002) against a
  # floating-point reference, compiled from this set's patched wlroots source.
  wlroots-nv12-tests = final.callPackage ./wlroots/tests.nix { };
}
// prev.lib.optionalAttrs withPixman {
  pixman = addPatches prev.pixman (import ./pixman);
}
