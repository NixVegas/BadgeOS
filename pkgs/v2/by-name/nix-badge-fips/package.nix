# The sophgone FIPs. OpenSBI embeds its own device tree (sophgone pkgs/opensbi).
{
  lib,
  pkgs,
  callPackage,
  sophgone,
  autopenOverlay,
  nixpkcsOverlay,
}:
let
  makeFips =
    {
      # The U-Boot in both polyglots: the secure one (signed FITs only, the key nodes of
      # fitKeyCert) with the verified-boot chain on, else the plain one.
      secureUboot ? false,
      fitKeyCert ? null,
    }:
    let
      # The one benign polyglot, reused as the sign base and the exploit's chainload target.
      polyglot = callPackage sophgone.lib.fipPolyglot {
        inherit secureUboot fitKeyCert;
      };

      overflowBl2Polyglot = callPackage sophgone.lib.overflowBl2 { variant = "polyglot"; };

      # pkgs with the autopen + nixpkcs overlays, unless it has them already: extending a
      # cross pkgs.buildPackages does not re-splice.
      signPkgs = if pkgs ? autopen then pkgs else (pkgs.extend autopenOverlay).extend nixpkcsOverlay;

      # Deterministic per-serial firmware keys (SG1-0001 placeholder) for encrypted
      # boot: bl_ek encrypts the images, ldr_ek is the fused loader KEK.
      fwBlEk = signPkgs.callPackage sophgone.lib.deriveFwKey {
        domain = "SG1-FWENC-v1";
        serial = "SG1-0001";
        name = "sg1-bl-ek-SG1-0001";
      };
      fwLdrEk = signPkgs.callPackage sophgone.lib.deriveFwKey {
        domain = "SG1-LDRKEK-v1";
        serial = "SG1-0001";
        name = "sg1-ldr-ek-SG1-0001";
      };

      # The secure polyglot's FSBL verifies (SCS=01) or decrypts and verifies (SCS=02) its
      # second stage. The graft bases keep the stub polyglot: the exploit chainloads the
      # plaintext sophg.1, whose FSBL must not enforce secure boot.
      polyglotSecure = callPackage sophgone.lib.fipPolyglot {
        secureBoot = true;
        inherit secureUboot fitKeyCert;
      };
      signedFipPolyglotStub = signPkgs.callPackage sophgone.lib.signFip { fip = polyglot; };
      signedEncFipPolyglotStub = signPkgs.callPackage sophgone.lib.signFip {
        fip = polyglot;
        encrypt = true;
        blEk = fwBlEk;
        ldrEk = fwLdrEk;
      };
    in
    rec {
      # the real (benign) boot chain
      fipArm = callPackage sophgone.lib.fip { core = "arm"; };
      fipRiscv = callPackage sophgone.lib.fip { core = "riscv"; };
      fipPolyglot = polyglot;

      # the sophgone exploit: SD:/fip.bin (chainload) + SD:/sophg.1 (the FSBL it reopens)
      chainloadFip = callPackage sophgone.lib.chainloadFip { variant = "polyglot"; };
      sophg1 = polyglot;

      # TPM-signed (+ encrypted) polyglots with the secure FSBL; need the autopen daemon.
      signedFipPolyglot = signPkgs.callPackage sophgone.lib.signFip { fip = polyglotSecure; };
      signedEncFipPolyglot = signPkgs.callPackage sophgone.lib.signFip {
        fip = polyglotSecure;
        encrypt = true;
        blEk = fwBlEk;
        ldrEk = fwLdrEk;
      };

      # the locked-cart exploits: a genuine signed(+enc) stub polyglot with only the BL2
      # slot grafted to the plaintext overflow blob
      chainloadFipLockedSigned = callPackage sophgone.lib.graftFip {
        signedFip = signedFipPolyglotStub;
        overflowBl2 = overflowBl2Polyglot;
      };
      chainloadFipLockedEnc = callPackage sophgone.lib.graftFip {
        signedFip = signedEncFipPolyglotStub;
        overflowBl2 = overflowBl2Polyglot;
      };
    };
in
lib.setFunctionArgs makeFips (lib.functionArgs makeFips)
// {
  # Which fip and U-Boot each secure-boot setting ships.
  passthru.tests.fip-variant-follows-option =
    {
      plain,
      gpt,
      gptSecure,
    }:
    callPackage ./test.nix { inherit plain gpt gptSecure; };
}
