# Fakes the checks build on: two-core and riscv-only store images, stage-0s, a fip, fake
# boot images, the bundle signers, and small signed bundles.
{
  self,
  pkgs,
}:
let
  inherit (pkgs) lib;
  bundleSigning = pkgs.nix-badge-bundle-signing;

  # A store image reads only these of a system.
  fakeSystem = hostPlatformSystem: {
    config = {
      system.build.toplevel = pkgs.hello;
      nixpkgs.hostPlatform.system = hostPlatformSystem;
      nix.package = pkgs.nix;
    };
  };
in
rec {
  devBundleSigner = bundleSigning.devSigner pkgs.nix-badge-rauc-dev-keyring;

  # Signs with sg1-image through autopen, with the cert the host trusts.
  sg1ImageBundleSigner =
    host:
    let
      cert = self.nixosConfigurations.${host}.config.hardware.sg2k.fitKeyCert;
    in
    assert lib.assertMsg (
      cert != null
    ) "${host} has no hardware.sg2k.fitKeyCert to sign its bundles with";
    bundleSigning.autopenSigner { inherit cert; };

  testSdImageGpt = pkgs.nix-badge-sd-image-gpt.passthru.tests.sd-image-gpt;

  testStoreSquashfs = pkgs.nix-badge-store-squashfs {
    systems = [
      (fakeSystem "aarch64-linux")
      (fakeSystem "riscv64-linux")
    ];
    stage0s = testStage0;
  };

  testStoreSquashfsSingleCore = pkgs.nix-badge-store-squashfs {
    systems = [ (fakeSystem "riscv64-linux") ];
    stage0s = { inherit (testStage0) riscv; };
  };

  # The native stage-0 twice, the riscv one renamed so a swapped /init-<core> shows.
  testStage0 = {
    arm = pkgs.nix-badge-stage0;
    riscv = pkgs.nix-badge-stage0.overrideAttrs {
      name = "fake-riscv-nix-badge-stage0";
    };
  };

  # The bundle builder only checks the fip's size.
  testFakeFip = pkgs.runCommand "fake-fip" { } ''
    head -c 1024 /dev/zero > "$out"
  '';

  # A tiny bundle; its build runs `rauc info` against the keyring as a self-check.
  testRaucBundle = pkgs.nix-badge-rauc-bundle {
    name = "test-nix-badge";
    version = "deadbeef";
    storeImage = testStoreSquashfs;
    bootImages = testSdImageGpt.fakeBootImages;
    fip = testFakeFip;
    signer = devBundleSigner;
    trustedCert = devBundleSigner.cert;
    compatible = "sg2k/nix-badge";
  };

  # The one-core, eMMC-less shape: riscv only, the fip in boot.tar.
  testRaucBundleSingleCore = pkgs.nix-badge-rauc-bundle {
    name = "test-nix-badge-single-core";
    version = "deadbeef";
    storeImage = testStoreSquashfsSingleCore;
    bootImages = { inherit (testSdImageGpt.fakeBootImages) riscv; };
    fip = testFakeFip;
    fipInBoot = true;
    signer = devBundleSigner;
    trustedCert = devBundleSigner.cert;
    compatible = "sg2k/licheerv-nano";
  };

  # testRaucBundle with compatible = "wrong", signed with sg1-image (the autopen host), so a
  # badge refuses it only for the compatible mismatch.
  testRaucBundleWrongCompatible = pkgs.nix-badge-rauc-bundle {
    name = "test-nix-badge-wrong-compatible";
    version = "deadbeef";
    storeImage = testStoreSquashfs;
    bootImages = testSdImageGpt.fakeBootImages;
    fip = testFakeFip;
    signer = sg1ImageBundleSigner "badge1-arm-x86_64";
    compatible = "wrong";
    trustedCert =
      self.nixosConfigurations."badge1-arm-x86_64".config.services.rauc.settings.keyring.path;
    extraTrustedCerts = [
      self.nixosConfigurations."badge1-riscv-x86_64".config.services.rauc.settings.keyring.path
    ];
  };
}
