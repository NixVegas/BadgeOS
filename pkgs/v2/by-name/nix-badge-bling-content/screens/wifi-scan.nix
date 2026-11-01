# WiFi scan results. The net-scan service (modules/sg2k/net-scan.nix) writes
# /run/nix-badge/wifi-scan, one "<signal_dBm>\t<SSID>" line per AP, strongest first.
# It runs only while a screen that returns `wantsScan = true` is up.
#
#   32px (title + 3 rows):            64px (title + 7 rows):
#   WIFI 6                            WIFI 6
#   -42 HomeNet                       -42 HomeNet
#   -55 Cafe_Guest                    -55 Cafe_Guest
#   -67 <hidden>                      -67 <hidden>
#                                     -70 NETGEAR-5G
#                                     ...
#
#   scope: { width; height; ... } -> { bitmap = [ width*height/8/4 ints ]; nextMs; wantsScan; }
scope:
let
  d = (import ./draw.nix) { inherit (scope) width height; };
  inherit (d) width height;
  sp = d.spleen5x8;

  # The file is absent until the first scan finishes.
  path = "/run/nix-badge/wifi-scan";
  raw = if builtins.pathExists path then builtins.readFile path else "";

  # A char-by-char fold, fine for a <1KB file.
  splitOn =
    delim: s:
    let
      n = builtins.stringLength s;
      step =
        st: i:
        let
          c = builtins.substring i 1 s;
        in
        if c == delim then
          {
            cur = "";
            acc = st.acc ++ [ st.cur ];
          }
        else
          {
            cur = st.cur + c;
            acc = st.acc;
          };
      f = builtins.foldl' step {
        cur = "";
        acc = [ ];
      } (builtins.genList (i: i) n);
    in
    f.acc ++ [ f.cur ];

  rows = builtins.filter (l: l != "") (splitOn "\n" raw);
  count = builtins.length rows;

  fmtLine = l: builtins.concatStringsSep " " (splitOn "\t" l);

  pages = height / 8;
  maxLines = pages - 1; # page 0 is the title
  shownN = if count < maxLines then count else maxLines;

  # Rows sit on page boundaries, so no glyph spills across pages.
  withTitle = sp.drawText d.empty 0 0 "WIFI ${toString count}";

  body =
    if count == 0 then
      sp.drawText withTitle 0 8 "scanning..."
    else
      builtins.foldl' (
        surf: i: sp.drawText surf 0 (8 * (i + 1)) (fmtLine (builtins.elemAt rows i))
      ) withTitle (builtins.genList (i: i) shownN);
in
{
  bitmap = d.pack body;
  # A scan rewrites the file at most every 20 s while this screen is up.
  nextMs = 1500;
  wantsScan = true;
}
