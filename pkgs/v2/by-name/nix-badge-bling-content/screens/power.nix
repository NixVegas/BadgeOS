# Power: the VSEL system rail (`scope.vselMv`, the TPS2116 output) and the 3xAA pack.
# Only the rail is labelled RAIL: a pack voltage under that caption reads as a bad rail.
#
#   32px:                             64px:
#   5.01V   RAIL                      5.01V             <- Gallant VSEL rail (hero)
#           BAT 87%                   RAIL      VBUS    <- Spleen: caption + source
#   [======pack bar=====]             BAT 5.43V  87%    <- Spleen pack detail
#                                     [=====pack bar====]
#                                     3.00 V ...... 5.40 V  <- pack scale labels
#
#   scope: { t; width; height; vselMv; batteryMv; batteryPct; onUsb; ... }
#   -> { bitmap = [ width*height/8/4 ints ]; nextMs; }
scope:
let
  d = (import ./draw.nix) { inherit (scope) width height; };
  inherit (d) width height;
  sp = d.spleen5x8;

  railMv = scope.vselMv or 0;
  railStr = if railMv > 0 then "${d.fixed2 railMv}V" else "--";

  batMv = scope.batteryMv;
  batStr = "${d.fixed2 batMv}V";

  # Pack level over 3.00..5.40 V, clamped to 0..1.
  frac =
    let
      x = (batMv - 3000) * 1.0 / 2400.0;
    in
    if x < 0.0 then
      0.0
    else if x > 1.0 then
      1.0
    else
      x;
  pct = builtins.floor (frac * 100.0 + 0.5);
  src = if scope.onUsb then "VBUS" else "BAT";

  layout32 =
    let
      s0 = d.drawText d.empty 0 0 railStr;
      detailX = d.textWidth railStr + 6;
      s1 = sp.drawText s0 detailX 2 "RAIL";
      s2a = sp.drawText s1 detailX 12 "BAT ${toString pct}%";
      s2 = d.drawBar s2a 0 (height - 6) width 6 frac;
    in
    d.pack s2;

  layout64 =
    let
      s0 = d.drawText d.empty 0 0 railStr;
      capY = (d.gallant.height - sp.height) / 2;
      s1 = sp.drawText s0 (d.textWidth railStr + 6) capY "RAIL";
      s1b = sp.drawText s1 (width - sp.textWidth src) capY src;

      detY = d.gallant.height + 2;
      s2 = sp.drawText s1b 0 detY "BAT ${batStr}  ${d.padLeft 3 (toString pct)}%";

      scaleY = height - sp.height;
      barY = detY + sp.height + 3;
      barH = scaleY - barY - 2;
      s3 = d.drawBar s2 0 barY width barH frac;

      loStr = "3.00 V";
      hiStr = "5.40 V";
      s4 = sp.drawText s3 0 scaleY loStr;
      s5 = sp.drawText s4 (width - sp.textWidth hiStr) scaleY hiStr;
    in
    d.pack s5;
in
{
  bitmap = if height >= 64 then layout64 else layout32;
  nextMs = 750;
}
