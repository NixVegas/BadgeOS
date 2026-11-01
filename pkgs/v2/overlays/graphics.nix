# Mesa and SDL3 trimmed to what the badge runs: llvmpipe only, no X or Vulkan.
final: prev:
let
  inherit (prev) lib;
in
{
  mesa =
    (prev.mesa.override {
      galliumDrivers = [
        # softpipe is 4-6x slower, uses more RAM and still needs LLVM.
        "llvmpipe"
      ];
      vulkanDrivers = [ ];
    }).overrideAttrs
      (
        o:
        {
          # spirv2dxil is a declared output that only the d3d12 driver fills.
          postInstall = (o.postInstall or "") + ''
            mkdir -p "$spirv2dxil"
          '';
          # VA has no driver with only llvmpipe, and meson fails on that.
          mesonFlags =
            (o.mesonFlags or [ ])
            ++ [
              (lib.mesonEnable "gallium-va" false)
              (lib.mesonOption "video-codecs" "")
            ]
            # Rusticl does not cross-build for riscv64: libclang rejects the Rust triple.
            ++ lib.optional prev.stdenv.hostPlatform.isRiscV64 (lib.mesonBool "gallium-rusticl" false);
        }
        // lib.optionalAttrs prev.stdenv.hostPlatform.isRiscV64 {
          postFixup = lib.replaceStrings [ " $opencl/lib/libRusticlOpenCL.so" ] [ "" ] (o.postFixup or "");
        }
      );

  # No X, Vulkan, tray, IBus or JACK, and a stub zenity instead of GTK4.
  sdl3 = prev.sdl3.override {
    zenity = final.writeShellScriptBin "zenity" "exit 1";
    x11Support = false;
    vulkanSupport = false;
    traySupport = false;
    ibusSupport = false;
    jackSupport = false;
  };
}
