# A card ships what its hosts would deploy, decided at evaluation time: the image's fip
# is each host's activeFip kind over the same polyglot, and the boot images and slot
# vbmeta are signed exactly when the chain is on. Not the whole fip's drvPath: a deploy
# builds the signer from a cross pkgs.buildPackages, whose wrappers record the target's
# bash. A card forces two full NixOS systems in one evaluator (~7 GB): run it alone.
{
  lib,
  runCommand,
  cards,
}:
let
  signed = drv: lib.elem "autopen" (drv.requiredSystemFeatures or [ ]);
  # A signed fip is a directory wrapping the polyglot it signed; the plain fip is the
  # polyglot itself.
  polyglotOf = fip: (fip.fip or fip).drvPath;

  facts =
    card:
    let
      armFip = card.arm.config.system.build.activeFip;
      riscvFip = card.riscv.config.system.build.activeFip;
    in
    {
      chain = card.arm.config.hardware.sg2k.secureBoot;
      imageDrv = card.image.drvPath;
      fipName = card.image.fip.name;
      armActiveFipName = armFip.name;
      riscvActiveFipName = riscvFip.name;
      fipPolyglot = polyglotOf card.image.fip;
      armActiveFipPolyglot = polyglotOf armFip;
      riscvActiveFipPolyglot = polyglotOf riscvFip;
      fipDrv = card.image.fip.drvPath;
      armActiveFipDrv = armFip.drvPath;
      riscvActiveFipDrv = riscvFip.drvPath;
      armBootImageSigned = signed card.arm.config.system.build.bootImage;
      riscvBootImageSigned = signed card.riscv.config.system.build.bootImage;
      vbmetaSigned = signed card.image.storeImage.vbmeta;
    };

  expectationsFor = name: f: {
    "${name}: image fip is the arm host's kind" = f.fipName == f.armActiveFipName;
    "${name}: image fip is the riscv host's kind" = f.fipName == f.riscvActiveFipName;
    "${name}: image fip signs the arm host's polyglot" = f.fipPolyglot == f.armActiveFipPolyglot;
    "${name}: image fip signs the riscv host's polyglot" = f.fipPolyglot == f.riscvActiveFipPolyglot;
    "${name}: arm boot.itb signed iff the chain is on" = f.armBootImageSigned == f.chain;
    "${name}: riscv boot.itb signed iff the chain is on" = f.riscvBootImageSigned == f.chain;
    "${name}: vbmeta signed iff the chain is on" = f.vbmetaSigned == f.chain;
  };

  all = lib.mapAttrs (_: facts) cards;
  expectations = lib.concatMapAttrs expectationsFor all;
  failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) expectations);
  # The drvPaths are reported as text: without their string context, so this check
  # never depends on (and never builds or signs) the image or the fips it names.
  report = builtins.unsafeDiscardStringContext (
    lib.concatStringsSep "\n" (lib.mapAttrsToList (n: f: "${n}: ${builtins.toJSON f}") all)
  );
in
if failed != [ ] then
  throw ''
    sdcard-fip failed:
      ${lib.concatStringsSep "\n  " failed}
    facts:
    ${report}''
else
  runCommand "sdcard-fip" { inherit report; } ''
    printf '%s\n' "$report" > $out
  ''
