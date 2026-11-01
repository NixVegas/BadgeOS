# nv12-convert-test.c against the patched wlroots' NV12 converters, with wlroots'
# warning flags as errors. It runs at build time (through qemu-user when cross), so
# an aarch64 build checks the NEON kernel against the C one.
{
  stdenv,
  buildPackages,
  wlroots_0_20,
}:
stdenv.mkDerivation {
  pname = "wlroots-nv12-tests";
  inherit (wlroots_0_20) version src patches;

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    $CC -std=c11 -O2 -Wall -Wextra -Werror -Wundef -Wlogical-op \
      -Wmissing-include-dirs -Wold-style-definition -Wpointer-arith -Winit-self \
      -Wstrict-prototypes -Wimplicit-fallthrough=2 -Wendif-labels \
      -Wstrict-aliasing=2 -Woverflow -Wmissing-prototypes -Walloca \
      -Wno-missing-braces -Wno-missing-field-initializers -Wno-unused-parameter \
      -D_POSIX_C_SOURCE=200809L -Iinclude \
      render/pixman/nv12.c ${./nv12-convert-test.c} -lm -o nv12-convert-test
    ${stdenv.hostPlatform.emulator buildPackages} ./nv12-convert-test
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 -t $out/bin nv12-convert-test
    runHook postInstall
  '';
}
