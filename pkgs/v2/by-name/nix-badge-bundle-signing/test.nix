# autopenSigner offline, through nix-badge-fit-signing's test daemon and scratch key. The
# cert is a code-signing leaf for that key: the FIT test cert (a CA without EKU) fails
# check-purpose=codesign. The verifier must refuse the dev and FIT test certs.
{
  runCommand,
  nix-badge-fit-signing,
  nix-badge-bundle-signing,
  nix-badge-rauc-dev-keyring,
}:
let
  daemon = nix-badge-fit-signing.passthru.testDaemon;
  signing = nix-badge-bundle-signing;

  cert = daemon.codesignCert;
  devKeyring = nix-badge-rauc-dev-keyring;

  content = runCommand "bundle-sign-test-content" { } ''
    mkdir $out
    head -c 65536 /dev/urandom > $out/payload.img
    cat > $out/manifest.raucm <<EOF
    [update]
    compatible=nix-badge/sg2000
    version=bundle-sign-test

    [bundle]
    format=verity

    [image.nix]
    filename=payload.img
    EOF
  '';

  signed = daemon.withTestDaemon (
    signing.signBundle {
      name = "bundle-sign-test";
      inherit content;
      signer = signing.autopenSigner {
        inherit cert;
        inherit (daemon) certHash socketPath;
      };
    }
  );
in
runCommand "bundle-sign-test" { preferLocalBuild = true; } ''
  set -euo pipefail
  fail() { echo "FAIL: $*" >&2; exit 1; }
  mkdir $out

  ${signing.verifier} ${cert} ${signed} > $out/verify.log 2>&1 \
    || { cat $out/verify.log; fail "the signed bundle does not verify against the test cert"; }
  grep -q 'Compatible:.*nix-badge/sg2000' $out/verify.log || { cat $out/verify.log; fail "no Compatible line"; }
  grep -qF 'nix-badge RAUC signer TEST cert' $out/verify.log \
    || { cat $out/verify.log; fail "the signer is not the test cert"; }

  for other in ${devKeyring}/cert.pem ${daemon.cert}; do
    name=$(basename "$other")
    if ${signing.verifier} "$other" ${signed} > "$out/refuse-$name.log" 2>&1; then
      cat "$out/refuse-$name.log"; fail "the bundle verified against $other"
    fi
    grep -qF 'signature verification failed' "$out/refuse-$name.log" \
      || { cat "$out/refuse-$name.log"; fail "no signature failure against $other"; }
  done

  cat $out/verify.log $out/refuse-*.log
''
