# AICSemi AIC8800D80 SDIO WiFi kernel modules (radxa-pkg/aic8800) for the Milk-V Duo S.
{
  pkgs,
  kernel,
  fwPath ? "/run/current-system/firmware/aic8800_fw/SDIO/aic8800D80",
  # cv18xx SDIO RX poll. Use it if the host does not deliver the in-band
  # interrupt. Off: mainline dwcmshc with cap-sdio-irq delivers it.
  usePoll ? false,
  # Skip the experimental patches.
  stock ? false,
  # Build the BT-over-SDIO half (hci0, through BlueZ).
  bluetooth ? false,
}:
let
  # aic8800-firmware pins the same rev. A let binding, not a formal: callPackage
  # would inject nixpkgs' top-level `src` alias.
  src = pkgs.fetchFromGitHub {
    owner = "radxa-pkg";
    repo = "aic8800";
    rev = "bd11969265809a0fc948f1107c8256bbb2c1aa60";
    hash = "sha256-7M02L7G/cadlUWF3YG5CAumtmV7RmEbRHWqZQTddRUI=";
  };
  driverSubdir = "src/SDIO/driver_fw/driver/aic8800";

  # kbuild takes ARCH from the build host by default.
  inherit (pkgs.stdenv.hostPlatform) linuxArch;
  crossPrefix = pkgs.stdenv.cc.targetPrefix;
  # The radxa series minus its USB-only patches, which fail on CRLF.
  seriesPatches = [
    "fix-sdio-firmware-path.patch"
    "fix-sdio-fall-through.patch"
    "fix-linux-6.1-build.patch"
    "fix-linux-6.7-build.patch"
    "fix-linux-6.5-build.patch"
    "fix-linux-6.9-build.patch"
    "fix-linux-6.13-build.patch"
    "fix-linux-6.14-build.patch"
    "fix-linux-6.15-build.patch"
    "fix-linux-6.16-build.patch"
    "fix-linux-6.17-build.patch"
    "fix-linux-6.19-build.patch"
    "fix-vmalloc-not-include.patch"
    "fix-build-on-low-memory-devices.patch"
  ];
