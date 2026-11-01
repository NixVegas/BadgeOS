# The badge's runtime content tree, /etc/nix-badge:
#   lib/      shared modules, imported as <nix-badge/lib/...>
#   oled.d/   NN-*.nix OLED screens, cycled in file name order
#   bling.d/  NN-*.nix LED patterns
# Imports are rewritten to <nix-badge/lib/...>, which the runtime resolves via its
# nix-badge=/etc/nix-badge search path.
{
  lib,
  runCommand,
  buildPackages,
}:
{
  # Bad Apple clip parameters; the geometry must match the runtime OLED.
  width ? 128,
  height ? 64,
  fps ? 60,
  durationSeconds ? null,
  keyframeInterval ? 60,

  badappleLive ? buildPackages.nix-badge-bling-badapple-live {
    inherit
      width
      height
      fps
      durationSeconds
      keyframeInterval
      ;
  },
}:
let
  # The info screens (10- is Bad Apple, added separately).
  screens = [
    # Also the initrd boot splash.
    {
      n = "15";
      name = "bootinfo";
      src = ./screens/bootinfo.nix;
    }
    {
      n = "20";
      name = "battery";
      src = ./screens/battery.nix;
    }
    {
      n = "30";
      name = "load";
      src = ./screens/load.nix;
    }
    {
      n = "40";
      name = "power";
      src = ./screens/power.nix;
    }
    {
      n = "50";
      name = "clock";
      src = ./screens/clock.nix;
    }
    {
      n = "60";
      name = "currentsystem";
      src = ./screens/currentsystem.nix;
    }
    {
      n = "65";
      name = "net";
      src = ./screens/net.nix;
    }
    {
      n = "62";
      name = "wifi-scan";
      src = ./screens/wifi-scan.nix;
    }
    {
      n = "63";
      name = "bt-scan";
      src = ./screens/bt-scan.nix;
    }
    {
      n = "66";
      name = "ticker";
      src = ./screens/ticker.nix;
    }
    {
      n = "67";
      name = "heartbeat";
      src = ./screens/heartbeat.nix;
    }
    {
      n = "68";
      name = "fps";
      src = ./screens/fps.nix;
    }
    {
      n = "69";
      name = "dial";
      src = ./screens/dial.nix;
    }
    # Hidden: the bootswap daemon jumps here via the screen-control API.
    {
      n = "90";
      name = "swapcore";
      src = ./screens/swapcore.nix;
    }
  ];

  # Demoscene effects, 128x64 only, copied verbatim.
  effects = [
    {
      n = "70";
      name = "xor";
      src = ./effects/xor-munch.nix;
    }
    {
      n = "72";
      name = "plasma";
      src = ./effects/plasma.nix;
    }
    {
      n = "74";
      name = "starfield";
      src = ./effects/starfield.nix;
    }
    {
      n = "76";
      name = "rotozoom";
      src = ./effects/rotozoom.nix;
    }
  ];

  screenCmds = lib.concatMapStringsSep "\n" (s: ''
    sed -E 's|import \./draw\.nix|import <nix-badge/lib/draw.nix>|g' ${s.src} > "$out/oled.d/${s.n}-${s.name}.nix"
  '') screens;

  effectCmds = lib.concatMapStringsSep "\n" (e: ''
    cp ${e.src} "$out/oled.d/${e.n}-${e.name}.nix"
  '') effects;

  effectChecks = lib.concatMapStringsSep "\n" (e: ''
    checkFrame "$out/oled.d/${e.n}-${e.name}.nix" 64 256
    echo "nix-badge-content: effect ${e.name} -> valid 128x64 frame (256 ints)"
  '') effects;

  # Each info screen at both panel heights: 128 ints @32, 256 @64.
  checkCmds = lib.concatMapStringsSep "\n" (s: ''
    checkFrame "$out/oled.d/${s.n}-${s.name}.nix" 32 128
    checkFrame "$out/oled.d/${s.n}-${s.name}.nix" 64 256
    echo "nix-badge-content: ${s.name} -> <nix-badge/lib> imports resolve; valid frame @32 and @64"
  '') screens;
