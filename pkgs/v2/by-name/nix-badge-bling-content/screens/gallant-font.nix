# Regenerates the checked-in gallant-font-data.nix from the Sun Gallant 12x22 BDF in
# illumos-gate (CDDL, Copyright 2006 Sun Microsystems, Inc.).
{ pkgs }:
let
  gallantBdf = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/illumos/illumos-gate/4b529e40b9b8c5bcd0a4bc923a168c7988b72748/usr/src/data/consfonts/Gallant19.bdf";
    sha256 = "sha256-SkAjTLzO+UY8Gb+W7wShLSVC7VEQONpIAwqqU3IGZSY=";
  };
in
pkgs.runCommand "gallant-font-nix"
  {
    nativeBuildInputs = [ pkgs.gawk ];
    bdf = gallantBdf;
    awkScript = ./gallant-bdf-to-nix.awk;
    licenseNote = ./LICENSE.gallant;
  }
  ''
    mkdir -p "$out"
    awk -f "$awkScript" "$bdf" > "$out/gallant-font-data.nix"
    cp "$licenseNote" "$out/LICENSE.gallant"

    # All 95 printable ASCII glyphs, 22 rows each.
    n=$(grep -cE '^    "[0-9]+" = \[' "$out/gallant-font-data.nix")
    echo "gallant-font: emitted $n glyphs (want 95 printable ASCII)"
    [ "$n" -eq 95 ] || { echo "SELF-TEST FAIL: $n glyphs != 95" >&2; exit 1; }

    bad=$(grep -oE '\[ ([0-9]+ ){22}\];' "$out/gallant-font-data.nix" | wc -l)
    [ "$bad" -eq 95 ] || { echo "SELF-TEST FAIL: $bad glyphs with 22 rows != 95" >&2; exit 1; }
    echo "gallant-font: SELF-TEST PASS (95 glyphs x 22 rows)"
  ''
