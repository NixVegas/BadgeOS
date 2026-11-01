# The screens' drawing library, for a 128xH mono SSD1306 panel (H = 32 or 64). Text comes
# in Sun Gallant 12x22 (CDDL) for hero values and Spleen 5x8/8x16 (BSD-2-Clause) for
# detail rows, both generated from their BDFs into *-font-data.nix.
#
# A screen applies it to `{ inherit (scope) width height; }` and draws onto a surface:
# every primitive takes a surface and returns a new one, starting from `empty`, and
# `pack` turns the final surface into the bitmap. GDDRAM byte = page*width + col with
# page = y/8, and bit r of a byte is pixel (col, page*8+r). Builtins only.
let
  oled = import ../oled.nix;
  inherit (oled) mod p2 range;

  # { width; height; glyphs = { "<cp>" = [ one int per row ]; }; }, bit (width-1) = leftmost.
  gallantFont = import ./gallant-font-data.nix;
  spleen5x8Font = import ./spleen-5x8-font-data.nix;
  spleen8x16Font = import ./spleen-8x16-font-data.nix;

  bitSet = v: n: mod (v / (p2 n)) 2 == 1;

  # Transpose a row-major WxH glyph into columns of ceil(H/8) vertical bytes:
  #   result[c] = [ sliceByte0 sliceByte1 ... ], bit r of slice s = pixel (c, s*8+r).
  glyphColumns =
    fW: fH: rows:
    let
      slices = (fH + 7) / 8; # page-rows the cell spans (Gallant 22 -> 3, Spleen 8 -> 1)
      colByte =
        c: s:
        builtins.foldl' (
          acc: r:
          let
            row = s * 8 + r;
          in
          if row < fH && bitSet (builtins.elemAt rows row) (fW - 1 - c) then acc + p2 r else acc
        ) 0 (range 0 8);
    in
    builtins.genList (c: builtins.genList (s: colByte c s) slices) fW;

  # Transposed once per font, outside the per-frame lambda. advance = cell width + 1px gap.
  mkFontData =
    tbl:
    let
      fW = tbl.width;
      fH = tbl.height;
      slices = (fH + 7) / 8;
      blankCol = builtins.genList (_: 0) slices;
    in
    {
      width = fW;
      height = fH;
      inherit slices;
      advance = fW + 1;
      blankCols = builtins.genList (_: blankCol) fW; # a whole blank cell's columns
      cols = builtins.mapAttrs (_: rows: glyphColumns fW fH rows) tbl.glyphs;
    };

  gallantData = mkFontData gallantFont;
  spleen5x8Data = mkFontData spleen5x8Font;
  spleen8x16Data = mkFontData spleen8x16Font;

  # builtins has no ord. Anything absent draws as a space.
  codepointOf =
    c:
    let
      m = {
        " " = 32;
        "!" = 33;
        "\"" = 34;
        "#" = 35;
        "$" = 36;
        "%" = 37;
        "&" = 38;
        "'" = 39;
        "(" = 40;
        ")" = 41;
        "*" = 42;
        "+" = 43;
        "," = 44;
        "-" = 45;
        "." = 46;
        "/" = 47;
        "0" = 48;
        "1" = 49;
        "2" = 50;
        "3" = 51;
        "4" = 52;
        "5" = 53;
        "6" = 54;
        "7" = 55;
        "8" = 56;
        "9" = 57;
        ":" = 58;
        ";" = 59;
        "<" = 60;
        "=" = 61;
        ">" = 62;
        "?" = 63;
        "@" = 64;
        "A" = 65;
        "B" = 66;
        "C" = 67;
        "D" = 68;
        "E" = 69;
        "F" = 70;
        "G" = 71;
        "H" = 72;
        "I" = 73;
        "J" = 74;
        "K" = 75;
        "L" = 76;
        "M" = 77;
        "N" = 78;
        "O" = 79;
        "P" = 80;
        "Q" = 81;
        "R" = 82;
        "S" = 83;
        "T" = 84;
        "U" = 85;
        "V" = 86;
        "W" = 87;
        "X" = 88;
        "Y" = 89;
        "Z" = 90;
        "a" = 97;
        "b" = 98;
        "c" = 99;
        "d" = 100;
        "e" = 101;
        "f" = 102;
        "g" = 103;
        "h" = 104;
        "i" = 105;
        "j" = 106;
        "k" = 107;
        "l" = 108;
        "m" = 109;
        "n" = 110;
        "o" = 111;
        "p" = 112;
        "q" = 113;
        "r" = 114;
        "s" = 115;
        "t" = 116;
        "u" = 117;
        "v" = 118;
        "w" = 119;
        "x" = 120;
        "y" = 121;
        "z" = 122;
        "[" = 91;
        "\\" = 92;
        "]" = 93;
        "^" = 94;
        "_" = 95;
        "`" = 96;
        "{" = 123;
        "|" = 124;
        "}" = 125;
        "~" = 126;
      };
    in
    if m ? ${c} then m.${c} else 32;

  chars = s: builtins.genList (i: builtins.substring i 1 s) (builtins.stringLength s);

  colsForChar =
    fontData: c:
    let
      cp = toString (codepointOf c);
    in
    if fontData.cols ? ${cp} then fontData.cols.${cp} else fontData.blankCols;
