# Patches on top of nixpkgs for the badge's graphics stack. Each package's patch
# list is pkgs/patches/<name>/default.nix, applied in order after nixpkgs' own.
#
# withPixman: also patch pixman. false keeps a closure on nixpkgs' pixman, so it
# does not rebuild everything that links pixman.
#
# withRgb888: also give sway the patch that prefers RGB888 render buffers, for the
# rotated panel; it is not in sway's list because no other display wants it.
#
# withAutologinUnlock: also patch greetd to unlock the memory of its automatic login,
# for the panel's desktop.
#
# withTouchControls: also give the games their touch controls, for the touch bar.
{
  withPixman ? true,
  withRgb888 ? false,
  withAutologinUnlock ? false,
  withTouchControls ? false,
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
  sway-unwrapped = addPatches prev.sway-unwrapped (
    (import ./sway) ++ prev.lib.optional withRgb888 ./sway/0002-panel-rgb888.patch
  );
  wvkbd = addPatches prev.wvkbd (import ./wvkbd);

  # On the badge, prev.sdl3 is already trimmed (overlays/graphics.nix); the patches
  # go on top of that. sdl2-compat runs on this sdl3, so SDL2 apps get them too.
  sdl3 = addPatches prev.sdl3 (import ./sdl3);

  # blitters-test and lowlevel-blt-bench built against this set's pixman, to
  # run on the badge itself.
  pixman-badge-tests = final.callPackage ./pixman/tests.nix { };

  # The pixman renderer's NV12 to XRGB8888 converter (wlroots 0002) against a
  # floating-point reference, compiled from this set's patched wlroots source.
  wlroots-nv12-tests = final.callPackage ./wlroots/tests.nix { };

  # The games' touch-control core (panel-touch 0001, in both games' lists) against
  # its unit test.
  panel-touch-tests = final.callPackage ./panel-touch/tests.nix { };
}
// prev.lib.optionalAttrs withPixman {
  pixman = addPatches prev.pixman (import ./pixman);
}
// prev.lib.optionalAttrs withAutologinUnlock {
  greetd = addPatches prev.greetd (import ./greetd);
}
// prev.lib.optionalAttrs withTouchControls {
  ioquake3 = addPatches prev.ioquake3 (import ./ioquake3);
  crispy-doom = addPatches prev.crispy-doom (import ./crispy-doom);
}
