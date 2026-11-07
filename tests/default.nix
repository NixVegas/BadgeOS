# The flake's checks: the packages' own tests, evaluation checks of the configurations,
# and the image and bundle tests.
{
  self,
  inputs,
  system,
  pkgs,
  packages,
  fixtures,
  nixosSystem,
  mkSg2k,
  netbootSystem,
}:
let
  inherit (pkgs) lib;
  inherit (fixtures)
    devBundleSigner
    testFakeFip
    testSdImageGpt
    testStage0
    testStoreSquashfs
    ;
  shortArch = p: lib.head (lib.splitString "-" p);
  rauc-bundle-manifest = import ./rauc-bundle-manifest.nix { inherit pkgs; };
  # For the wlroots NV12 converter checks.
  pkgsPatched = pkgs.extend (import ../pkgs/v2/patches/overlay.nix { withPixman = false; });
in
if !(inputs.sophgone.packages.${system} ? uboot-sandbox) then
  throw ''
    checks.${system}.fit-sign: inputs.sophgone.packages.${system}.uboot-sandbox is
    missing. Bump the sophgone input to a revision with the sandbox U-Boot and
    pkgs/uboot-common/sg1-image.crt, or until then pass
    --override-input sophgone path:/path/to/sophgone.''
else
  {
    store-squashfs = pkgs.nix-badge-store-squashfs.passthru.tests.store-squashfs {
      storeImage = testStoreSquashfs;
      stage0s = testStage0;
    };
    store-squashfs-single-core = pkgs.nix-badge-store-squashfs.passthru.tests.store-squashfs {
      storeImage = fixtures.testStoreSquashfsSingleCore;
      stage0s = { inherit (testStage0) riscv; };
    };
    fit-sign = pkgs.nix-badge-fit-signing.passthru.tests.fit-sign;
    bundle-sign = pkgs.nix-badge-bundle-signing.passthru.tests.bundle-sign;
    # The generation image over the real badge1-arm system, plus signed mocks.
    boot-image = pkgs.nix-badge-boot-image.passthru.tests.boot-image {
      system =
        self.nixosConfigurations.${if system == "aarch64-linux" then "badge1-arm" else "badge1-arm-x86_64"};
    };
    boot-dir = pkgs.nix-badge-boot-dir.passthru.tests.boot-dir;
    dtb-licheerv-nano = import ./dtb-licheerv-nano.nix { inherit pkgs; };
    board-licheerv-nano-riscv = import ./board-licheerv-nano.nix {
      inherit pkgs;
      sys = self.nixosConfigurations."licheerv-nano-riscv-${shortArch system}";
    };
    board-licheerv-nano-arm = import ./board-licheerv-nano.nix {
      inherit pkgs;
      sys =
        self.nixosConfigurations.${
          if system == "aarch64-linux" then "licheerv-nano-arm" else "licheerv-nano-arm-x86_64"
        };
    };
    sd-image-gpt-single-core = testSdImageGpt.sd-image-gpt-single-core;
    oled-storage = import ./oled-storage.nix { inherit pkgs; };
    install-bootloader = import ./install-bootloader.nix {
      pkgs = pkgs;
    };
    # The desktop profile on both cores (evaluation plus a source grep).
    desktop-profile = import ./desktop-profile.nix {
      pkgs = pkgs;
      systems = {
        arm =
          self.nixosConfigurations.${if system == "aarch64-linux" then "badge1-arm" else "badge1-arm-x86_64"};
        riscv = self.nixosConfigurations."badge1-riscv-${shortArch system}";
      };
    };
    graphics-24bpp = import ./graphics-24bpp.nix { pkgs = pkgs; };
    desktop-dsi-panel = import ./desktop-dsi-panel.nix {
      inherit pkgs;
      sys = self.nixosConfigurations."licheerv-nano-riscv-${shortArch system}";
    };
    dtb-codec-resets = import ./dtb-codec-resets.nix {
      inherit pkgs;
      systems = {
        arm =
          self.nixosConfigurations.${if system == "aarch64-linux" then "badge1-arm" else "badge1-arm-x86_64"};
        riscv = self.nixosConfigurations."badge1-riscv-${shortArch system}";
      };
    };
    devmem-free = import ./devmem-free.nix {
      inherit pkgs;
      badgePkgs =
        self.nixosConfigurations.${
          if system == "aarch64-linux" then "badge1-arm" else "badge1-arm-x86_64"
        }.pkgs;
    };
    # The documentation site; its build checks every internal link.
    docs = packages.docs;
    external-storage-store = import ./external-storage-store.nix { inherit pkgs; };
    # nixosModules.v2, enabled and nothing else, is the sg2k-arm system.
    nixos-module-v2 =
      let
        sys = nixosSystem {
          modules = [
            self.nixosModules.v2
            {
              hardware.sg2k.enable = true;
              nixpkgs.buildPlatform = system;
            }
          ];
        };
        want =
          self.nixosConfigurations.${
            if system == "aarch64-linux" then "sg2k-arm" else "sg2k-arm-${shortArch system}"
          };
      in
      if sys.config.system.build.toplevel.drvPath == want.config.system.build.toplevel.drvPath then
        pkgs.runCommand "test-nixos-module-v2" { } "touch $out"
      else
        throw "nixos-module-v2: nixosModules.v2 with hardware.sg2k.enable is not the sg2k-arm system";
    # The BSP, imported but not enabled, changes nothing.
    sg2k-disabled = import ./sg2k-disabled.nix {
      pkgs = pkgs;
      inherit system;
      mkSystem = mods: nixosSystem { modules = [ self.nixosModules.v2 ] ++ mods; };
    };
    # The NV12 converter against a BT.601 reference; the aarch64 one checks NEON
    # against C byte for byte under qemu-user.
    wlroots-nv12-convert = pkgsPatched.wlroots-nv12-tests;
    wlroots-nv12-convert-aarch64 = pkgsPatched.pkgsCross.aarch64-multiplatform.wlroots-nv12-tests;
    nix-fixes-this-selftest = pkgs.nix-fixes-this.passthru.tests.selftest;
    nix-badge-unit = pkgs.pkgsCross.aarch64-multiplatform.nix-badge-noeval.tests.unit;
    # Plan-mode harnesses: fake inputs, no real devices touched.
    nix-badge-stage0 = pkgs.nix-badge-stage0.passthru.tests.plan;
    nix-badge-emmc-init = pkgs.nix-badge-emmc-init.passthru.tests.plan;
    nix-badge-install = pkgs.nix-badge-install.passthru.tests.install;
    nix-badge-emmc-update = pkgs.nix-badge-emmc-update.passthru.tests.update;
    nix-badge-storage-mode = pkgs.nix-badge-storage-mode.passthru.tests.mode;
    rauc-pre-install = pkgs.nix-badge-rauc-pre-install.passthru.tests.refuse;
    nix-badge-cache-gc = pkgs.nix-badge-cache-gc.passthru.tests.gc;
    nix-badge-card-boot-reset = pkgs.nix-badge-card-boot-reset.passthru.tests.reset;
    badapple2ipxe-clip = pkgs.badapple2ipxe.passthru.tests.clip;
    # The Bad Apple iPXE animation the netboot menu offers.
    nix-badge-netboot-badapple = pkgs.nix-badge-netboot-badapple;
    nix-badge-netboot-root = pkgs.nix-badge-netboot-root.passthru.tests.root;
    nix-badge-router-gateway = pkgs.nix-badge-router-gateway.passthru.tests.gateway;
    nix-badge-hostname = pkgs.nix-badge-hostname.passthru.tests.serial;
    nix-badge-stable-mac = pkgs.nix-badge-stable-mac.passthru.tests.mac;
    nix-badge-net-scan = pkgs.nix-badge-net-scan.passthru.tests.scan;
    nix-badge-grow-userdata = pkgs.nix-badge-grow-userdata.passthru.tests.grow;
    nix-badge-userdata-swap = pkgs.nix-badge-userdata-swap.passthru.tests.swap;
    nix-badge-make-data-card = pkgs.nix-badge-make-data-card.passthru.tests.convert;
    # Harmonia with the stream-through patch; its Rust tests run in the build.
    nix-badge-harmonia = pkgs.nix-badge-harmonia;
    sd-image-gpt = testSdImageGpt;
    rauc-bundle = fixtures.testRaucBundle;
    rauc-bundle-single-core = fixtures.testRaucBundleSingleCore;
    rauc-bundle-wrong-compatible = fixtures.testRaucBundleWrongCompatible;
    rauc-hook = pkgs.nix-badge-rauc-bundle.passthru.tests.rauc-hook;
    # RAUC installs in manifest order, so the fip must come last.
    rauc-bundle-manifest-order = rauc-bundle-manifest {
      name = "rauc-bundle-manifest-order";
      bundle = fixtures.testRaucBundle;
      compatible = "sg2k/nix-badge";
      sections = [
        "[image.boot]"
        "[image.nix]"
        "[image.fip]"
      ];
    };
    # Without an eMMC the fip rides in boot.tar.
    rauc-bundle-single-core-manifest = rauc-bundle-manifest {
      name = "rauc-bundle-single-core-manifest";
      bundle = fixtures.testRaucBundleSingleCore;
      compatible = "sg2k/licheerv-nano";
      sections = [
        "[image.boot]"
        "[image.nix]"
      ];
      bootTar = [
        "fip.bin"
        "riscv/boot.itb"
        "riscv/vbmeta.itb"
        "secure"
        "store.sha256"
      ];
    };
    rauc-bundle-markers =
      let
        signedArm = pkgs.runCommand "fake-boot-image-arm-signed" { } ''
          mkdir -p $out
          cp ${testSdImageGpt.fakeBootImages.arm}/boot.itb $out/boot.itb
          echo signed > $out/.secure
        '';
        failed = pkgs.testers.testBuildFailure (
          pkgs.nix-badge-rauc-bundle {
            name = "test-nix-badge-markers";
            version = "deadbeef";
            storeImage = testStoreSquashfs;
            bootImages = testSdImageGpt.fakeBootImages // {
              arm = signedArm;
            };
            fip = testFakeFip;
            signer = devBundleSigner;
            trustedCert = devBundleSigner.cert;
            compatible = "sg2k/nix-badge";
          }
        );
      in
      pkgs.runCommand "test-rauc-bundle-markers" { } ''
        [ "$(cat ${failed}/testBuildFailure.exit)" != 0 ]
        grep -qF 'make-bundle: secure markers disagree' ${failed}/testBuildFailure.log \
          || { cat ${failed}/testBuildFailure.log >&2; exit 1; }
        touch $out
      '';
  }
  # A card ships its host's fip and signs its images exactly when the chain is on;
  # evaluation only, one check per card.
  // lib.listToAttrs (
    map
      (
        prefix:
        lib.nameValuePair "sdcard-fip-${prefix}" (
          pkgs.nix-badge-sd-image-gpt.passthru.tests.sdcard-fip {
            cards.${prefix} = {
              image = packages."${prefix}-sdcard";
              arm =
                self.nixosConfigurations.${
                  if system == "aarch64-linux" then "${prefix}-arm" else "${prefix}-arm-x86_64"
                };
              riscv = self.nixosConfigurations."${prefix}-riscv-${shortArch system}";
            };
          }
        )
      )
      [
        "badge1"
        "badge1-secure"
        "licheerv-nano"
      ]
  )
  // import ./sg2k-scenarios.nix {
    inherit pkgs;
    mkSystem =
      mods:
      mkSg2k {
        board = "nix-badge";
        core = "riscv";
        buildPlatform = system;
        extraModules = mods;
      };
  }
  // {
    fip-variant-follows-option =
      let
        sysFor =
          base: self.nixosConfigurations.${if system == "aarch64-linux" then base else "${base}-x86_64"};
      in
      pkgs.nix-badge-fips.passthru.tests.fip-variant-follows-option {
        plain = sysFor "sg2k-arm";
        gpt = sysFor "badge1-arm";
        gptSecure = sysFor "badge1-secure-arm";
      };
  }
  // {
    # badge1 is deployed over its Ethernet, so that is its uplink.
    badge1-router-upstream =
      let
        wrong = lib.filter (n: self.nixosConfigurations.${n}.config.badge.router.upstream != "ethernet") [
          "badge1-riscv-${shortArch system}"
          "badge1-secure-riscv-${shortArch system}"
        ];
      in
      if wrong == [ ] then
        pkgs.runCommand "test-badge1-router-upstream" { } "touch $out"
      else
        throw "badge1-router-upstream: ${toString wrong} do not route out of Ethernet";
  }
  // lib.optionalAttrs (system == "x86_64-linux") {
    # The installer the badge netboots, built for x86_64.
    netboot-artifacts = import ./netboot-artifacts.nix {
      inherit pkgs netbootSystem;
      nixpkgsSource = inputs.nixpkgs-2605.outPath;
    };
    # The badge's binary cache in VMs, against two upstream caches and a LAN client.
    badge-cache = import ./badge-cache.nix {
      inherit pkgs;
      module = self.nixosModules.v2;
    };
    # The router and netboot in VMs, against an upstream, LAN clients and a PXE client.
    router-ipxe = import ./router-ipxe.nix {
      inherit pkgs;
      module = self.nixosModules.v2;
    };
  }
