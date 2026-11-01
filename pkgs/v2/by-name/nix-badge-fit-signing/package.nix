# signFit / verifyFit: build (and when `secure`, sign) a U-Boot FIT on the build host,
# and check a signed one with the real FIT verifier (sophgone's sandbox U-Boot).
#
# signFit { name, its, inputs ? [ ], secure, cert ? null, ... }
#   -> $out/<name>.itb and $out/.secure. /incbin/ paths in `its` are store paths or
#   basenames of `inputs`. A secure build signs through the autopen daemon; mkimage exits
#   0 even when signing fails, so every signature is checked and the result verified.
#   requireConfigurations = false is for a script-only FIT (a slot's vbmeta.itb).
#
# verifyFit { itb, cert, keyName ? "sg1-image", mode ? "bootm", config ? null }
#   -> a check derivation: "bootm" checks a configuration signature, "source" runs the
#   script image `frag`, as nixbadge_fit runs a slot's vbmeta.itb.
{
  lib,
  pkgs,
  stdenv,
  callPackage,
  runCommand,
  writeShellScript,
  coreutils,
  gnugrep,
  dtc,
  ubootTools,
  sophgone,
  autopenOverlay,
  nixpkcsOverlay,
}:
let
  # pkgs with the autopen + nixpkcs overlays, as in nix-badge-fips.
  signPkgs = (pkgs.extend autopenOverlay).extend nixpkcsOverlay;

  mkProvider = signPkgs.callPackage ./provider.nix { };

  # Hash of autopen's verification key for sophgone's sg1-image.crt, so the remote key
  # needs no IFD. Recompute when the certificate changes (the mismatch reports it).
  sg1ImageCertHash = "sha256-WMZtOyNVmIVZ7Df0wk/nIErSaM33Cu8LqnuOJ47hcAU=";

  sandbox = sophgone.packages.${stdenv.buildPlatform.system}.uboot-sandbox;

  # The sandbox control DTB, built like sophgone's fit-key-dtb.nix: one certificate under
  # both key names (key-<name> required = "conf", key-<name>-img required = "image").
  fitKeyDtb =
    cert:
    {
      keyName ? "sg1-image",
    }:
    runCommand "fit-sandbox-control-dtb"
      {
        nativeBuildInputs = [
          dtc
          ubootTools
        ];
      }
      ''
        echo '/dts-v1/; / { };' | dtc -I dts -O dtb -p 4096 -o control.dtb
        mkdir keys
        cp ${cert} keys/${keyName}.crt
        cp ${cert} keys/${keyName}-img.crt
        fdt_add_pubkey -a sha256,rsa2048 -k keys -n ${keyName} -r conf control.dtb
        fdt_add_pubkey -a sha256,rsa2048 -k keys -n ${keyName}-img -r image control.dtb
        mkdir $out
        cp control.dtb $out/control.dtb
      '';

  # verify-fit <control.dtb> <itb> [keyName] [mode] [config]: run the FIT in the sandbox
  # U-Boot. Passes only if the configuration (bootm) or image (source) signature
  # verified and no check failed; what runs after verification does not count.
  # Never put `reset` in the -c script: it relaunches the sandbox forever.
  verifier = writeShellScript "verify-fit" ''
    set -uo pipefail
    dtb=$1 itb=$2 key=''${3:-sg1-image} mode=''${4:-bootm} conf=''${5:-}
    case $mode in
      bootm) run="iminfo 0x1000000; bootm 0x1000000''${conf:+#$conf}" ;;
      source) run="source 0x1000000:frag" ;;
      *) echo "verify-fit: unknown mode $mode" >&2; exit 1 ;;
    esac
    log=$(${coreutils}/bin/timeout 60 ${sandbox}/bin/u-boot -d "$dtb" \
      -c "host load hostfs - 0x1000000 $itb; $run" 2>&1 \
      | ${coreutils}/bin/tr -d '\r')
    printf '%s\n' "$log"
    ok=1
    grep() { ${gnugrep}/bin/grep "$@"; }
    if printf '%s\n' "$log" | grep -qE 'Bad Data Hash|Bad hash value| error!|Failed to verify|rsa2048:[A-Za-z0-9_-]*-( |$)'; then
      echo "verify-fit: a hash or signature check failed" >&2; ok=0
    fi
    if ! printf '%s\n' "$log" | grep -q 'rsa2048:'; then
      echo "verify-fit: no RSA signature was checked" >&2; ok=0
    fi
    if [ "$mode" = bootm ] && ${dtc}/bin/fdtget -l "$itb" /configurations 2>/dev/null | grep -q . \
      && ! printf '%s\n' "$log" | grep -qF "sha256,rsa2048:$key+ OK"; then
      echo "verify-fit: the configuration signature did not verify" >&2; ok=0
    fi
    # bootm's verification lines do not name the configuration; its "Using" line does.
    if [ -n "$conf" ] && ! printf '%s\n' "$log" | grep -qF "Using '$conf' configuration"; then
      echo "verify-fit: bootm did not select configuration $conf" >&2; ok=0
    fi
    if [ "$mode" = source ] && ! printf '%s\n' "$log" | grep -qE "sha256,rsa2048:$key-img\+( |$)"; then
      echo "verify-fit: the frag image signature did not verify" >&2; ok=0
    fi
    [ "$ok" = 1 ]
  '';

  # sig-guard <itb> [images-only]: every configuration and image has a signature-1 value
  # (mkimage's silent failure leaves the node without one).
  sigGuard = writeShellScript "fit-sig-guard" ''
    set -euo pipefail
    itb=$1 bad=0 parents="/configurations /images"
    if [ "''${2:-}" = images-only ]; then parents=/images; fi
    for parent in $parents; do
      if ! nodes=$(${dtc}/bin/fdtget -l "$itb" $parent); then
        echo "fit-sig-guard: cannot list $parent in $itb" >&2
        exit 1
      fi
      if [ -z "$nodes" ]; then
        echo "fit-sig-guard: no ''${parent#/} in $itb" >&2
        exit 1
      fi
      for node in $nodes; do
        if ! ${dtc}/bin/fdtget -t bx "$itb" $parent/$node/signature-1 value > /dev/null 2>&1; then
          echo "fit-sig-guard: $parent/$node has no signature-1 value" >&2
          bad=1
        fi
      done
    done
    [ "$bad" = 0 ]
  '';

  signFit =
    {
      name,
      its,
      inputs ? [ ],
      secure,
      keyName ? "sg1-image",
      cert ? null,
      certHash ? sg1ImageCertHash,
      socketPath ? "/run/autopen/socket",
      requireConfigurations ? true,
    }:
    assert lib.assertMsg (secure -> cert != null) "signFit ${name}: secure needs `cert`";
    let
      # A standalone store copy of the certificate: the shim reads it (AUTOPEN_CERT) at
      # sign time, and a bare subpath of a flake source is not in the build closure.
      certFile = builtins.path {
        path = cert;
        name = "${keyName}.crt";
      };
      remoteKey = signPkgs.autopen.lib.signingKey.remote {
        name = keyName;
        verificationKey = signPkgs.autopen.lib.verificationKey.fromCertificate {
          source = certFile;
          hash = certHash;
        };
        inherit socketPath;
      };
      provider = mkProvider {
        inherit remoteKey;
        cert = certFile;
        label = keyName;
      };
      controlDtb = fitKeyDtb certFile { inherit keyName; };
    in
    runCommand "fit-${name}"
      (
        {
          inherit its;
          passAsFile = [ "its" ];
          nativeBuildInputs = [
            dtc
          ]
          ++ (if secure then [ provider.mkimage ] else [ ubootTools ]);
        }
        // lib.optionalAttrs secure {
          # Only a builder advertising `autopen` (the host whose daemon holds the key);
          # preferLocalBuild alone is overridden by --max-jobs 0.
          preferLocalBuild = true;
          requiredSystemFeatures = [ "autopen" ];
          allowSubstitutes = false;
          passthru = { inherit remoteKey; };
        }
      )
      ''
        set -euo pipefail
        for f in ${lib.escapeShellArgs inputs}; do ln -s "$f" "$(stripHash "$f")"; done
        cp "$itsPath" "${name}.its"
        mkdir -p $out
        ${
          if secure then
            ''
              # The key as a PEM-encoded provider URI; mkimage's libcrypto resolves it
              # through the same provider. No -k/-K: with -k mkimage ignores -G.
              ${provider.openssl}/bin/openssl pkey -in 'pkcs11:object=${keyName};type=private' -out key-uri.pem
              head -n 1 key-uri.pem | grep -qx -- '-----BEGIN PKCS#11 PROVIDER URI-----' \
                || { echo "signFit ${name}: provider URI export failed" >&2; exit 1; }
              mkimage -f "${name}.its" -G key-uri.pem -r "$out/${name}.itb"
              ${sigGuard} "$out/${name}.itb" ${lib.optionalString (!requireConfigurations) "images-only"}
              ${verifier} ${controlDtb}/control.dtb "$out/${name}.itb" ${keyName} ${
                if requireConfigurations then "bootm" else "source"
              } > verify.log \
                || { cat verify.log; exit 1; }
              echo signed > $out/.secure
            ''
          else
            ''
              mkimage -f "${name}.its" "$out/${name}.itb"
              echo unsigned > $out/.secure
            ''
        }
      '';

  verifyFit =
    {
      itb,
      cert,
      keyName ? "sg1-image",
      mode ? "bootm",
      config ? null,
    }:
    assert lib.assertMsg (config != null -> mode == "bootm") "verifyFit: `config` needs mode bootm";
    let
      controlDtb = fitKeyDtb cert { inherit keyName; };
    in
    runCommand "verify-fit${lib.optionalString (config != null) "-${config}"}" { } ''
      mkdir $out
      ${verifier} ${controlDtb}/control.dtb ${itb} ${keyName} ${mode} ${
        lib.optionalString (config != null) (lib.escapeShellArg config)
      } > $out/verify.log \
        || { cat $out/verify.log; exit 1; }
    '';

  toolkit = {
    inherit
      signPkgs
      signFit
      verifyFit
      verifier
      sigGuard
      mkProvider
      sg1ImageCertHash
      ;
    fitKeyDtb = cert: fitKeyDtb cert { };
  };
in
toolkit
// {
  passthru = {
    # The offline signer stand-in the signing checks share (./test-daemon.nix).
    testDaemon = callPackage ./test-daemon.nix { fit = toolkit; };
    tests.fit-sign = callPackage ./test.nix { };
  };
}
