# The badge control tool: LEDs, core select, power rails, mmio and the OLED.
# Static musl, so the LED service survives switch_root with no libc to find.
{
  pkgs,
  # Link the upstream Nix C API as a second evaluator beside fix (aarch64 only).
  nixEval ? true,
  # Link the Nix C API dynamically (glibc) instead of the slow static archive link.
  # Not for the initrd: only the stage-2 oled service uses it. aarch64 + nixEval only.
  nixDynamic ? false,
  # Zig -Dcpu model, or null for baseline (nixpkgs' zig hook ignores gcc.arch).
  # Null on purpose: the XThead riscv build measured a wash, with a SIGILL risk.
  zigCpu ? null,
}:
let
  hp = pkgs.stdenv.hostPlatform;
  lib = pkgs.lib;
  # Pin zig's glibc stubs to nixpkgs' glibc so the linked symbol versions exist.
  wantDynamic = nixDynamic && nixEval && hp.isAarch64;
  glibcMM = lib.versions.majorMinor pkgs.glibc.version;
  zigTarget =
    if hp.isAarch64 then
      (if wantDynamic then "aarch64-linux-gnu.${glibcMM}" else "aarch64-linux-musl")
    else if hp.isRiscV64 then
      "riscv64-linux-musl"
    else
      throw "nix-badge: unsupported target ${hp.system}";

  wantNix = nixEval && hp.isAarch64;
  nixComps =
    if wantDynamic then
      pkgs.nixVersions.nixComponents_2_34
    else
      pkgs.pkgsStatic.nixVersions.nixComponents_2_34;
  nixExprC = nixComps."nix-expr-c";
  nixStoreC = nixComps."nix-store-c";
  nixUtilC = nixComps."nix-util-c";
  nixFetchersC = nixComps."nix-fetchers-c";
  nixClosure = pkgs.buildPackages.closureInfo {
    rootPaths = [
      nixExprC
      nixExprC.dev
      nixStoreC
      nixStoreC.dev
      nixUtilC
      nixUtilC.dev
      nixFetchersC
    ];
  };
  # libstdc++.a is in the cc `lib` output, libgcc.a (the unwinder) in its main output.
  nixCcLib = pkgs.pkgsStatic.stdenv.cc.cc.lib;
  nixCcMain = pkgs.pkgsStatic.stdenv.cc.cc;
  # Static libs pkg-config --static omits; their default output is `bin`, hence getLib.
  nixExtraLibDirs = map (p: "${lib.getLib p}/lib") [
    pkgs.pkgsStatic.acl
    pkgs.pkgsStatic.bzip2
    pkgs.pkgsStatic.libunistring
    pkgs.pkgsStatic.llhttp
  ];
  # Strip the C23 [[deprecated]] attributes zig's translate-c cannot parse.
  nixExprCHeaders = pkgs.buildPackages.runCommand "nix-expr-c-headers-nodeprecated" { } ''
    mkdir -p $out/include
    cp -r ${nixExprC.dev}/include/. $out/include/
    chmod -R +w $out/include
    sed -i 's/\[\[deprecated([^]]*)\]\]//g' $out/include/*.h
  '';

  # One flattened nix-expr-c.pc: Zig runs pkg-config without --static, keeps only
  # -I/-L/-l/-D and drops absolute .a paths, so the shipped .pc files do not survive it.
  nixEvalPkgConfig = pkgs.buildPackages.runCommand "nix-badge-nix-expr-c-pc" { } ''
    export PKG_CONFIG_PATH=""
    for p in $(cat ${nixClosure}/store-paths); do
      for d in "$p/lib/pkgconfig" "$p/share/pkgconfig"; do
        [ -d "$d" ] && PKG_CONFIG_PATH="$PKG_CONFIG_PATH:$d"
      done
    done
    export PKG_CONFIG_PATH="''${PKG_CONFIG_PATH#:}"
    pkgconfig=${pkgs.pkgsBuildBuild.pkg-config}/bin/pkg-config

    cflags="-I${nixExprCHeaders}/include $("$pkgconfig" ${staticFlag} --cflags nix-expr-c)"

    # Absolute archives become -L/-l pairs (Zig parses no -l:<file>). Order and
    # repeats matter: the aws components reference each other in a cycle.
    libs="-L$out/lib"
    for arg in ${extraLibDirFlags} $("$pkgconfig" ${staticFlag} --libs nix-expr-c) ${cxxRuntimeFlags}; do
      case "$arg" in
        /*.a)
          base=''${arg##*/}
          base=''${base#lib}
          libs="$libs -L''${arg%/*} -l''${base%.a}"
          ;;
        *) libs="$libs $arg" ;;
      esac
    done

    mkdir -p $out/lib/pkgconfig
    ${lib.optionalString (!wantDynamic) ''
      cp "$(find ${nixCcLib} -name libstdc++.a | head -1)" $out/lib/libnix_badge_cxx.a
      cp "$(find ${nixCcMain} -name libgcc.a | head -1)" $out/lib/libnix_badge_gcc.a
      chmod +w $out/lib/libnix_badge_cxx.a $out/lib/libnix_badge_gcc.a
    ''}
    cat > $out/lib/pkgconfig/nix-expr-c.pc <<EOF
    Name: nix-expr-c
    Description: The Nix C API, resolved for nix-badge
    Version: ${nixExprC.version}
    Cflags: $cflags
    Libs: $libs
    EOF
  '';

  # Requires.private holds the C++ libraries; the dynamic link needs none of it.
  staticFlag = lib.optionalString (!wantDynamic) "--static";

  extraLibDirFlags = lib.optionalString (!wantDynamic) (
    lib.concatMapStringsSep " " (d: "-L${d}") nixExtraLibDirs
  );
  # Private names: Zig maps -lstdc++ to LLVM's libc++, which is ABI-incompatible.
  cxxRuntimeFlags = lib.optionalString (!wantDynamic) "-lnix_badge_cxx -lnix_badge_gcc";

  nixArg = lib.optionalString wantNix "-Dnix-eval=true";
