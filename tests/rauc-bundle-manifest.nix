# A bundle's manifest: its compatible, its image sections in order and, given bootTar,
# exactly the files of its boot.tar.
{ pkgs }:
{
  name,
  bundle,
  compatible,
  sections,
  bootTar ? null,
}:
let
  inherit (pkgs) lib;
in
pkgs.runCommand "test-${name}"
  {
    nativeBuildInputs = [
      pkgs.squashfsTools
      pkgs.gnutar
    ];
  }
  ''
    unsquashfs -cat ${bundle}/${bundle.fileName} manifest.raucm > manifest.raucm
    cat manifest.raucm
    grep -qx 'compatible=${compatible}' manifest.raucm || { echo "manifest compatible is not ${compatible}" >&2; exit 1; }
    grep '^\[image\.' manifest.raucm > order.txt
    printf '%s\n' ${lib.escapeShellArgs sections} > want.txt
    cmp want.txt order.txt || { echo "image sections are not ${toString sections}:" >&2; cat order.txt >&2; exit 1; }
    ${lib.optionalString (bootTar != null) ''
      unsquashfs -cat ${bundle}/${bundle.fileName} boot.tar | tar -t | sort > tar.txt
      printf '%s\n' ${lib.escapeShellArgs bootTar} | sort > want-tar.txt
      cmp want-tar.txt tar.txt || { echo "boot.tar does not list exactly ${toString bootTar}:" >&2; cat tar.txt >&2; exit 1; }
    ''}
    touch $out
  ''
