# Regenerates the checked-in spleen-{5x8,8x16}-font-data.nix from the Spleen BDFs
# (Frederic Cambus, BSD-2-Clause).
{ pkgs }:
let
  rev = "0493c34e22791824767c618fed42c434b477662c"; # tag 2.2.0
  spleen5x8Bdf = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/fcambus/spleen/${rev}/spleen-5x8.bdf";
    sha256 = "sha256-QEiBhNB10MdSzdI5tEHF7OUeULNTFW8klsdWw4SrAcs=";
  };
  spleen8x16Bdf = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/fcambus/spleen/${rev}/spleen-8x16.bdf";
    sha256 = "sha256-Sj2X7mGoyGp1JdjHI8uKFAgfOVzS/rQie6XjuvBim64=";
  };
in
pkgs.runCommand "spleen-font-nix"
  {
    nativeBuildInputs = [ pkgs.gawk ];
    bdf5x8 = spleen5x8Bdf;
    bdf8x16 = spleen8x16Bdf;
    awkScript = ./spleen-bdf-to-nix.awk;
    licenseNote = ./LICENSE.spleen;
  }
  ''
    mkdir -p "$out"
    awk -v width=5 -v height=8  -f "$awkScript" "$bdf5x8"  > "$out/spleen-5x8-font-data.nix"
    awk -v width=8 -v height=16 -f "$awkScript" "$bdf8x16" > "$out/spleen-8x16-font-data.nix"
    cp "$licenseNote" "$out/LICENSE.spleen"

    # All 95 printable ASCII glyphs, `height` rows each.
    check() {
      local file="$1" rows="$2"
      n=$(grep -cE '^    "[0-9]+" = \[' "$file")
      echo "spleen-font: $file emitted $n glyphs (want 95 printable ASCII)"
      [ "$n" -eq 95 ] || { echo "SELF-TEST FAIL: $file $n glyphs != 95" >&2; exit 1; }
      bad=$(grep -oE "\[ ([0-9]+ ){$rows}\];" "$file" | wc -l)
      [ "$bad" -eq 95 ] || { echo "SELF-TEST FAIL: $file $bad glyphs with $rows rows != 95" >&2; exit 1; }
      echo "spleen-font: SELF-TEST PASS ($file: 95 glyphs x $rows rows)"
    }
    check "$out/spleen-5x8-font-data.nix" 8
    check "$out/spleen-8x16-font-data.nix" 16
  ''
