# Renders short text as overlay entries (eval.zig applyOverlay), e.g. a "[nix] 60fps"
# HUD over Bad Apple. Each covered column is overwritten, so the text sits in a clean box.
# An entry is E = offset*256 + byte (offset = page*width + col), packed two per int as
# E0*262144 + E1, like a delta. Glyphs are the Spleen 5x8 table (BSD-2-Clause).
let
  data = import <nix-badge/lib/spleen-5x8-font-data.nix>; # { width=5; height=8; glyphs; }

  # Printable ASCII in codepoint order: char i is codepoint 32+i. Anything else is a space.
  ascii = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";
  cp = builtins.listToAttrs (
    builtins.genList (i: {
      name = builtins.substring i 1 ascii;
      value = 32 + i;
    }) (builtins.stringLength ascii)
  );

  glyphRows = c: data.glyphs.${toString (cp.${c} or 32)} or data.glyphs."32";
  chars = s: builtins.genList (i: builtins.substring i 1 s) (builtins.stringLength s);

  pow2 = n: builtins.foldl' (a: _: a * 2) 1 (builtins.genList (x: x) n);
  # Bit b (0 = LSB) of v.
  bit =
    v: b:
    let
      d = v / (pow2 b);
    in
    d - (d / 2) * 2;
  # Column c (0..4) of an 8-row glyph as a vertical byte: row r -> output bit r, reading the
  # (4-c)th bit of each row (bit 4 = leftmost column in the row-major table).
  colByte =
    rows: c:
    builtins.foldl' (acc: r: acc + (bit (builtins.elemAt rows r) (4 - c)) * (pow2 r)) 0 (
      builtins.genList (x: x) 8
    );

  # Each glyph's column bytes, computed once. Only cheap when the caller hoists the
  # import out of its per-frame lambda.
  glyphColsByCp = builtins.mapAttrs (_: rows: builtins.genList (c: colByte rows c) 5) data.glyphs;
  colsOf = ch: glyphColsByCp.${toString (cp.${ch} or 32)} or glyphColsByCp."32";

  advance = 6; # 5px cell + 1px gap
in
{
  # renderText { text; x?; page?; width?; } -> { overlay = [packed ints]; overlayN = count; }
  # Draws `text` on `page` (0 = top 8 rows) from column `x`, clipped to `width`.
  renderText =
    {
      text,
      x ? 0,
      page ? 0,
      width ? 128,
    }:
    let
      # Each character's 5 glyph columns + 1 gap column as { col; byte; }.
      cells = builtins.concatMap (
        i:
        let
          ch = builtins.elemAt (chars text) i;
          cols = colsOf ch;
          base = x + i * advance;
        in
        builtins.genList (c: {
          col = base + c;
          byte = if c < 5 then builtins.elemAt cols c else 0; # col 5 = inter-char gap
        }) advance
      ) (builtins.genList (i: i) (builtins.stringLength text));

      # Clip on column (0..width), then place on `page`: offset = page*width + col.
      es = map (e: {
        off = page * width + e.col;
        inherit (e) byte;
      }) (builtins.filter (e: e.col >= 0 && e.col < width) cells);
      n = builtins.length es;
      E = e: e.off * 256 + e.byte;
      npairs = (n + 1) / 2;
      packed = builtins.genList (
        p:
        let
          e0 = builtins.elemAt es (2 * p);
          e1i = 2 * p + 1;
        in
        (E e0) * 262144 + (if e1i < n then E (builtins.elemAt es e1i) else 0)
      ) npairs;
    in
    {
      overlay = packed;
      overlayN = n;
    };
}