in
runCommand "nix-badge-content"
  {
    nativeBuildInputs = [ buildPackages.nix ];
  }
  ''
    mkdir -p "$out/lib" "$out/oled.d" "$out/bling.d"

    cp ${./oled.nix} "$out/lib/oled.nix"
    cp ${./screens/gallant-font-data.nix} "$out/lib/gallant-font-data.nix"
    cp ${./screens/spleen-5x8-font-data.nix} "$out/lib/spleen-5x8-font-data.nix"
    cp ${./screens/spleen-8x16-font-data.nix} "$out/lib/spleen-8x16-font-data.nix"
    cp ${./lib/font.nix} "$out/lib/font.nix"
    sed -E \
      -e 's|import \.\./oled\.nix|import <nix-badge/lib/oled.nix>|g' \
      -e 's|import \./gallant-font-data\.nix|import <nix-badge/lib/gallant-font-data.nix>|g' \
      -e 's|import \./spleen-5x8-font-data\.nix|import <nix-badge/lib/spleen-5x8-font-data.nix>|g' \
      -e 's|import \./spleen-8x16-font-data\.nix|import <nix-badge/lib/spleen-8x16-font-data.nix>|g' \
      ${./screens/draw.nix} > "$out/lib/draw.nix"

    cp ${badappleLive}/badapple-live.nix "$out/oled.d/10-badapple.nix"
    ${screenCmds}
    ${effectCmds}

    cp ${./leds-live.nix} "$out/bling.d/10-rainbow.nix"
    cp ${./leds/solid.nix} "$out/bling.d/20-solid.nix"
    cp ${./leds/pulse.nix} "$out/bling.d/30-pulse.nix"
    cp ${./leds/chase.nix} "$out/bling.d/40-chase.nix"
    cp ${./leds/sparkle.nix} "$out/bling.d/50-sparkle.nix"
    cp ${./leds/fire.nix} "$out/bling.d/60-fire.nix"

    # --impure below: <nix-badge> comes from NIX_PATH, currentsystem reads currentSystem.
    export NIX_PATH="nix-badge=$out"
    export NIX_STATE_DIR="$PWD/nix-state" NIX_STORE_DIR="$PWD/nix-store" HOME="$PWD"

    for lp in "$out"/bling.d/*.nix; do
      nix --extra-experimental-features nix-command eval --impure --raw --expr "
        let r = (import $lp) {
          t = 1234; frameIndex = 3; width = 24; height = 1; backend = 0; fps = 30;
          strap = 1; batteryMv = 4100; batteryPct = 87; onUsb = true; load1 = 0.1;
          cpuPct = 5; memPct = 40; uptimeS = 10;
        };
        in if builtins.length r.bitmap == 24
              && builtins.all (x: builtins.isInt x && x >= 0 && x <= 16777215) r.bitmap
              && builtins.isInt r.nextMs && r.nextMs > 0
           then \"ok\" else throw \"bad LED frame\"
      " >/dev/null || { echo "SELFTEST FAIL: $lp is not a valid LED pattern" >&2; exit 1; }
      echo "nix-badge-content: LED pattern $(basename "$lp") -> valid 24-LED frame"
    done
    checkFrame() {
      local f="$1" h="$2" want="$3"
      nix --extra-experimental-features nix-command eval --impure --raw --expr "
        let r = (import $f) {
          t = 1234; frameIndex = 0; width = 128; height = $h; batteryMv = 4100;
          batteryPct = 87; onUsb = true; load1 = 0.42; cpuPct = 12; memPct = 40;
          uptimeS = 90061; backend = 0; fps = 60; strap = 1; vselMv = 5010;
          nixosVersion = \"26.05.20260830.1a2b3c\"; kernelVersion = \"6.18.44-test\";
        };
        in if builtins.length r.bitmap == $want
              && builtins.all (x: builtins.isInt x) r.bitmap
              && builtins.any (x: x != 0) r.bitmap
              && builtins.isInt r.nextMs && r.nextMs > 0
           then \"ok\" else throw \"bad frame\"
      " >/dev/null || { echo "SELFTEST FAIL: $f did not eval to a valid $want-int frame @h=$h" >&2; exit 1; }
    }
    ${checkCmds}
    ${effectChecks}

    # Bad Apple frame 0 must eval and carry the HUD overlay (backend 1 = nix).
    nix --extra-experimental-features nix-command eval --impure --raw --expr "
      let r = (import $out/oled.d/10-badapple.nix) {
        frameIndex = 0; width = 128; height = 64; backend = 1; fps = 60; strap = 1; vselMv = 5010;
        t = 0; batteryMv = 0; batteryPct = 0; onUsb = false; load1 = 0.0;
        cpuPct = 0; memPct = 0; uptimeS = 0;
      };
      in if builtins.isList r.bitmap && builtins.isInt r.nextMs
            && r.overlayN > 0 && builtins.all (x: builtins.isInt x) r.overlay
         then \"ok\" else throw \"bad badapple HUD frame\"
    " >/dev/null || { echo "SELFTEST FAIL: 10-badapple.nix frame 0 / HUD overlay did not eval" >&2; exit 1; }
    echo "nix-badge-content: badapple frame 0 evals + carries a [nix] fps HUD overlay"

    # Without the search path a screen must fail to import.
    if NIX_PATH="" nix --extra-experimental-features nix-command eval --impure --raw --expr "
      (import $out/oled.d/20-battery.nix) { width = 128; height = 64; batteryPct = 50; batteryMv = 3900; onUsb = false; } " >/dev/null 2>&1; then
      echo "SELFTEST FAIL: 20-battery.nix resolved without the <nix-badge> search path" >&2
      exit 1
    fi
    echo "nix-badge-content: confirmed screens require the <nix-badge> search path"

    echo "nix-badge-content: assembled lib/ + oled.d/ (badapple + ${toString (builtins.length screens)} screens) + bling.d/"
  ''
