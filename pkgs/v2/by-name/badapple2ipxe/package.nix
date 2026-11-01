# Compiles a video into an iPXE console-animation script (see badapple2ipxe.py).
# ffmpeg does the decode/scale/threshold; the Python emits the iPXE.
{
  lib,
  callPackage,
  writeShellApplication,
  python3,
  ffmpeg-headless,
}:
writeShellApplication {
  name = "badapple2ipxe";
  runtimeInputs = [
    python3
    ffmpeg-headless
  ];
  text = ''
    exec python3 ${./badapple2ipxe.py} "$@"
  '';
  passthru.tests.clip = callPackage ./test.nix { };
  meta = {
    description = "Compile a video into an iPXE console animation script";
    mainProgram = "badapple2ipxe";
    license = lib.licenses.mit;
  };
}