in
pkgs.stdenv.mkDerivation {
  pname = "aic8800-sdio";
  version = "6.4.3.0-unstable-2026-06-20-${kernel.version}";

  inherit src;

  nativeBuildInputs = kernel.moduleBuildDependencies;

  postPatch = ''
        for p in ${pkgs.lib.concatStringsSep " " seriesPatches}; do
          patch -p1 --binary -i "debian/patches/$p"
        done
        patch -p1 --binary -i ${./aic8800-linux-7.1-sdio.patch}

        substituteInPlace ${driverSubdir}/aic8800_bsp/Makefile \
          --replace-fail '"/lib/firmware/aic8800_fw/SDIO/aic8800D80"' '"${fwPath}"'

        # Use the BT-coex firmware: the chip stages the BT patch tables, and the
        # wifi-only image stops after the jump.
        substituteInPlace ${driverSubdir}/aic8800_bsp/aic_bsp_main.c \
          --replace-fail '"fmacfw_8800d80_u02.bin"' '"fmacfwbt_8800d80_u02.bin"'

        # 7.2 dropped strncpy. ccflags-y, since KCFLAGS gets word-split and kbuild 7.2
        # ignores EXTRA_CFLAGS.
        echo "ccflags-y += -include ${./strncpy-compat.h}" \
          >> ${driverSubdir}/aic8800_fdrv/Makefile

        # 7.2 cfg80211: remain_on_channel() gained an rx_addr the driver ignores.
        substituteInPlace ${driverSubdir}/aic8800_fdrv/rwnx_main.c \
          --replace-fail 'unsigned int duration, u64 *cookie)' \
                         'unsigned int duration, u64 *cookie, const u8 *rx_addr)'

        # kernel 7.3: cfg80211 assigns the RoC/mgmt_tx/probe cookies.
        patch -p1 --binary -i ${./aic8800-linux-7.3-cfg80211-cookies.patch}

        patch -p1 --binary -i ${./aic8800-mmc-sdio-headers.patch}
        patch -p1 --binary -i ${./aic8800-cvitek-sdio-enum.patch}

        # 6.16 removed <linux/of_gpio.h>, which rfkill.c does not use.
        substituteInPlace ${driverSubdir}/aic8800_btlpm/rfkill.c \
          --replace-fail '#include <linux/of_gpio.h>
    ' ""

        ${pkgs.lib.optionalString usePoll ''
          ${pkgs.buildPackages.python3}/bin/python3 ${./aic8800-cv18xx-poll.py}
        ''}

        # fdrv builds both HCI implementations, bluedroid (the default) and BlueZ,
        # exclusive on CONFIG_BLUEDROID: select BlueZ.
        ${pkgs.lib.optionalString bluetooth ''
                substituteInPlace ${driverSubdir}/aic8800_fdrv/aic_btsdio.h \
                  --replace-fail '#else
          #define CONFIG_BLUEDROID        1 /* bleuz 0, bluedroid 1, lbh 2 */' \
                                 '#else
          #define CONFIG_BLUEDROID        0 /* bleuz 0, bluedroid 1, lbh 2 */'
                substituteInPlace ${driverSubdir}/aic8800_bsp/Makefile \
                  --replace-fail 'CONFIG_SDIO_BT = n' 'CONFIG_SDIO_BT = y'
                substituteInPlace ${driverSubdir}/aic8800_fdrv/Makefile \
                  --replace-fail 'CONFIG_SDIO_BT=n' 'CONFIG_SDIO_BT=y'

                # AICBT_INFO is an unconditional printk per packet: gate it behind
                # AICBT_DBG_FLAG, off.
                substituteInPlace ${driverSubdir}/aic8800_fdrv/aic_btsdio.h \
                  --replace-fail '#define AICBT_DBG_FLAG          1' \
                                 '#define AICBT_DBG_FLAG          0'
                substituteInPlace ${driverSubdir}/aic8800_fdrv/aic_btsdio.h \
                  --replace-fail '#define AICBT_INFO(fmt, arg...) printk("aic_btsdio: " fmt "\n" , ## arg)' \
                                 '#if AICBT_DBG_FLAG
          #define AICBT_INFO(fmt, arg...) printk("aic_btsdio: " fmt "\n" , ## arg)
          #else
          #define AICBT_INFO(fmt, arg...)
          #endif'

                # 6.12 removed hci_dev->dev_type.
                substituteInPlace ${driverSubdir}/aic8800_fdrv/btsdio.c \
                  --replace-fail 'hdev->dev_type = HCI_PRIMARY;' ""
        ''}

        # Experimental patches.
        ${pkgs.lib.optionalString (!stock) ''
          patch -p1 --binary -i ${./aic8800-drop-user-ext-flags.patch}
          patch -p1 --binary -i ${./aic8800-patch-buffer-reloc.patch}
          patch -p1 --binary -i ${./aic8800-fix6-nonblocking-startapp.patch}
          # CONFIG_AMSDU_RX=n stops the {0x170, ...} firmware patch-table write.
          substituteInPlace ${driverSubdir}/aic8800_bsp/Makefile \
            --replace-fail 'CONFIG_AMSDU_RX = y' 'CONFIG_AMSDU_RX = n'
        ''}
  '';

  makeFlags = [
    "-C"
    "${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
    "M=$(PWD)/${driverSubdir}"
    "ARCH=${linuxArch}"
    "CROSS_COMPILE=${crossPrefix}"
    # cvi_get_wifi_pwr_on_desc() and cvi_sdio_rescan() come from sdhci-cv181x,
    # which modpost cannot see.
    "KBUILD_MODPOST_WARN=1"
    "modules"
  ];

  installPhase = ''
    runHook preInstall
    instdir="$out/lib/modules/${kernel.modDirVersion}/kernel/drivers/net/wireless/aic8800"
    mkdir -p "$instdir"
    for ko in aic8800_bsp aic8800_fdrv aic8800_btlpm; do
      install -p -m 0644 ${driverSubdir}/$ko/$ko.ko "$instdir/"
    done

    # Keep kernel.dev out of the runtime closure.
    for ko in "$instdir"/*.ko; do
      ${pkgs.buildPackages.removeReferencesTo}/bin/remove-references-to -t ${kernel.dev} "$ko"
    done
    runHook postInstall
  '';

  # kbuild strips the .ko files already.
  dontStrip = true;

  meta = {
    description = "AICSemi AIC8800D80 SDIO WiFi out-of-tree kernel modules";
    license = pkgs.lib.licenses.gpl2Only;
  };
}
