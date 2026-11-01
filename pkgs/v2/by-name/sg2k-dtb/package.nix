# A board's device tree for one core, $out/sophgo/<dtb>, built against the kernel
# source's DTS include tree the way the kernel's dtb rule does.
{
  lib,
  runCommand,
  applyPatches,
  stdenvNoCC,
  buildPackages,
  kernel,
  board ? "nix-badge",
  core ? "riscv",
  # A fixed USB host instead of the fixed peripheral. dr_mode="otg" soft-locks CPU#0
  # (USB_VBUS_DET senses our own USB_VBUS_EN), so each role is its own DTB.
  usbHost ? false,
  # Files from the board's set, appended after the top DTS and before the host fragment.
  dtsFragments ? [ ],
}:
let
  boardDts = (import ../../firmware/dts/boards.nix).${board};

  # Only the board's files, so another board's file cannot change this DTB.
  dtsDir = builtins.path {
    name = "dts";
    path = ../../firmware/dts;
    filter = path: _: lib.elem (baseNameOf path) boardDts.files;
  };

  topName = boardDts.top.${core};
  appended = dtsFragments ++ lib.optional usbHost boardDts.usbHost;
  dts =
    if appended == [ ] then
      "${dtsDir}/${topName}"
    else
      runCommand "${lib.removeSuffix ".dts" topName}-full.dts" { } ''
        cat ${lib.concatMapStringsSep " " (f: "${dtsDir}/${f}") ([ topName ] ++ appended)} > $out
      '';

  sophgoDir = if core == "arm" then "arch/arm64/boot/dts/sophgo" else "arch/riscv/boot/dts/sophgo";

  # Mainline's sophgo dtsi lacks the SoC peripheral nodes (thermal, pwm, efuse, i2s,
  # ...); Armbian's DTS patches add them.
  patchedSrc = applyPatches {
    name = "linux-${kernel.version}-sophgo-dts-patched";
    src = kernel.src;
    patches = import ../../kernel/patches/armbian/dts-patches.nix;
  };
in
stdenvNoCC.mkDerivation {
  pname = "sg2k-${board}-${core}-dtb" + lib.optionalString usbHost "-usb-host";
  version = kernel.version;

  src = patchedSrc;

  nativeBuildInputs = [
    buildPackages.buildPackages.gcc
    buildPackages.buildPackages.dtc
  ];

  dontConfigure = true;

  buildPhase = "true";

  installPhase = ''
    KSRC="$NIX_BUILD_TOP/$sourceRoot"
    cd "$KSRC"

    # include-prefixes holds relative symlinks; make them absolute.
    INCDIR=$(mktemp -d)
    for link in scripts/dtc/include-prefixes/*; do
      name=$(basename "$link")
      real=$(realpath "scripts/dtc/include-prefixes/$name")
      ln -s "$real" "$INCDIR/$name"
    done
    # The top-level include/, for dt-bindings not reached through a symlink.
    ln -sf "$(realpath include)" "$INCDIR/include"

    # The core's sophgo DTS dir, for dtc -i, so labels resolve within the dir.
    SOPHGO_DIR=$(realpath ${sophgoDir})

    # The DTS lives outside the kernel tree, so -I the sophgo dir for its #includes.
    TMPDTS=$(mktemp "$NIX_BUILD_TOP/${board}-${core}.XXXXXX.dts")
    gcc -E \
      -nostdinc \
      -I "$INCDIR" \
      -I "$SOPHGO_DIR" \
      -I "${dtsDir}" \
      -undef -D__DTS__ \
      -x assembler-with-cpp \
      ${dts} \
      -o "$TMPDTS"

    mkdir -p "$out/sophgo"
    dtc \
      -I dts \
      -O dtb \
      -i "$SOPHGO_DIR" \
      -i "$INCDIR" \
      -Wno-unit_address_vs_reg \
      -Wno-avoid_unnecessary_addr_size \
      -Wno-alias_paths \
      -Wno-interrupt_map \
      -Wno-simple_bus_reg \
      "$TMPDTS" \
      -o "$out/sophgo/${boardDts.dtb}"
  '';

  meta = {
    description = "Device tree blob for an SG200x board and core";
    license = lib.licenses.gpl2Only;
  };
}