in
# Everything above is shared across frames.
{
  width ? 128,
  height ? 32,
}:
let
  pages = height / 8;
  nBytes = width * height / 8;
  nInts = nBytes / 4;

  # A surface is a list of `{ off; byte; }` contributions; `pack` ORs overlaps together.
  # Off-panel contributions are dropped. A primitive applied to `empty` yields only its
  # own entries, so a screen can build a big shape with one concatLists.
  empty = [ ];

  orI = a: b: builtins.bitOr a b;

  # Entries for column x, rows y0 .. y0+h-1: one per page the run covers.
  vrunEntries =
    x: y0: h:
    let
      y1 = y0 + h - 1; # last lit row (inclusive)
    in
    if h <= 0 || x < 0 || x >= width || y1 < 0 || y0 >= height then
      [ ]
    else
      let
        p0 = if y0 < 0 then 0 else y0 / 8;
        p1 = if y1 >= height then pages - 1 else y1 / 8;
      in
      builtins.genList (
        i:
        let
          page = p0 + i;
          base = page * 8;
          lo = if y0 > base then y0 - base else 0; # first lit row within page
          hi = if y1 < base + 7 then y1 - base else 7; # last lit row within page
          byte = (p2 (hi + 1) - 1) - (p2 lo - 1); # bits lo..hi set
        in
        {
          off = page * width + x;
          inherit byte;
        }
      ) (p1 - p0 + 1);

  orVRun =
    surf: x: y0: h:
    surf ++ vrunEntries x y0 h;

  setPixel =
    surf: x: y:
    if x >= 0 && x < width && y >= 0 && y < height then orVRun surf x y 1 else surf;

  # `w` pixels from (x,y) to the right.
  hline =
    surf: x: y: w:
    surf ++ builtins.concatMap (i: vrunEntries (x + i) y 1) (range 0 w);

  # `h` pixels from (x,y) down.
  vline =
    surf: x: y: h:
    orVRun surf x y h;

  # Filled w x h rectangle, top-left (x,y).
  fillRect =
    surf: x: y: w: h:
    surf ++ builtins.concatMap (i: vrunEntries (x + i) y h) (range 0 w);

  # Hollow w x h rectangle (border only).
  rect =
    surf: x: y: w: h:
    let
      top = hline surf x y w;
      bot = hline top x (y + h - 1) w;
      l = vline bot x y h;
    in
    vline l (x + w - 1) y h;

  # One glyph byte `v` placed `off` = y mod 8 rows into `page`: it splits across `page`
  # and `page+1`. Returns 0..2 entries.
  cellEntries =
    col: page: v: lowShift: hiShift: off:
    if v == 0 || col < 0 || col >= width then
      [ ]
    else
      let
        lowByte = mod (v * lowShift) 256; # bits landing in `page`
        hiByte = if off == 0 then 0 else v / hiShift; # bits spilling to page+1
        lo =
          if lowByte != 0 && page >= 0 && page < pages then
            [
              {
                off = page * width + col;
                byte = lowByte;
              }
            ]
          else
            [ ];
        hi =
          if hiByte != 0 && page + 1 >= 0 && page + 1 < pages then
            [
              {
                off = (page + 1) * width + col;
                byte = hiByte;
              }
            ]
          else
            [ ];
      in
      lo ++ hi;

  # Entries for one glyph, top-left (x,y), clipped per column.
  glyphEntries =
    fontData: x: y: cols:
    let
      off = mod y 8; # sub-page shift 0..7
      basePage = (y - off) / 8; # NB: y may be negative; screens keep y>=0
      lowShift = p2 off; # multiply to move bits up within a page
      hiShift = p2 (8 - off); # divide to get the bits that spilled into next page
      nCols = builtins.length cols;
    in
    builtins.concatMap (
      c:
      let
        colBytes = builtins.elemAt cols c; # `slices` bytes for this column
        colX = x + c;
      in
      builtins.concatMap (
        sIdx: cellEntries colX (basePage + sIdx) (builtins.elemAt colBytes sIdx) lowShift hiShift off
      ) (range 0 fontData.slices)
    ) (range 0 nCols);

  drawGlyphCols =
    fontData: surf: x: y: cols:
    surf ++ glyphEntries fontData x y cols;

  # A string left to right, stopping at the right edge.
  drawTextWith =
    fontData: surf: x: y: str:
    let
      adv = fontData.advance;
      cs = chars str;
      perChar = builtins.genList (
        i:
        let
          cx = x + i * adv;
        in
        if cx >= width then
          [ ]
        else
          glyphEntries fontData cx y (colsForChar fontData (builtins.elemAt cs i))
      ) (builtins.length cs);
    in
    surf ++ builtins.concatLists perChar;

  mkFace = fontData: {
    advance = fontData.advance;
    width = fontData.width;
    height = fontData.height;
    glyphW = fontData.advance;
    drawChar =
      surf: x: y: c:
      drawGlyphCols fontData surf x y (colsForChar fontData c);
    drawText = drawTextWith fontData;
    textWidth = s: builtins.stringLength s * fontData.advance;
  };

  gallant = mkFace gallantData; # 12x22 hero face
  spleen5x8 = mkFace spleen5x8Data; # 5x8 dense detail face
  spleen8x16 = mkFace spleen8x16Data; # 8x16 mid face

  # The bare helpers draw Gallant.
  inherit (gallant)
    drawChar
    drawText
    textWidth
    glyphW
    ;
  gW = gallant.width; # 12
  gH = gallant.height; # 22

  # A hollow w x h gauge with the leftmost `frac` (0.0..1.0) of its interior filled,
  # round(inner*frac) columns with inner = w-2. Each solid column is one vertical run,
  # because `pack` cost grows with the entry count.
  drawBar =
    surf: x: y: w: h: frac:
    if w < 2 || h < 2 then
      surf
    else
      let
        f =
          if frac < 0.0 then
            0.0
          else if frac > 1.0 then
            1.0
          else
            frac;
        inner = w - 2;
        fill = builtins.floor (inner * f + 0.5);
        solidE = builtins.concatMap (i: vrunEntries (x + i) y h) (range 0 (fill + 1));
        rightE = vrunEntries (x + w - 1) y h;
        # Unfilled interior columns: top and bottom pixels only.
        emptyInner = w - 2 - fill;
        frameE = builtins.concatMap (
          i: vrunEntries (x + 1 + fill + i) y 1 ++ vrunEntries (x + 1 + fill + i) (y + h - 1) 1
        ) (range 0 emptyInner);
      in
      surf ++ solidE ++ rightE ++ frameE;

  # Surface -> bitmap: width*height/32 ints, 4 GDDRAM bytes each, little-endian. Entries
  # are sorted by offset, equal offsets OR'd, and one cursor walk emits the ints.
  pack =
    surf:
    let
      sorted = builtins.sort (a: b: a.off < b.off) surf;
      laneMul =
        off:
        let
          l = off - (off / 4) * 4;
        in
        if l == 0 then
          1
        else if l == 1 then
          256
        else if l == 2 then
          65536
        else
          16777216;
      # `outRev` holds the finished ints in reverse, `curI` is the int being built and
      # `curVal` its value so far. place adds a finished byte, zero-filling skipped ints.
      place =
        st: off: byte:
        if byte == 0 then
          st
        else
          let
            ti = off / 4;
            lv = byte * (laneMul off);
          in
          if ti == st.curI then
            {
              outRev = st.outRev;
              curI = st.curI;
              curVal = st.curVal + lv;
            }
          else
            let
              gap = builtins.genList (g: 0) (ti - st.curI - 1);
            in
            {
              outRev = gap ++ [ st.curVal ] ++ st.outRev;
              curI = ti;
              curVal = lv;
            };
      # One fold: OR equal offsets together (curOff/curByte), then place.
      st =
        builtins.foldl'
          (
            acc: e:
            if acc.curOff == e.off then
              acc // { curByte = orI acc.curByte e.byte; }
            else
              let
                placed = place acc.place acc.curOff acc.curByte;
              in
              {
                curOff = e.off;
                curByte = e.byte;
                place = placed;
              }
          )
          {
            curOff = -1;
            curByte = 0;
            place = {
              outRev = [ ];
              curI = 0;
              curVal = 0;
            };
          }
          sorted;
      finalPlaced = place st.place st.curOff st.curByte;
      # Reverse, append the last int, zero-fill to nInts.
      headInts = builtins.genList (
        j: builtins.elemAt (finalPlaced.outRev) (builtins.length finalPlaced.outRev - 1 - j)
      ) (builtins.length finalPlaced.outRev);
      builtInts = headInts ++ [ finalPlaced.curVal ];
      nBuilt = builtins.length builtInts;
    in
    builtins.genList (i: if i < nBuilt then builtins.elemAt builtInts i else 0) nInts;

  # Right-justify `s` in `n` chars.
  padLeft =
    n: s:
    let
      d = n - builtins.stringLength s;
    in
    if d <= 0 then s else builtins.concatStringsSep "" (builtins.genList (_: " ") d) + s;

  # Zero-pad to 2 digits.
  pad2 =
    n:
    let
      s = toString n;
    in
    if builtins.stringLength s < 2 then "0${s}" else s;

  # Thousandths as "X.XX", truncated: 4100 -> "4.10".
  fixed2 =
    milliInt:
    let
      whole = milliInt / 1000;
      frac = mod milliInt 1000;
      hund = frac / 10;
    in
    "${toString whole}.${pad2 hund}";
in
{
  inherit
    empty
    setPixel
    hline
    vline
    fillRect
    rect
    drawChar
    drawText
    drawBar
    pack
    padLeft
    pad2
    fixed2
    glyphW
    textWidth
    width
    height
    ;
  fontWidth = gW;
  fontHeight = gH;
  # Each face is { drawText; drawChar; textWidth; advance; glyphW; width; height; }.
  inherit gallant spleen5x8 spleen8x16;
  inherit (oled) mod range;
}
