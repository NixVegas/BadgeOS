# The boot firmware: the fip the BootROM boots, picked from the board's fips by the
# secure-boot settings, the recovery fip kept beside it, and the key the verified-boot
# chain trusts. deploy.nix writes the fips picked here.
{
  config,
  lib,
  pkgs,
  sophgone,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.hardware.sg2k;

  core = cfg.core;
  fips = cfg.firmware.fips;

  # A one-core board boots its core's own fip; two cores boot the polyglot.
  dualCore = lib.length cfg.cores > 1;
  coreFip = if core == "arm" then fips.fipArm else fips.fipRiscv;
  secureBoot = cfg.firmware.secureBoot;
  encryptedBoot = cfg.firmware.encryptedBoot;

  # Throws, not only the assertions below: the fip is forced before assertions are checked.
  activeFip =
    if cfg.secureBoot && !secureBoot then
      throw "hardware.sg2k.secureBoot requires hardware.sg2k.firmware.secureBoot"
    else if encryptedBoot && !secureBoot then
      throw "hardware.sg2k.firmware.encryptedBoot requires secureBoot"
    else if (secureBoot || encryptedBoot) && !(pkgs.buildPackages ? autopen) then
      throw "hardware.sg2k.firmware.secureBoot needs the autopen and nixpkcs overlays in nixpkgs.overlays"
    else if !dualCore then
      if secureBoot then
        throw "hardware.sg2k.firmware.secureBoot needs a two-core board: the signed fip is the polyglot"
      else
        coreFip
    else if encryptedBoot then
      fips.signedEncFipPolyglot
    else if secureBoot then
      fips.signedFipPolyglot
    else
      fips.fipPolyglot;
in
{
  options.hardware.sg2k = {
    secureBoot = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Boot through the verified-boot chain: the secure U-Boot in the fip (signed
        FITs only, trusting hardware.sg2k.fitKeyCert) and a generation image and slot
        vbmeta images signed with the sg1-image key. Implies
        hardware.sg2k.firmware.secureBoot. The signing needs the autopen daemon socket
        at build time.
      '';
    };

    fitKeyCert = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        PEM certificate of the sg1-image key, which signs the generation image and
        which the secure U-Boot trusts. Required with secureBoot. When set it is also
        the RAUC keyring.
      '';
    };

    firmware = {
      fips = mkOption {
        type = types.raw;
        internal = true;
        description = "The board's fip images (the boot firmware), as built packages.";
      };

      # Separate from secureBoot: a fused badge with the chain off still needs a signed fip.
      secureBoot = mkOption {
        type = types.bool;
        default = config.hardware.sg2k.secureBoot;
        defaultText = lib.literalExpression "config.hardware.sg2k.secureBoot";
        description = ''
          Install the TPM-signed polyglot as the active fip, for a badge whose SCS fuses
          are burned (its mask ROM verifies the RSA chain, and an unsigned fip halts at
          `E:verify root (-14)`). Also drops the unsigned /boot/fip-<core>.bin recovery
          blob, which cannot boot there. The signing needs the autopen daemon socket at
          build time.
        '';
      };

      encryptedBoot = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Additionally AES-encrypt the images in the active fip (implies secureBoot), for a
          badge fused to SCS=02.
        '';
      };

      fipPath = mkOption {
        type = types.str;
        default = "/boot/fip.bin";
        example = "/boot/sophg.1";
        description = ''
          Absolute path, on the badge's FAT boot partition, that a deploy writes the
          active polyglot fip to.

          The default is the file the BootROM itself loads, which is what an ordinary
          badge wants: every deploy refreshes the firmware in place.

          Set it to a different file on a sophgone exploit target. There /boot/fip.bin
          holds the grafted fip.
        '';
      };

      activeFipFile = mkOption {
        type = types.str;
        internal = true;
        readOnly = true;
        description = "The fip file the BootROM boots, which a deploy writes to fipPath.";
      };

      recoveryFip = mkOption {
        type = types.nullOr types.package;
        internal = true;
        readOnly = true;
        description = ''
          This core's own fip, which a deploy keeps on /boot as the way back from the
          other core; null for none.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Update bundles and FIT images are signed with the sg1-image key.
    hardware.sg2k.fitKeyCert = lib.mkDefault "${sophgone}/pkgs/uboot-common/sg1-image.crt";

    assertions = [
      {
        assertion = cfg.secureBoot -> secureBoot;
        message = "hardware.sg2k.secureBoot requires hardware.sg2k.firmware.secureBoot";
      }
      {
        assertion = cfg.secureBoot -> cfg.fitKeyCert != null;
        message = "hardware.sg2k.secureBoot requires hardware.sg2k.fitKeyCert";
      }
      {
        assertion = encryptedBoot -> secureBoot;
        message = "hardware.sg2k.firmware.encryptedBoot requires secureBoot";
      }
      {
        assertion = secureBoot -> cfg.soc == "sg2000";
        message = "hardware.sg2k.firmware.secureBoot is only supported on the SG2000";
      }
    ];

    hardware.sg2k.firmware = {
      activeFipFile = if secureBoot || encryptedBoot then "${activeFip}/fip.bin" else "${activeFip}";
      # The other core's way back: unsigned, so a fused badge cannot boot it.
      recoveryFip = if dualCore && !secureBoot then coreFip else null;
    };

    # For the check that the fip follows hardware.sg2k.firmware.secureBoot.
    system.build.activeFip = activeFip;
  };
}
