# signFit / verifyFit offline through ./test-daemon.nix: a signed FIT verifies, a flipped
# kernel byte does not, the guard rejects unsigned and value-less signature nodes, and a
# script-only FIT verifies in `source` mode.
{
  lib,
  runCommand,
  dtc,
  python3,
  nix-badge-fit-signing,
}:
let
  fit = nix-badge-fit-signing;

  daemon = fit.passthru.testDaemon;
  inherit (daemon)
    socketPath
    cert
    certHash
    withTestDaemon
    ;

  inputs = runCommand "fit-sign-test-inputs" { nativeBuildInputs = [ dtc ]; } ''
    mkdir $out
    head -c 65536 /dev/urandom > $out/kernel.bin
    echo '/dts-v1/; / { model = "fit-sign-test"; };' | dtc -I dts -O dtb -o $out/fdt-default.dtb
    printf 'echo fit-sign-test' > $out/script-default.txt
    printf 'setenv verityargs fit-sign-test' > $out/frag.txt
  '';

  # One kernel, one fdt, one script, one configuration; arch arm64 like the real
  # boot.itb.
  mkIts =
    secure:
    let
      imgSig = lib.optionalString secure ''
        signature-1 { algo = "sha256,rsa2048"; key-name-hint = "sg1-image-img"; };
      '';
      image = name: file: attrs: ''
        ${name} {
          data = /incbin/("${file}");
          ${attrs}
          compression = "none";
          hash-1 { algo = "sha256"; };
          ${imgSig}
        };
      '';
    in
    ''
      /dts-v1/;
      / {
        description = "signFit test";
        #address-cells = <1>;
        images {
          ${image "kernel" "kernel.bin" ''
            type = "kernel"; arch = "arm64"; os = "linux";
            load = <0x81000000>; entry = <0x81000000>;
          ''}
          ${image "fdt-default" "fdt-default.dtb" ''type = "flat_dt"; arch = "arm64";''}
          ${image "script-default" "script-default.txt" ''type = "script";''}
        };
        configurations {
          default = "conf-default";
          conf-default {
            kernel = "kernel";
            fdt = "fdt-default";
            ${lib.optionalString secure ''
              signature-1 {
                algo = "sha256,rsa2048";
                key-name-hint = "sg1-image";
                sign-images = "kernel", "fdt";
              };
            ''}
          };
        };
      };
    '';

  fitInputs = map (f: "${inputs}/${f}") [
    "kernel.bin"
    "fdt-default.dtb"
    "script-default.txt"
  ];

  # The vbmeta shape: one script image, an empty /configurations (mkimage wants the
  # node).
  mkScriptIts = secure: ''
    /dts-v1/;
    / {
      description = "signFit script-only test";
      #address-cells = <1>;
      images {
        frag {
          data = /incbin/("frag.txt");
          type = "script";
          compression = "none";
          hash-1 { algo = "sha256"; };
          ${lib.optionalString secure ''
            signature-1 { algo = "sha256,rsa2048"; key-name-hint = "sg1-image-img"; };
          ''}
        };
      };
      configurations { };
    };
  '';

  signed = withTestDaemon (
    fit.signFit {
      name = "test";
      its = mkIts true;
      inputs = fitInputs;
      secure = true;
      inherit cert certHash socketPath;
    }
  );

  scriptSigned = withTestDaemon (
    fit.signFit {
      name = "vbmeta";
      its = mkScriptIts true;
      inputs = [ "${inputs}/frag.txt" ];
      secure = true;
      requireConfigurations = false;
      inherit cert certHash socketPath;
    }
  );

  scriptPlain = fit.signFit {
    name = "vbmeta";
    its = mkScriptIts false;
    inputs = [ "${inputs}/frag.txt" ];
    secure = false;
    requireConfigurations = false;
  };

  scriptVerified = fit.verifyFit {
    itb = "${scriptSigned}/vbmeta.itb";
    inherit cert;
    mode = "source";
  };

  plain = fit.signFit {
    name = "test";
    its = mkIts false;
    inputs = fitInputs;
    secure = false;
  };

  # mkimage's silent-failure shape: the secure .its run through `mkimage -f` with no
  # key material leaves every signature-1 node in place WITHOUT a value (rc 0).
  sigNodesNoValue = fit.signFit {
    name = "test";
    its = mkIts true;
    inputs = fitInputs;
    secure = false;
  };

  verified = fit.verifyFit {
    itb = "${signed}/test.itb";
    inherit cert;
  };
