# Dev signing identity for RAUC bundles, for test bundles and hosts without
# hardware.sg2k.fitKeyCert. The cert is reproducible: fixed validity and a fixed serial
# (`openssl req -x509` picks a random one). The key is a separate output, so it never
# lands in a badge's closure.
{ runCommand, openssl }:
runCommand "nix-badge-rauc-dev-keyring"
  {
    keyFile = ./dev-key.pem;
    nativeBuildInputs = [ openssl ];
    outputs = [
      "out"
      "key"
    ];
  }
  ''
    mkdir -p $out "$key"
    openssl req -x509 -key "$keyFile" -out $out/cert.pem \
      -not_before 20260101000000Z -not_after 20360101000000Z \
      -set_serial 0x01 \
      -addext subjectKeyIdentifier=hash \
      -addext authorityKeyIdentifier=keyid:always,issuer:always \
      -addext basicConstraints=CA:FALSE \
      -addext extendedKeyUsage=critical,codeSigning \
      -subj "/OU=nix-badge dev/OU=RAUC/CN=nix-badge dev signer/"
    cp "$keyFile" "$key"/key.pem
  ''
