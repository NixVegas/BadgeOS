# The FAT boot partition for a card:
#   /<core>/slot-A/boot.itb    each core's generation image (nix-badge-boot-image)
#   /<core>/slot-A/vbmeta.itb  the store image's slot vbmeta, the same for every core
#   /<core>/slot-B/            a copy of slot-A/: NIX_B holds the same store image
#   /fip.bin                   the fip the ROM boots (the polyglot on a two-core board)
#   /fip-<core>.bin            optional plaintext recovery fips (not on a fused card)
#   /secure                    `signed` or `unsigned`; every image's .secure must agree
{
  lib,
  callPackage,
  runCommand,
}:
let
  makeBootDir =
    {
      fip,
      # { <core> = fip; }
      recoveryFips ? { },
      # { <core> = system.build.bootImage; }
      bootImages,
      # the store image's passthru.vbmeta
      vbmeta,
    }:
    let
      cores = lib.attrNames bootImages;
      markers = map (core: "${bootImages.${core}}/.secure") cores ++ [ "${vbmeta}/.secure" ];
      disagreement = lib.concatStringsSep ", " (
        map (core: "${core} boot.itb $(cat ${bootImages.${core}}/.secure)") cores
        ++ [ "vbmeta $(cat ${vbmeta}/.secure)" ]
      );
    in
    runCommand "sg2k-boot-dir" { } ''
      ${lib.concatMapStrings (core: ''
        install -D -m 0644 "${bootImages.${core}}/boot.itb" "$out/${core}/slot-A/boot.itb"
        install -D -m 0644 "${bootImages.${core}}/boot.itb" "$out/${core}/slot-B/boot.itb"
      '') cores}
      for core in ${toString cores}; do
        install -D -m 0644 "${vbmeta}/vbmeta.itb" "$out/$core/slot-A/vbmeta.itb"
        install -D -m 0644 "${vbmeta}/vbmeta.itb" "$out/$core/slot-B/vbmeta.itb"
      done

      marker=$(cat "${lib.head markers}")
      for m in ${lib.escapeShellArgs markers}; do
        case "$(cat "$m")" in
          signed | unsigned) ;;
          *) echo "make-boot-dir: $m says '$(cat "$m")', not signed or unsigned" >&2; exit 1 ;;
        esac
        [ "$(cat "$m")" = "$marker" ] || {
          echo "make-boot-dir: secure markers disagree: ${disagreement}" >&2
          exit 1
        }
      done
      printf '%s' "$marker" > "$out/secure"

      cp ${fip} "$out/fip.bin"
      ${lib.concatStrings (
        lib.mapAttrsToList (core: f: ''
          cp ${f} "$out/fip-${core}.bin"
        '') recoveryFips
      )}
    '';
in
lib.setFunctionArgs makeBootDir (lib.functionArgs makeBootDir)
// {
  passthru.tests.boot-dir = callPackage ./test.nix { };
}