in
runCommand "fit-sign-test"
  {
    nativeBuildInputs = [
      dtc
      python3
    ];
    preferLocalBuild = true;
  }
  ''
    set -euo pipefail
    fail() { echo "FAIL: $*" >&2; exit 1; }

    # secure: marker, signature values, sandbox verification
    [ "$(cat ${signed}/.secure)" = signed ] || fail "signed .secure is not 'signed'"
    for n in /configurations/conf-default /images/kernel /images/fdt-default /images/script-default; do
      fdtget -t bx ${signed}/test.itb $n/signature-1 value > /dev/null || fail "$n has no signature value"
    done
    grep -qF 'sha256,rsa2048:sg1-image+ OK' ${verified}/verify.log || fail "verifyFit log lacks the conf OK line"

    # tamper: one kernel byte flipped after signing
    cp ${signed}/test.itb flipped.itb
    chmod u+w flipped.itb
    python3 - <<'PY'
    data = bytearray(open("flipped.itb", "rb").read())
    kernel = open("${inputs}/kernel.bin", "rb").read()
    off = data.find(kernel[:64])
    assert off > 0 and data.find(kernel[:64], off + 1) < 0, off
    data[off + 4096] ^= 0x01
    open("flipped.itb", "wb").write(data)
    PY
    if ${fit.verifier} ${fit.fitKeyDtb cert}/control.dtb flipped.itb > flipped.log 2>&1; then
      cat flipped.log; fail "a flipped kernel byte verified"
    fi
    grep -qF 'Bad Data Hash' flipped.log || { cat flipped.log; fail "no 'Bad Data Hash' for the flipped copy"; }

    # the silent-failure guard rejects an unsigned FIT
    if ${fit.sigGuard} ${plain}/test.itb > guard.log 2>&1; then
      fail "the signature guard accepted an unsigned FIT"
    fi

    # the guard rejects mkimage's real silent-failure shape: signature-1 present,
    # no value
    sv=${sigNodesNoValue}/test.itb
    fdtget -l $sv /configurations/conf-default | grep -qx signature-1 \
      || fail "the silent-failure fixture lacks its signature-1 node"
    if fdtget -t bx $sv /configurations/conf-default/signature-1 value > /dev/null 2>&1; then
      fail "the silent-failure fixture has a signature value"
    fi
    if ${fit.sigGuard} $sv > guard-novalue.log 2>&1; then
      fail "the signature guard accepted signature nodes without values"
    fi
    grep -qF 'fit-sig-guard: /configurations/conf-default has no signature-1 value' guard-novalue.log \
      || { cat guard-novalue.log; fail "the guard did not name the unsigned configuration"; }

    # plain: marker, no signature nodes anywhere
    [ "$(cat ${plain}/.secure)" = unsigned ] || fail "plain .secure is not 'unsigned'"
    for n in /configurations/conf-default /images/kernel /images/fdt-default /images/script-default; do
      if fdtget -l ${plain}/test.itb $n | grep -q signature; then fail "plain $n has a signature node"; fi
    done

    # script-only: signed frag, verified by `source` with the image key
    [ "$(cat ${scriptSigned}/.secure)" = signed ] || fail "script-only .secure is not 'signed'"
    fdtget -t bx ${scriptSigned}/vbmeta.itb /images/frag/signature-1 value > /dev/null \
      || fail "script-only frag has no signature value"
    grep -qE 'sha256,rsa2048:sg1-image-img\+( |$)' ${scriptVerified}/verify.log \
      || { cat ${scriptVerified}/verify.log; fail "verifyFit source mode lacks the image OK line"; }
    if ${fit.sigGuard} ${scriptPlain}/vbmeta.itb images-only > guard-script.log 2>&1; then
      fail "the images-only guard accepted an unsigned script FIT"
    fi
    grep -qF 'fit-sig-guard: /images/frag has no signature-1 value' guard-script.log \
      || { cat guard-script.log; fail "the images-only guard did not name the unsigned frag"; }

    mkdir $out
    cp ${verified}/verify.log flipped.log guard-novalue.log guard-script.log $out/
    cp ${scriptVerified}/verify.log $out/verify-source.log
  ''
