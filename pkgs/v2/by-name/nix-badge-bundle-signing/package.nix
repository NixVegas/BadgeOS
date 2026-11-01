# RAUC bundle signers and the post-sign verification. A signer is
# { cert, rauc, setup, key, drvAttrs }: `setup` runs before `rauc bundle`, and `drvAttrs`
# merge into the signing derivation.
{
  callPackage,
  runCommand,
  writeShellScript,
  coreutils,
  rauc,
  squashfsTools,
  # only autopenSigner needs it
  nix-badge-fit-signing,
}:
let
  fit = nix-badge-fit-signing;

  # The production signer: the key is reachable only through the autopen daemon, and
  # `rauc bundle` gets it as a PEM-encoded PKCS#11 provider URI.
  autopenSigner =
    {
      keyName ? "sg1-image",
      cert,
      certHash ? fit.sg1ImageCertHash,
      socketPath ? "/run/autopen/socket",
    }:
    let
      # A standalone store copy: the shim reads it (AUTOPEN_CERT) at sign time.
      certFile = builtins.path {
        path = cert;
        name = "${keyName}.crt";
      };
      remoteKey = fit.signPkgs.autopen.lib.signingKey.remote {
        name = keyName;
        verificationKey = fit.signPkgs.autopen.lib.verificationKey.fromCertificate {
          source = certFile;
          hash = certHash;
        };
        inherit socketPath;
      };
      provider = fit.mkProvider {
        inherit remoteKey;
        cert = certFile;
        label = keyName;
      };
    in
    {
      cert = certFile;
      inherit (provider) rauc;
      key = "key-uri.pem";
      setup = ''
        ${provider.openssl}/bin/openssl pkey -in 'pkcs11:object=${keyName};type=private' -out key-uri.pem
        head -n 1 key-uri.pem | grep -qx -- '-----BEGIN PKCS#11 PROVIDER URI-----' \
          || { echo "sign-bundle: provider URI export for ${keyName} failed" >&2; exit 1; }
      '';
      drvAttrs = {
        # Only a builder advertising `autopen` (the host whose daemon holds the key);
        # preferLocalBuild alone is overridden by --max-jobs 0.
        preferLocalBuild = true;
        requiredSystemFeatures = [ "autopen" ];
        allowSubstitutes = false;
        passthru = { inherit remoteKey; };
      };
    };

  # The checked-in dev keyring (nix-badge-rauc-dev-keyring), for test bundles.
  devSigner = keyring: {
    cert = "${keyring}/cert.pem";
    inherit rauc;
    key = "${keyring.key}/key.pem";
    setup = "";
    drvAttrs = { };
  };

  # verifier <cert> <bundle> [compatible]: `rauc info` with the badge's keyring settings.
  # Without check-purpose=codesign, OpenSSL's default purpose rejects a codeSigning EKU.
  verifier = writeShellScript "rauc-verify-bundle" ''
    set -euo pipefail
    cert=$1 bundle=$2 compatible=''${3:-nix-badge/sg2000}
    conf=$(${coreutils}/bin/mktemp)
    trap '${coreutils}/bin/rm -f "$conf"' EXIT
    printf '[system]\ncompatible=%s\nbootloader=uboot\n\n[keyring]\npath=%s\ncheck-purpose=codesign\n' \
      "$compatible" "$cert" > "$conf"
    ${rauc}/bin/rauc info --conf="$conf" "$bundle"
  '';

  # Sign a bundle content directory (manifest.raucm + images) and verify it.
  signBundle =
    {
      name,
      content,
      signer,
    }:
    runCommand "${name}.raucb"
      (
        {
          nativeBuildInputs = [ squashfsTools ];
        }
        // signer.drvAttrs
      )
      ''
        set -euo pipefail
        cp -r ${content} in
        chmod -R u+w in
        ${signer.setup}
        ${signer.rauc}/bin/rauc bundle --cert=${signer.cert} --key=${signer.key} in "$out"
        ${verifier} ${signer.cert} "$out" > info.txt 2>&1 \
          || { cat info.txt; echo "sign-bundle: $out does not verify against ${signer.cert}" >&2; exit 1; }
        cat info.txt
      '';
in
{
  inherit
    autopenSigner
    devSigner
    verifier
    signBundle
    ;
  passthru.tests.bundle-sign = callPackage ./test.nix { };
}
