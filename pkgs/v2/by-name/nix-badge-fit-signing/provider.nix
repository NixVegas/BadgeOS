# Tools whose libcrypto loads pkcs11-provider in front of the autopen PKCS#11 shim, for
# keys behind the autopen daemon. They get the key as a PEM-encoded provider URI: libp11's
# engine fails on an attribute the shim does not implement ("Attribute type invalid").
#
# (signPkgs.callPackage ./provider.nix { }) { remoteKey, cert, label }
#   -> { openssl, mkimage, rauc, wrap }
{
  openssl,
  autopen,
  ubootTools,
  rauc,
}:
{
  remoteKey,
  cert,
  label,
}:
let
  wrap' =
    extra:
    openssl.withPkcs11Module (
      {
        pkcs11Module = autopen.pkcs11Module;
        moduleEnv = { inherit remoteKey cert label; };
      }
      // extra
    );
  wrap = package: wrap' { inherit package; };
in
{
  inherit wrap;
  # openssl exports the provider-URI PEM.
  openssl = wrap' { };
  # mkimage (and the rest of ubootTools) signs with that PEM as `-G`.
  mkimage = wrap ubootTools;
  # rauc signs with that PEM as `--key`.
  rauc = wrap rauc;
}
