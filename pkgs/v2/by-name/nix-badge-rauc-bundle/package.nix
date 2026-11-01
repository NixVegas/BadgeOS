# A signed RAUC bundle (verity format) from a gpt system: the store image, boot.tar (each
# core's boot.itb and vbmeta.itb, secure, store.sha256) and the fip, as a raw image or,
# with fipInBoot, inside boot.tar. The output is a directory with the bundle
# (passthru.fileName) and its hydra-build-products entry.
{
  lib,
  callPackage,
  runCommand,
  rauc,
  gnutar,
  coreutils,
  squashfsTools,
  nix-badge-bundle-signing,
}:
let
  inherit (nix-badge-bundle-signing) verifier;

  makeBundle =
    {
      name,
      version,
      storeImage,
      # { <core> = system.build.bootImage; } (boot.itb + .secure)
      bootImages,
      # The store image's slot vbmeta (vbmeta.itb + .secure), the same bytes as its own.
      vbmeta ? storeImage.vbmeta,
      fip,
      # A nix-badge-bundle-signing signer.
      signer,
      # The keyring cert the badge trusts. The signer is a self-signed leaf, so the badge
      # accepts the bundle only if its cert is byte-identical to this one.
      trustedCert,
      # Other badge configs' keyring certs that must match the signer too.
      extraTrustedCerts ? [ ],
      # The manifest's [update] compatible: the target board's hardware.sg2k.rauc.compatible.
      compatible,
      # No eMMC: the fip goes in boot.tar, for the hook to write to the booted SD's FAT.
      fipInBoot ? false,
    }:
    let
      cores = lib.attrNames bootImages;
      markers = map (core: "${bootImages.${core}}/.secure") cores ++ [ "${vbmeta}/.secure" ];
      disagreement = lib.concatStringsSep ", " (
        map (core: "${core} boot.itb $(cat ${bootImages.${core}}/.secure)") cores
        ++ [ "vbmeta $(cat ${vbmeta}/.secure)" ]
      );
      itbs = lib.concatMap (core: [
        "${core}/boot.itb"
        "${core}/vbmeta.itb"
      ]) cores;
      payload = lib.sort lib.lessThan (
        itbs
        ++ [
          "secure"
          "store.sha256"
        ]
        ++ lib.optional fipInBoot "fip.bin"
      );
      sections = [
        "[image.boot]"
        "[image.nix]"
      ]
      ++ lib.optional (!fipInBoot) "[image.fip]";
    in
    runCommand "${name}-${version}"
      (
        {
          passthru.fileName = "${name}-${version}.raucb";
          # `rauc bundle` runs mksquashfs by name for format=verity.
          nativeBuildInputs = [
            rauc
            gnutar
            coreutils
            squashfsTools
          ];
        }
        // signer.drvAttrs
      )
      ''
        mkdir -p in ${lib.concatMapStringsSep " " (core: "boot/${core}") cores}

        # One secure word for the bundle; the hook compares it with the card's /secure.
        marker=$(cat ${lib.head markers})
        for m in ${lib.escapeShellArgs markers}; do
          case "$(cat "$m")" in
            signed | unsigned) ;;
            *) echo "make-bundle: $m says '$(cat "$m")', not signed or unsigned" >&2; exit 1 ;;
          esac
          [ "$(cat "$m")" = "$marker" ] || {
            echo "make-bundle: secure markers disagree: ${disagreement}" >&2
            exit 1
          }
        done
        cmp ${vbmeta}/vbmeta.itb ${storeImage}/vbmeta.itb || {
          echo "make-bundle: vbmeta.itb is not the store image's own (${storeImage}/vbmeta.itb)" >&2
          exit 1
        }

        # store.img is a symlink in the store image's output; cp follows it.
        cp ${storeImage}/store.img in/store.img

        # Ties boot.tar to this store.img: the hook compares it with RAUC_IMAGE_DIGEST,
        # the manifest's sha256 of the same file.
        sha256sum in/store.img | cut -d' ' -f1 > boot/store.sha256

        # boot.tar is slot-agnostic: the hook copies it into whichever slot RAUC installs.
        for core in ${toString cores}; do
          cp ${vbmeta}/vbmeta.itb boot/$core/vbmeta.itb
        done
        ${lib.concatMapStrings (core: ''
          cp ${bootImages.${core}}/boot.itb boot/${core}/boot.itb
        '') cores}
        chmod 0644 boot/*/*.itb
        ${lib.optionalString fipInBoot ''
          cp ${fip} boot/fip.bin
          chmod 0644 boot/fip.bin
        ''}
        printf '%s' "$marker" > boot/secure
        ( cd boot && tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
            -cf "$NIX_BUILD_TOP/in/boot.tar" \
            ${toString payload} )

        # Exactly the names the hook expects (sort, not grep -q: tar would get SIGPIPE).
        tar -tf in/boot.tar | sort > boot.lst
        printf '%s\n' ${toString payload} | sort > want.lst
        cmp -s boot.lst want.lst || {
          echo "make-bundle: boot.tar does not list exactly the expected files:" >&2
          diff want.lst boot.lst >&2 || true
          exit 1
        }
        for f in ${toString itbs}; do
          [ -s boot/$f ] || { echo "make-bundle: $f is empty" >&2; exit 1; }
        done

        ${lib.optionalString (!fipInBoot) ''
          # The fip goes raw to offset 0 of boot area 1; the factory copy at +1 MiB, the ROM's
          # fallback for a torn update, is only ever written by nix-badge-emmc-init.
          cp ${fip} in/fip.bin
          fipsize=$(stat -c %s in/fip.bin)
          [ "$fipsize" -le 1048576 ] || {
            echo "make-bundle: fip.bin is $fipsize bytes, over the 1 MiB raw-slot budget" >&2
            exit 1
          }
        ''}

        install -m755 ${./hook.sh} in/hook.sh
        cat > in/manifest.raucm <<EOF
        [update]
        compatible=${compatible}
        version=${version}

        [bundle]
        format=verity

        [hooks]
        filename=hook.sh

        [image.boot]
        filename=boot.tar
        hooks=install

        [image.nix]
        filename=store.img
        hooks=post-install
        EOF
        ${lib.optionalString (!fipInBoot) ''
          # [image.fip] needs type=raw: RAUC maps no type to ".bin". RAUC installs the images
          # in file order, so the fip goes last, after every refusal and the store write.
          cat >> in/manifest.raucm <<EOF

          [image.fip]
          filename=fip.bin
          type=raw
          EOF
        ''}
        grep '^\[image\.' in/manifest.raucm > image-order.txt
        printf '%s\n' ${lib.escapeShellArgs sections} | cmp -s - image-order.txt || {
          echo "make-bundle: manifest image sections must be ${toString sections}, in that order:" >&2
          cat image-order.txt >&2
          exit 1
        }

        ${signer.setup}
        mkdir -p $out/nix-support
        bundle=$out/${name}-${version}.raucb
        ${signer.rauc}/bin/rauc bundle --cert=${signer.cert} --key=${signer.key} in "$bundle"

        # Against the cert the badge trusts: self-signed certs from one recipe on two
        # OpenSSL versions need not be byte-identical.
        cmp ${signer.cert} ${trustedCert} || {
          echo "make-bundle: the signing cert (${signer.cert}) is not the cert the badge trusts (${trustedCert})" >&2
          exit 1
        }
        for extra in ${lib.escapeShellArgs extraTrustedCerts}; do
          cmp ${signer.cert} "$extra" || {
            echo "make-bundle: the signing cert (${signer.cert}) is not $extra" >&2
            exit 1
          }
          echo "make-bundle: signing cert matches $extra"
        done

        # Verify with the badge's own keyring settings: a pass means the badge accepts it.
        ${verifier} ${trustedCert} "$bundle" > info.txt 2>&1 \
          || { cat info.txt; echo "make-bundle: $bundle does not verify against ${trustedCert}" >&2; exit 1; }
        cat info.txt
        grep -q "Compatible:.*${compatible}" info.txt
        grep -q "Version:.*${version}" info.txt
        grep -qE '^\s*Hooks:\s+install\s*$' info.txt
        grep -qE '^\s*Hooks:\s+post-install\s*$' info.txt
        echo "file rauc-bundle $bundle" >> $out/nix-support/hydra-build-products
      '';
in
lib.setFunctionArgs makeBundle (lib.functionArgs makeBundle)
// {
  # The bundle hook (./hook.sh) on a fake boot FAT.
  passthru.tests.rauc-hook = callPackage ./test.nix { };
}
