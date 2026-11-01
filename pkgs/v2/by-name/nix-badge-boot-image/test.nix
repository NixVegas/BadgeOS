# The generation image over badge1-arm (unsigned, so no signer) and its module wiring,
# then mock systems: two kernels, no rauc.external, the riscv command-line budget, the
# kernel size limit, and a signed image whose scripts boot in the sandbox U-Boot. The
# 12 MiB video mock kernel needs sophgone's sandbox: the stock one bootm-decompresses
# only 8 MiB.
{
  lib,
  runCommand,
  testers,
  dtc,
  ubootTools,
  nix-badge-fit-signing,
  nix-badge-boot-image,
  # nixosConfigurations.badge1-arm-x86_64
  realSystem,
  sandbox,
}:
let
  fit = nix-badge-fit-signing;
  makeBootImage = nix-badge-boot-image;
  daemon = fit.passthru.testDaemon;

  # ---- real system ----
  cfg = realSystem.config;
  real = makeBootImage {
    sys = realSystem;
    core = "arm";
    secure = false;
    fitKeyCert = null;
  };
  realKernel = "${cfg.boot.kernelPackages.kernel}/${cfg.system.boot.loader.kernelFile}";
  wired = makeBootImage {
    sys = realSystem;
    inherit (cfg.hardware.sg2k) core fitKeyCert;
    secure = cfg.hardware.sg2k.secureBoot;
    raucExternal = cfg.hardware.sg2k.emmc.enable;
    dataCard = cfg.hardware.sg2k.externalStorage.enable;
  };
  # Evaluation-time facts, reported by the build so a failure names itself.
  evalChecks = {
    "hardware.sg2k.core is arm" = cfg.hardware.sg2k.core == "arm";
    "system.build.bootImage is makeBootImage over the config" =
      cfg.system.build.bootImage.drvPath == wired.drvPath;
    "the base toplevel links boot-image" =
      lib.hasInfix (builtins.unsafeDiscardStringContext "ln -s ${cfg.system.build.bootImage} $out/boot-image") (
        builtins.unsafeDiscardStringContext cfg.system.systemBuilderCommands
      );
    "the base kernelParams leave init= and \${nixbadge_args} to the FIT line" =
      !lib.any (x: lib.hasPrefix "init=" x || x == "\${nixbadge_args}") cfg.boot.kernelParams;
    "a specialisation toplevel carries no boot-image" =
      !lib.hasInfix "boot-image" cfg.specialisation.video.configuration.system.systemBuilderCommands;
  };

  # ---- mocks ----
  # mockKernel <letter>: an Image of copies of the letter, 64 KiB; "b", the video
  # kernel, is 12 MiB.
  mockKernelOf =
    n: bytes:
    runCommand "mock-kernel-${n}" { } ''
      mkdir $out
      head -c ${toString bytes} /dev/zero | tr '\0' '${n}' > $out/Image
    '';
  mockKernel = n: mockKernelOf n (if n == "b" then 12 * 1024 * 1024 else 65536);
  # Sparse kernels at the uncompressed limit and one byte past it (no disk cost).
  sparseKernel =
    name: bytes:
    runCommand "mock-kernel-${name}" { } ''
      mkdir $out
      truncate -s ${toString bytes} $out/Image
    '';
  mockDtbs =
    n:
    runCommand "mock-dtbs-${n}" { nativeBuildInputs = [ dtc ]; } ''
      mkdir -p $out/sophgo
      echo '/dts-v1/; / { model = "${n}"; };' | dtc -I dts -O dtb -o $out/sophgo/mock.dtb
    '';
  mockCfg =
    {
      params,
      kernel ? mockKernel "a",
      dtbs ? mockDtbs "badge",
    }:
    {
      boot.kernelParams = params;
      boot.kernelPackages.kernel = kernel;
      system.boot.loader.kernelFile = "Image";
      hardware.deviceTree = {
        package = dtbs;
        name = "sophgo/mock.dtb";
      };
    };
  mockSys = base: specs: {
    config = mockCfg base // {
      specialisation = lib.mapAttrs (_: s: { configuration = mockCfg s; }) specs;
    };
  };
  baseParams = [
    "console=ttyS0,115200"
    "cma=16M"
    "dm-mod.waitfor=PARTUUID=\${nixroot}"
  ];

  # desktop: own DTB, same kernel; video: its own kernel and a quoted parameter.
  twoKernelsSys = mockSys { params = baseParams; } {
    desktop = {
      params = baseParams ++ [ "cma=128M" ];
      dtbs = mockDtbs "usb-host";
    };
    video = {
      params = baseParams ++ [ "dyndbg=\"file vo.c +p\"" ];
      kernel = mockKernel "b";
    };
  };
  twoKernels = makeBootImage {
    sys = twoKernelsSys;
    core = "riscv";
    secure = false;
    fitKeyCert = null;
  };

  # A board without an eMMC boots without rauc.external.
  noRaucExt = makeBootImage {
    sys = mockSys { params = baseParams; } { };
    core = "riscv";
    secure = false;
    fitKeyCert = null;
    raucExternal = false;
  };

  overBudget = makeBootImage {
    sys = mockSys { params = baseParams; } {
      video.params = baseParams ++ [ "nixbadge.pad=${lib.fixedWidthString 886 "x" ""}" ];
    };
    core = "riscv";
    secure = false;
    fitKeyCert = null;
  };
  budgetFailure = testers.testBuildFailure overBudget.passthru.scripts;

  # kernel-limit: the base kernel at exactly 64 MiB, and at 64 MiB + 1 byte.
  limitImage =
    bytes:
    makeBootImage {
      sys = mockSys {
        params = baseParams;
        kernel = sparseKernel "limit-${toString bytes}" bytes;
      } { };
      core = "arm";
      secure = false;
      fitKeyCert = null;
    };
  atLimit = (limitImage 67108864).passthru.kernels.kernel;
  overLimitFailure = testers.testBuildFailure (limitImage 67108865).passthru.kernels.kernel;

  signed = daemon.withTestDaemon (makeBootImage {
    sys = twoKernelsSys;
    core = "riscv";
    secure = true;
    fitKeyCert = daemon.cert;
    signArgs = { inherit (daemon) certHash socketPath; };
  });
  profiles = [
    "default"
    "desktop"
    "video"
  ];
  verified = lib.genAttrs profiles (
    p:
    fit.verifyFit {
      itb = "${signed}/boot.itb";
      inherit (daemon) cert;
      config = "conf-${p}";
    }
  );
  controlDtb = fit.fitKeyDtb daemon.cert;
