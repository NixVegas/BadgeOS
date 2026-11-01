# The offline stand-in for the production signer: a SoftHSM token with the throwaway key
# in ./test-key and an autopen daemon started inside the signing build. Not autopen's
# software keys: their backend needs a CPU feature some build hosts lack.
# Pass `cert`, `certHash` and `socketPath` to signFit, then wrap it in `withTestDaemon`.
{
  runCommand,
  softhsm,
  opensc,
  openssl,
  # the nix-badge-fit-signing toolkit (for signPkgs.autopen)
  fit,
}:
let

  # Fixed: the remote key bakes the socket path in at eval time, and /build is the
  # sandbox's build directory.
  socketPath = "/build/autopen.sock";
  cert = ./test-key/sg1-image-test.crt;
  # The same key in a codeSigning-only certificate, as RAUC wants it.
  codesignCert = ./test-key/sg1-image-test-codesign.crt;
  # SRI hash of autopen's verification key for this certificate (see package.nix).
  certHash = "sha256-QzonoQ9ByWRdrw4MTlf6K4I/NxFfDAr6ZpW/8WtqMKk=";

  # The SoftHSM token with the test key under label sg1-image, id 01 (what the
  # daemon's --hardware-key URI names).
  token =
    runCommand "fit-sign-test-token"
      {
        nativeBuildInputs = [
          softhsm
          opensc
          openssl
        ];
      }
      ''
        mkdir -p $out/tokens
        export SOFTHSM2_CONF=$PWD/softhsm2.conf
        printf 'directories.tokendir = %s\nobjectstore.backend = file\nlog.level = ERROR\n' \
          "$out/tokens" > "$SOFTHSM2_CONF"
        softhsm2-util --init-token --free --label fittest --pin 1234 --so-pin 1234
        openssl pkcs8 -topk8 -nocrypt -in ${./test-key/sg1-image-test.key} -outform DER -out key.p8
        openssl x509 -in ${cert} -outform DER -out cert.der
        openssl x509 -in ${cert} -pubkey -noout | openssl pkey -pubin -outform DER -out pub.der
        mod=${softhsm}/lib/softhsm/libsofthsm2.so
        for o in "key.p8 privkey" "cert.der cert" "pub.der pubkey"; do
          set -- $o
          pkcs11-tool --module $mod --login --pin 1234 --write-object $1 --type $2 \
            --label sg1-image --id 01
        done
      '';

  # Start the test daemon in front of the token, inside the signing build.
  startDaemon = remoteKey: ''
    cp -r ${token}/tokens tokens
    chmod -R u+w tokens
    export SOFTHSM2_CONF=$PWD/softhsm2.conf
    printf 'directories.tokendir = %s\nobjectstore.backend = file\nlog.level = ERROR\n' \
      "$PWD/tokens" > "$SOFTHSM2_CONF"
    printf 1234 > pin
    autopen serve --socket-path ${socketPath} \
      --hardware-key "pkcs11:token=fittest;id=%01;object=sg1-image;type=private?module-path=${softhsm}/lib/softhsm/libsofthsm2.so&pin-source=file:$PWD/pin" \
      ${remoteKey.fileRefPath} 2> autopen.log &
    autopen_pid=$!
    for _ in $(seq 1 100); do [ -S ${socketPath} ] && break; sleep 0.1; done
    [ -S ${socketPath} ] || { cat autopen.log; exit 1; }
  '';

  # A secure signFit build against the in-build test daemon.
  withTestDaemon =
    raw:
    raw.overrideAttrs (old: {
      # The test daemon stands in for the TPM host: no `autopen` feature needed.
      requiredSystemFeatures = [ ];
      nativeBuildInputs = old.nativeBuildInputs ++ [ fit.signPkgs.autopen ];
      buildCommand =
        startDaemon raw.remoteKey
        + old.buildCommand
        + ''
          # the shim reached the test daemon (the key exists only in its token)
          grep -q "New connection" autopen.log || { cat autopen.log; exit 1; }
          kill $autopen_pid
        '';
    });
in
{
  inherit
    socketPath
    cert
    codesignCert
    certHash
    withTestDaemon
    ;
}
