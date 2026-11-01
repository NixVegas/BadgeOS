# The v2 packages (SD cards, bundles, tools and test fixtures) and checks, read from
# nixpkgs with the v2 overlay and from the configurations.
{
  self,
  inputs,
  v2,
  ...
}:
let
  inherit (inputs) nixpkgs-2605;
  inherit (v2)
    sg2kLib
    pkgsFor
    sdcardFor
    sg2kBuildSystems
    mkSg2k
    ;
in
{
  perSystem =
    { config, system, ... }:
    let
      # Every badgeOS artefact builds on this.
      pkgs = pkgsFor system;
      sophgoneFips = pkgs.nix-badge-fips { };

      # Fakes shared with the checks.
      fixtures = import ../../tests/fixtures.nix {
        inherit self pkgs;
      };
      inherit (fixtures) sg1ImageBundleSigner;

      # The SD cards, from the configurations.
      cards = {
        sg2k-sdcard = sdcardFor { buildSystem = system; };

        # badge1 is fused SCS=02, so its card carries the TPM-signed + encrypted polyglot;
        # the signing runs on the autopen host, so build locally.
        badge1-sdcard = sdcardFor {
          buildSystem = system;
          prefix = "badge1";
          secure = true;
        };

        # The verified-boot chain on: /secure = signed.
        badge1-secure-sdcard = sdcardFor {
          buildSystem = system;
          prefix = "badge1-secure";
          secure = true;
        };

        # Both cores, booting whichever the strap resistor selects, and a card for each.
        licheerv-nano-sdcard = sdcardFor {
          buildSystem = system;
          board = "licheerv-nano";
        };
        licheerv-nano-sdcard-arm = sdcardFor {
          buildSystem = system;
          board = "licheerv-nano";
          cores = [ "arm" ];
        };
        licheerv-nano-sdcard-riscv = sdcardFor {
          buildSystem = system;
          board = "licheerv-nano";
          cores = [ "riscv" ];
        };
      };
    in
    {
      packages = {
        default = cards.sg2k-sdcard;
        sg2k-sdcard = cards.sg2k-sdcard;
        badge1-sdcard = cards.badge1-sdcard;

        # The card's store image (~1.6 GB).
        badge1-store-squashfs = cards.badge1-sdcard.storeImage;
        badge1-secure-sdcard = cards.badge1-secure-sdcard;
        badge1-secure-store-squashfs = cards.badge1-secure-sdcard.storeImage;

        # Signed with sg1-image through autopen. trustedCert is the keyring path a real
        # badge1 config trusts, so a signer/keyring mismatch fails the build.
        badge1-bundle = pkgs.nix-badge-rauc-bundle {
          name = "nix-badge";
          version = builtins.substring 0 8 (baseNameOf cards.badge1-sdcard.storeImage.outPath);
          storeImage = cards.badge1-sdcard.storeImage;
          bootImages = cards.badge1-sdcard.bootImages;
          fip = "${cards.badge1-sdcard.bootDir}/fip.bin";

          # Builds only on the signing host.
          signer = sg1ImageBundleSigner "badge1-arm-x86_64";
          inherit (self.nixosConfigurations."badge1-arm-x86_64".config.hardware.sg2k.rauc) compatible;
          fipInBoot = !self.nixosConfigurations."badge1-arm-x86_64".config.hardware.sg2k.emmc.enable;
          trustedCert =
            self.nixosConfigurations."badge1-arm-x86_64".config.services.rauc.settings.keyring.path;
          extraTrustedCerts = [
            self.nixosConfigurations."badge1-riscv-x86_64".config.services.rauc.settings.keyring.path
          ];
        };

        # badge1-bundle for the verified-boot card: everything signed, so it installs only
        # onto a signed card.
        badge1-secure-bundle = pkgs.nix-badge-rauc-bundle {
          name = "nix-badge-secure";
          version = builtins.substring 0 8 (baseNameOf cards.badge1-secure-sdcard.storeImage.outPath);
          storeImage = cards.badge1-secure-sdcard.storeImage;
          bootImages = cards.badge1-secure-sdcard.bootImages;
          fip = "${cards.badge1-secure-sdcard.bootDir}/fip.bin";
          signer = sg1ImageBundleSigner "badge1-secure-arm-x86_64";
          inherit (self.nixosConfigurations."badge1-secure-arm-x86_64".config.hardware.sg2k.rauc) compatible;
          fipInBoot = !self.nixosConfigurations."badge1-secure-arm-x86_64".config.hardware.sg2k.emmc.enable;
          trustedCert =
            self.nixosConfigurations."badge1-secure-arm-x86_64".config.services.rauc.settings.keyring.path;
          extraTrustedCerts = [
            self.nixosConfigurations."badge1-secure-riscv-x86_64".config.services.rauc.settings.keyring.path
          ];
        };
        licheerv-nano-sdcard = cards.licheerv-nano-sdcard;
        licheerv-nano-sdcard-arm = cards.licheerv-nano-sdcard-arm;
        licheerv-nano-sdcard-riscv = cards.licheerv-nano-sdcard-riscv;

        # The two-core card's update, so a board on either strap keeps booting; on a
        # one-core card it installs both cores. The Nano has no eMMC: its fip rides in
        # boot.tar.
        licheerv-nano-bundle =
          let
            sys = self.nixosConfigurations."licheerv-nano-riscv-x86_64";
          in
          pkgs.nix-badge-rauc-bundle {
            name = "licheerv-nano";
            version = builtins.substring 0 8 (baseNameOf cards.licheerv-nano-sdcard.storeImage.outPath);
            storeImage = cards.licheerv-nano-sdcard.storeImage;
            bootImages = cards.licheerv-nano-sdcard.bootImages;
            fip = cards.licheerv-nano-sdcard.fip;
            fipInBoot = !sys.config.hardware.sg2k.emmc.enable;
            signer = sg1ImageBundleSigner "licheerv-nano-riscv-x86_64";
            inherit (sys.config.hardware.sg2k.rauc) compatible;
            trustedCert = sys.config.services.rauc.settings.keyring.path;
            extraTrustedCerts = [
              self.nixosConfigurations."licheerv-nano-arm-x86_64".config.services.rauc.settings.keyring.path
            ];
          };

        # OpenOCD with the CH347 driver, for JTAG over the badge's J1 port.
        openocd-ch347 = pkgs.openocd-ch347;

        # The LT8912B bring-up module, loaded by hand (site/src/hdmi.md).
        lt8912b-bringup = self.nixosConfigurations."badge1-arm-x86_64".pkgs.lt8912b-bringup.override {
          kernel = self.nixosConfigurations."badge1-arm-x86_64".config.boot.kernelPackages.kernel;
        };

        # The vendor display stack forward-ported onto the badge kernel.
        soph-display = self.nixosConfigurations."badge1-arm-x86_64".pkgs.soph-display.override {
          kernel = self.nixosConfigurations."badge1-arm-x86_64".config.boot.kernelPackages.kernel;
        };
        soph-display-riscv = self.nixosConfigurations."badge1-riscv-x86_64".pkgs.soph-display.override {
          kernel = self.nixosConfigurations."badge1-riscv-x86_64".config.boot.kernelPackages.kernel;
        };

        # H.264 clips on HDMI through the vendor VDEC -> VO path; USER advances.
        nix-badge-video = self.nixosConfigurations."badge1-arm-x86_64".pkgs.nix-badge-video;

        # The documentation site (site/), with the options nixosModules.v2 declares.
        docs = import ../../site {
          inherit pkgs;
          modules = [ self.nixosModules.v2 ];
          specialArgs = { inherit inputs; };
          version = v2.badgeVersion;
          nixosLabel = sg2kLib.version;
        };

        # The LicheeRV Nano's fips: the polyglot, and each core's own (FSBL, monitor and
        # U-Boot as passthru).
        licheerv-nano-fip = pkgs.sg2k-fips-licheerv-nano.fipPolyglot;
        licheerv-nano-fip-arm = pkgs.sg2k-fips-licheerv-nano.fipArm;
        licheerv-nano-fip-riscv = pkgs.sg2k-fips-licheerv-nano.fipRiscv;

        # The sophgone chainloader (SD:/fip.bin) and the polyglot it boots (SD:/sophg.1).
        sophgone-fip = sophgoneFips.chainloadFip;
        sophgone-sophg1 = sophgoneFips.sophg1;

        # The signed fips need the autopen daemon.
        sophgone-unsigned = sophgoneFips.fipPolyglot;
        sophgone-signed = sophgoneFips.signedFipPolyglot;
        sophgone-signed-enc = sophgoneFips.signedEncFipPolyglot;
        sophgone-exploit-signed = sophgoneFips.chainloadFipLockedSigned;
        sophgone-exploit-signed-enc = sophgoneFips.chainloadFipLockedEnc;
        fix = (pkgs.extend (import inputs.fix { }).overlay).fix;

        # Build-time Nix content baked by fix.
        bling-demo = pkgs.nix-badge-bling-demo {
          fix = (pkgs.extend (import inputs.fix { }).overlay).fix;
        };
        bling-leds-demo = pkgs.nix-badge-bling-demo {
          fix = (pkgs.extend (import inputs.fix { }).overlay).fix;
          entry = "leds-demo.nix";
          name = "bling-leds-demo";
        };
        bling-badapple-live = pkgs.buildPackages.nix-badge-bling-badapple-live { };

        # RAUC cross-built for both badge arches.
        rauc-aarch64 = (pkgsFor "x86_64-linux").pkgsCross.aarch64-multiplatform.rauc;
        rauc-riscv64 = (pkgsFor "x86_64-linux").pkgsCross.riscv64.rauc;
      }
      // sg2kLib.optionalAttrs (system == "x86_64-linux") {
        # What the badge serves of the Nix Vegas installer (x86_64).
        inherit (v2) netboot;
      };

      checks = sg2kLib.optionalAttrs (sg2kLib.elem system sg2kBuildSystems) (
        import ../../tests {
          inherit
            self
            inputs
            system
            pkgs
            fixtures
            mkSg2k
            ;
          packages = config.packages;
          nixosSystem = nixpkgs-2605.lib.nixosSystem;
          inherit (v2) netbootSystem;
        }
      );
    };
}
