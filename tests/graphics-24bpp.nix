# The 24bpp (RGB888/BGR888) desktop formats on the host: the patched sway on wlroots'
# headless backend and pixman renderer, probed by ./graphics-24bpp/run.sh. Building
# it also runs the patched pixman's and SDL3's own test suites.
{ pkgs }:
let
  # Without the pixman patches, so this sway does not rebuild against them.
  patched = pkgs.extend (import ../pkgs/v2/patches/overlay.nix { withPixman = false; });

  pixmanPatched = pkgs.pixman.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ import ../pkgs/v2/patches/pixman;
  });

  badgeGraphicsCheck = patched.callPackage ../pkgs/v2/by-name/badge-graphics-check/package.nix { };
in
patched.runCommand "test-graphics-24bpp"
  {
    nativeBuildInputs = [
      patched.sway-unwrapped
      patched.wayland-utils
      patched.grim
      patched.jq
      patched.python3
      badgeGraphicsCheck
    ];
    buildInputs = [ pixmanPatched ];
  }
  ''
    bash ${./graphics-24bpp}/run.sh
    touch $out
  ''
