# The fip and the U-Boot in it follow the two secure-boot options: firmware.secureBoot
# picks the signed fip, hardware.sg2k.secureBoot (the chain) the secure U-Boot and a signed
# generation image. Decided at evaluation time from derivation names; nothing is built.
# It evaluates three full NixOS systems in one evaluator: run it alone.
{
  lib,
  runCommand,
  plain,
  gpt,
  gptSecure,
}:
let

  facts =
    sys:
    let
      cfg = sys.config;
      fip = cfg.system.build.activeFip;
      # A signed fip is a directory wrapping the polyglot it signed; the plain fip
      # is the polyglot itself.
      polyglot = fip.fip or fip;
    in
    {
      fipName = fip.name;
      ubootPname = polyglot.armUboot.pname;
      riscvUbootPname = polyglot.riscvUboot.pname;
      chain = cfg.hardware.sg2k.secureBoot;
      signedFip = cfg.hardware.sg2k.firmware.secureBoot;
      # signFit: only a signing build requires the `autopen` builder feature.
      signedBootImage = lib.elem "autopen" (cfg.system.build.bootImage.requiredSystemFeatures or [ ]);
    };

  p = facts plain;
  g = facts gpt;
  s = facts gptSecure;

  expectations = {
    "plain: fip is the unsigned polyglot" =
      lib.hasInfix "fip-polyglot" p.fipName && !lib.hasInfix "signed" p.fipName;
    "plain: plain U-Boot" = !lib.hasSuffix "-secure" p.ubootPname;
    "plain: plain riscv U-Boot" = !lib.hasSuffix "-secure" p.riscvUbootPname;
    "plain: chain and signed fip off" = !p.chain && !p.signedFip && !p.signedBootImage;

    "badge1: signed fip" = lib.hasInfix "fip-signed" g.fipName;
    "badge1: plain U-Boot (still boots extlinux)" = !lib.hasSuffix "-secure" g.ubootPname;
    "badge1: plain riscv U-Boot" = !lib.hasSuffix "-secure" g.riscvUbootPname;
    "badge1: firmware.secureBoot on, chain off" = g.signedFip && !g.chain;
    "badge1: generation image unsigned" = !g.signedBootImage;

    "badge1-secure: signed fip" = lib.hasInfix "fip-signed" s.fipName;
    "badge1-secure: secure U-Boot" = lib.hasSuffix "-secure" s.ubootPname;
    "badge1-secure: secure riscv U-Boot" = lib.hasSuffix "-secure" s.riscvUbootPname;
    "badge1-secure: chain on and signed fip on" = s.chain && s.signedFip;
    "badge1-secure: generation image signed" = s.signedBootImage;
  };

  failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) expectations);
  report = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (n: f: "${n}: ${builtins.toJSON f}") {
      plain = p;
      badge1 = g;
      badge1-secure = s;
    }
  );
in
if failed != [ ] then
  throw ''
    fip-variant-follows-option failed:
      ${lib.concatStringsSep "\n  " failed}
    facts:
    ${report}''
else
  runCommand "fip-variant-follows-option" { inherit report; } ''
    printf '%s\n' "$report" > $out
  ''
