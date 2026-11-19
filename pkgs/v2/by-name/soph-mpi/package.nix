# The Sophgo userspace middleware (cvi_mpi): the modules the display and H.264 path need.
# withCamera adds the capture path (VI, ISP and its 3A libraries).
{
  lib,
  stdenv,
  fetchFromGitHub,
  soph-ion-uapi,
  withCamera ? false,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "soph-mpi" + lib.optionalString withCamera "-camera";
  version = "0-unstable-2025-693a72a1";

  src = fetchFromGitHub {
    owner = "sophgo";
    repo = "cvi_mpi";
    rev = "693a72a1d52f2e08ea767e0a72905e81f10572a5";
    hash = "sha256-cz+9kD6WTu91j7lbhxP9gq6iP+kMNoy39I9afVgW90g=";
  };

  # Maps ION memory through /dev/soph-ion instead of /dev/mem, which a STRICT_DEVMEM
  # kernel refuses for RAM.
  patches = [ ./devmem-soph-ion.patch ] ++ lib.optional withCamera ./isp-shared-buffer-heap.patch;

  strictDeps = true;
  buildInputs = [ soph-ion-uapi ];

  modulesToBuild = [
    "sys"
    "vo"
    "vdec"
    "mipi_tx"
    "rgn"
  ]
  ++ lib.optionals withCamera [
    "bin"
    "vi"
    "vpss"
    "isp"
  ];

  postPatch = ''
    # The vendor Makefiles set SHELL = /bin/bash.
    find . \( -name 'Makefile' -o -name '*.mk' \) -print0 \
      | xargs -0 sed -i 's|^SHELL = /bin/bash|SHELL = ${stdenv.shell}|'

    # T-Head-only ISA flags from Sophgo's toolchain fork; stock gcc rejects them.
    substituteInPlace mpi_param.mk \
      --replace-fail \
        'OPT_LEVEL += -mno-ldd -mcpu=c906fdv -march=rv64imafdcv0p7xthead -mcmodel=medany -mabi=lp64d' \
        'OPT_LEVEL += -mcmodel=medany -mabi=lp64d'

    # CVI_SYS_Init() shells out to devmem, which the badge lacks; the same writes are
    # mipi_tx's fab_lowpower_off parameter.
    substituteInPlace modules/sys/src/cvi_sys.c \
      --replace-fail '	pthread_once(&lp_off_once, _sys_low_power_off);' ""
  ''
  + lib.optionalString withCamera ''
    # Keep the ISP and 3A libraries without the tuning daemons and replay tools.
    sed -i -e '/generate_toolJson.sh/d' -e '/cd isp-daemon2;/d' \
      -e '/raw_replay; \$(MAKE) all/d' -e '/raw_dump; \$(MAKE) all/d' modules/isp/cv181x/Makefile
    if grep -q 'generate_toolJson\|isp-daemon2; \$(MAKE) -j4\|raw_replay; \$(MAKE) all\|raw_dump; \$(MAKE) all' \
      modules/isp/cv181x/Makefile; then
      exit 1
    fi
  ''
  + lib.optionalString (withCamera && stdenv.hostPlatform.isAarch64) ''
    # Alias vendor object names to the selected toolchain triple.
    find modules -name '*.aarch64-linux-gnu.*.o' -print0 | while IFS= read -r -d "" o; do
      ln -s "$(basename "$o")" "''${o/.aarch64-linux-gnu./.${stdenv.hostPlatform.config}.}"
    done
    ln -s aarch64-linux-gnu modules/bin/prebuilt/${stdenv.hostPlatform.config}

    # The prebuilt objects need GCC outline atomics after the shared-library inputs.
    cat > ld-libgcc <<EOF
    #!${stdenv.shell}
    exec ${stdenv.cc.targetPrefix}ld "\$@" $($CC -print-libgcc-file-name)
    EOF
    chmod +x ld-libgcc
    substituteInPlace mpi_param.mk --replace-fail 'LD := $(CROSS_COMPILE)ld' "LD := $PWD/ld-libgcc"
  '';

  dontConfigure = true;

  # GCC-9-era code built with -Werror.
  # The ISP diagnostics use non-literal format strings.
  env.NIX_CFLAGS_COMPILE = "-Wno-error" + lib.optionalString withCamera " -Wno-format-security";

  buildPhase = ''
    runHook preBuild

    # `prepare` stamps __CV181X__ over __CV180X__. A CV180X build succeeds, then
    # rejects every bind to VO at runtime.
    make prepare CHIP_ARCH=CV181X PARAM_FILE=$PWD/mpi_param.mk
    grep -q '__CV181X__' include/linux/cvi_defines.h \
      || { echo "prepare did not stamp __CV181X__"; exit 1; }
    if grep -q '#define __CV180X__' include/linux/cvi_defines.h; then
      echo "cvi_defines.h still defines __CV180X__; refusing to build"
      exit 1
    fi

    for m in $modulesToBuild; do
      echo "=== building modules/$m ==="
      make -C "modules/$m" all \
        CHIP_ARCH=CV181X \
        CROSS_COMPILE=${stdenv.cc.targetPrefix}
    done

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib $out/include
    # The module Makefiles drop their output in ./lib.
    cp -v lib/*.so $out/lib/ 2>/dev/null || true
    cp -v lib/*.a  $out/lib/ 2>/dev/null || true

    # The public headers plus the per-module ones the samples include.
    cp -r include/. $out/include/
    for m in $modulesToBuild; do
      if [ -d "modules/$m/include" ]; then
        cp -r "modules/$m/include/." $out/include/
      fi
    done

    if [ -z "$(ls -A $out/lib 2>/dev/null)" ]; then
      echo "no libraries were installed -- the module build produced nothing"
      exit 1
    fi

    runHook postInstall
  '';

  meta = {
    description = "Sophgo CVITEK multimedia middleware (cvi_mpi) for CV181x/SG2000";
    homepage = "https://github.com/sophgo/cvi_mpi";
    # No license: the vendor tree ships none.
    platforms = [
      "aarch64-linux"
      "riscv64-linux"
    ];
  };
})