in
pkgs.buildPackages.stdenv.mkDerivation (finalAttrs: {
  pname = "nix-badge";
  version = "0.2";

  # Keep .gitignore: a copied .zig-cache leaves zigDeps empty.
  src = ./nix-badge;

  # The hash covers every dependency build.zig.zon pins.
  zigDeps = pkgs.buildPackages.zig.fetchDeps {
    inherit (finalAttrs) pname version src;
    hash = "sha256-TRytzmJv2GkyRn7+sQBUhKtaNJ2NxX/0tnKBCufdtLU=";
  };

  # No pkg-config here: its cross setup hook renames the binary and rewrites
  # PKG_CONFIG_PATH. build.zig uses stdenv's `patch` for the fix patches.
  nativeBuildInputs = [ pkgs.buildPackages.zig ];

  # zig's setup hook creates ZIG_GLOBAL_CACHE_DIR in configure; keep configure on.
  postConfigure = ''
    ln -s "${finalAttrs.zigDeps}" "$ZIG_GLOBAL_CACHE_DIR/p"
  '';

  buildPhase = ''
    runHook preBuild

    ${lib.optionalString wantNix ''
      export PKG_CONFIG="${pkgs.pkgsBuildBuild.pkg-config}/bin/pkg-config"
      export PKG_CONFIG_PATH="${nixEvalPkgConfig}/lib/pkgconfig''${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
      echo "nix-badge: linking the Nix C API backend through pkg-config"
    ''}

    zig build -Dtarget=${zigTarget}${
      lib.optionalString (zigCpu != null) " -Dcpu=${zigCpu}"
    } -Doptimize=ReleaseSafe ${nixArg} --prefix "$out"

    ${lib.optionalString wantDynamic ''
      # NixOS has no /lib/ld-linux; use nixpkgs' loader and an rpath for the direct deps.
      RPATH="${
        lib.concatStringsSep ":" (
          map (p: "${lib.getLib p}/lib") [
            nixExprC
            nixStoreC
            nixUtilC
            nixFetchersC
            pkgs.stdenv.cc.cc
            pkgs.glibc
          ]
        )
      }"
      ${pkgs.buildPackages.patchelf}/bin/patchelf \
        --set-interpreter ${pkgs.glibc}/lib/ld-linux-aarch64.so.1 \
        --set-rpath "$RPATH" "$out/bin/nix-badge"
      echo "nix-badge: set the dynamic interpreter and rpath"
    ''}

    # ReleaseSafe panic strings embed zig's source paths, which would keep zig and
    # llvm (~3.8 GB) in the badge closure.
    ${pkgs.buildPackages.removeReferencesTo}/bin/remove-references-to \
      -t ${pkgs.buildPackages.zig} "$out/bin/nix-badge"
    runHook postBuild
  '';

  dontInstall = true;

  # The zig unit tests (`zig build test`), run on the build host.
  passthru.tests.unit = finalAttrs.finalPackage.overrideAttrs {
    pname = "nix-badge-unit";
    buildPhase = ''
      runHook preBuild
      zig build test --summary all
      runHook postBuild
    '';
    dontInstall = false;
    installPhase = "touch $out";
  };

  meta = {
    description = "Badge control tool for the Milk-V Duo S NixOS badge (Zig)";
    platforms = pkgs.lib.platforms.linux;
  };
})