in
runCommand "boot-image-test"
  {
    nativeBuildInputs = [
      ubootTools
      dtc
    ];
  }
  ''
    set -euo pipefail
    fail() { echo "FAIL: $*" >&2; exit 1; }

    ${lib.concatStrings (
      lib.mapAttrsToList (n: ok: lib.optionalString (!ok) "fail ${lib.escapeShellArg n}\n") evalChecks
    )}

    # extract <itb> <dir>: every image of the FIT into <dir>/<image name>
    extract() {
      mkdir -p "$2"
      dumpimage -l "$1" > "$2.list"
      sed -n 's/^ Image \([0-9]*\) (\(.*\))$/\1 \2/p' "$2.list" | while read -r i n; do
        dumpimage -T flat_dt -p "$i" -o "$2/$n" "$1" > /dev/null
      done
    }

    # ---- real system (badge1-arm, unsigned) ----
    itb=${real}/boot.itb
    extract $itb real
    for n in kernel fdt-default fdt-desktop fdt-video script-default script-desktop script-video; do
      grep -qx " Image [0-9]* ($n)" real.list || fail "real image lacks $n"
    done
    [ "$(fdtget -l $itb /images | wc -l)" = 7 ] || fail "real image has extra images: $(fdtget -l $itb /images)"
    [ "$(fdtget $itb /configurations default)" = conf-default ] || fail "default is not conf-default"
    for p in default desktop video; do
      [ "$(fdtget $itb /configurations/conf-$p kernel)" = kernel ] || fail "conf-$p kernel"
      [ "$(fdtget $itb /configurations/conf-$p fdt)" = fdt-$p ] || fail "conf-$p fdt"
    done
    # The kernel is gzip-compressed (bootm gunzips it to its load address); the
    # device trees and scripts are not.
    [ "$(fdtget $itb /images/kernel compression)" = gzip ] || fail "real kernel compression is not gzip"
    [ "$(fdtget $itb /images/kernel type)" = kernel ] || fail "real kernel type"
    [ "$(fdtget -t x $itb /images/kernel load)" = 81000000 ] || fail "real kernel load"
    [ "$(fdtget -t x $itb /images/kernel entry)" = 81000000 ] || fail "real kernel entry"
    grep -A6 '^ Image [0-9]* (kernel)$' real.list | grep -q 'Compression: *gzip compressed' \
      || fail "dumpimage -l does not list the real kernel as gzip compressed"
    for n in fdt-default fdt-desktop fdt-video script-default script-desktop script-video; do
      [ "$(fdtget $itb /images/$n compression)" = none ] || fail "real $n compression is not none"
    done
    gunzip -c real/kernel | cmp -s - ${realKernel} || fail "real kernel data does not gunzip to ${realKernel}"
    {
      echo "boot.itb $(stat -c %s $itb)"
      echo "kernel-uncompressed $(stat -L -c %s ${realKernel})"
      echo "kernel-gzip $(stat -c %s real/kernel)"
    } | tee sizes
    [ "$(fdtget -t bx $itb /images/fdt-desktop/hash-1 value)" != "$(fdtget -t bx $itb /images/fdt-default/hash-1 value)" ] \
      || fail "fdt-desktop is the default DTB"
    cmp -s real/fdt-desktop real/fdt-default && fail "extracted fdt-desktop equals fdt-default"
    for p in default desktop video; do
      s=real/script-$p
      cat $s; echo
      case $p in default) cma=16M ;; *) cma=128M ;; esac
      for want in "init=/init-arm nixbadge.profile=$p " '${"$"}{verityargs}' 'rauc.slot=${"$"}{rauc_slot}' \
                  " cma=$cma " 'nixbadge.bootmedium=${"$"}{bootmedium} ${"$"}{nixbadge_args}"'; do
        grep -qF -- "$want" $s || fail "script-$p lacks '$want'"
      done
      # the script carries ${"$"}{nixbadge_args} once, last
      [ "$(grep -oF '${"$"}{nixbadge_args}' $s | wc -l)" = 1 ] || fail "script-$p has ${"$"}{nixbadge_args} more than once"
      [ "$(tail -n 1 $s)" = 'bootm ${"$"}{loadaddr}#conf-'$p'; false' ] || fail "script-$p does not end in bootm conf-$p; false"
      [ -n "$(tail -c 1 $s)" ] || fail "script-$p ends in a newline"
    done
    if grep -l 'init=/nix/store' real/script-*; then fail "a script names init=/nix/store"; fi
    [ "$(cat ${real}/.secure)" = unsigned ] || fail "real .secure is not unsigned"
    [ "$(cat ${real}/profiles | tr '\n' ' ')" = "default desktop video " ] || fail "real profiles: $(cat ${real}/profiles)"

    # ---- fit-two-kernels (mock, riscv) ----
    itb=${twoKernels}/boot.itb
    extract $itb two
    [ "$(fdtget -l $itb /images | sort | tr '\n' ' ')" = "fdt-default fdt-desktop fdt-video kernel kernel-video script-default script-desktop script-video " ] \
      || fail "two-kernels images: $(fdtget -l $itb /images)"
    [ "$(fdtget $itb /configurations/conf-video kernel)" = kernel-video ] || fail "conf-video does not boot kernel-video"
    [ "$(fdtget $itb /configurations/conf-desktop kernel)" = kernel ] || fail "conf-desktop does not boot kernel"
    [ "$(fdtget $itb /configurations/conf-default kernel)" = kernel ] || fail "conf-default does not boot kernel"
    for k in kernel kernel-video; do
      [ "$(fdtget $itb /images/$k compression)" = gzip ] || fail "two-kernels $k compression is not gzip"
    done
    gunzip -c two/kernel-video | cmp -s - ${mockKernel "b"}/Image || fail "kernel-video is not the video kernel"
    gunzip -c two/kernel | cmp -s - ${mockKernel "a"}/Image || fail "kernel is not the base kernel"
    [ "$(fdtget $itb /images/kernel arch)" = riscv ] || fail "riscv kernel arch"
    grep -qF 'init=/init-riscv nixbadge.profile=video ' two/script-video || fail "riscv script init"

    # ---- no-rauc-ext (mock): only raucExternal = false drops ${"$"}{rauc_ext} ----
    grep -qF '${"$"}{rauc_ext}' two/script-default || fail "the default mock lacks ${"$"}{rauc_ext}"
    if grep -qF rauc_ext ${noRaucExt.passthru.scripts}/script-default; then
      fail "raucExternal = false still carries rauc_ext"
    fi

    # ---- data cards: nixbadge-datacard tells U-Boot it may boot a card's FIT ----
    [ "$(fdtget ${wired}/boot.itb / nixbadge-datacard)" = 1 ] || fail "badge1 (data cards on) lacks nixbadge-datacard"
    if fdtget ${real}/boot.itb / nixbadge-datacard > /dev/null 2>&1; then
      fail "an image without dataCard has nixbadge-datacard"
    fi

    # ---- cmdline-budget (mock, riscv) ----
    [ "$(cat ${budgetFailure}/testBuildFailure.exit)" != 0 ] || fail "over-budget build succeeded"
    grep -qF 'boot-image: riscv command line would exceed 1000 bytes' ${budgetFailure}/testBuildFailure.log \
      || { cat ${budgetFailure}/testBuildFailure.log; fail "no budget message"; }

    # ---- kernel-limit (mock): 64 MiB builds, 64 MiB + 1 byte fails naming both limits ----
    gunzip -c ${atLimit}/Image.gz | wc -c | grep -qx 67108864 || fail "the 64 MiB kernel did not compress whole"
    [ "$(cat ${overLimitFailure}/testBuildFailure.exit)" != 0 ] || fail "a 64 MiB + 1 byte kernel built"
    for want in 'is 67108865 bytes uncompressed' '67108864 (64 MiB, CONFIG_SYS_BOOTM_LEN' '< 0x7000000'; do
      grep -qF -- "$want" ${overLimitFailure}/testBuildFailure.log \
        || { cat ${overLimitFailure}/testBuildFailure.log; fail "kernel-limit message lacks '$want'"; }
    done

    # ---- signed (mock): every configuration verifies, every script boots its own ----
    [ "$(cat ${signed}/.secure)" = signed ] || fail "signed .secure is not signed"
    ${lib.concatMapStrings (p: ''
      grep -qF "Using 'conf-${p}' configuration" ${verified.${p}}/verify.log || fail "conf-${p} not selected"
      grep -qF 'sha256,rsa2048:sg1-image+ OK' ${verified.${p}}/verify.log || fail "conf-${p} did not verify"
    '') profiles}
    for p in default desktop video; do
      # default boots as a factory reset (btnsel's both-buttons case); the others with
      # nixbadge_args unset, which hush expands to nothing (the trailing space stays)
      case $p in
        default)  args="setenv nixbadge_args nixbadge.reset=userdata;"; tail=" nixbadge.reset=userdata" ;;
        *)        args=""; tail=" " ;;
      esac
      sblog=$(timeout 60 ${sandbox}/bin/u-boot -d ${controlDtb}/control.dtb -c "host load hostfs - 0x8a000000 ${signed}/boot.itb; \
        setenv loadaddr 0x8a000000; setenv verityargs dm-mod.create=V; setenv rauc_slot B; setenv rauc_ext rauc.external; $args \
        setenv bootmedium 1; setenv nixroot U; setenv sb_show bootargs; source 0x8a000000:script-$p" 2>&1 | tr -d '\r') || true
      printf '%s\n' "$sblog" > sandbox-$p.log
      case $p in
        default)  extra="" ;;
        desktop)  extra=" cma=128M" ;;
        video)    extra=' dyndbg="file vo.c +p"' ;;
      esac
      want="bootargs=init=/init-riscv nixbadge.profile=$p console=ttyS0,115200 cma=16M dm-mod.waitfor=PARTUUID=U$extra dm-mod.create=V rauc.slot=B rauc.external nixbadge.bootmedium=1$tail"
      printf '%s\n' "$sblog" | grep -qF "Using 'conf-$p' configuration" || { cat sandbox-$p.log; fail "script-$p did not boot conf-$p"; }
      printf '%s\n' "$sblog" | grep -qx 'BOOTED bootm' || { cat sandbox-$p.log; fail "script-$p did not boot"; }
      printf '%s\n' "$sblog" | grep -qxF "$want" || { cat sandbox-$p.log; echo "want: $want"; fail "script-$p bootargs"; }
    done

    mkdir $out
    cp real.list two.list sandbox-*.log sizes $out/
    cp real/script-* $out/
    ${lib.concatMapStrings (p: "cp ${verified.${p}}/verify.log $out/verify-conf-${p}.log\n") profiles}
  ''
