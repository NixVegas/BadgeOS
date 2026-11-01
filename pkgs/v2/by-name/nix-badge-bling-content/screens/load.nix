# Load: the 1-minute load average and CPU/memory gauges.
#
#   32px:                               64px:
#   0.42   CPU 12 [==cpu==]             0.42  1 MINUTE      <- Gallant load1 + caption
#   LOAD   MEM 40 [==mem==]
#                                       CPU  12% [====cpu====]  <- full-width gauge
#                                       MEM  40% [====mem====]  <- full-width gauge
#
#   scope: { t; width; height; batteryMv; batteryPct; onUsb; load1; cpuPct; memPct; uptimeS }
#   -> { bitmap = [ width*height/8/4 ints ]; nextMs; }
scope:
let
  d = (import ./draw.nix) { inherit (scope) width height; };
  inherit (d) width height;
  sp = d.spleen5x8;

  # load1 is a float; "X.XX", truncated.
  load1x100 = builtins.floor (scope.load1 * 100.0);
  ldWhole = load1x100 / 100;
  ldHund = d.mod load1x100 100;
  ldStr = "${toString ldWhole}.${d.pad2 ldHund}";

  cpu = if scope.cpuPct > 100 then 100 else scope.cpuPct;
  mem = if scope.memPct > 100 then 100 else scope.memPct;
  cpuFrac = cpu * 1.0 / 100.0;
  memFrac = mem * 1.0 / 100.0;

  layout32 =
    let
      s0 = d.drawText d.empty 0 0 ldStr;
      s1 = sp.drawText s0 0 (height - sp.height) "LOAD";
      heroRight = d.textWidth ldStr;
      tagX = if heroRight + 6 < 60 then 60 else heroRight + 6;
      cpuLabel = "CPU ${toString cpu}";
      memLabel = "MEM ${toString mem}";
      labelW = sp.textWidth "CPU 100"; # reserve for up to 3 digits
      barX = tagX + labelW + 3;
      barW = width - barX;
      s2 = sp.drawText s1 tagX 3 cpuLabel;
      s3 = if barW >= 8 then d.drawBar s2 barX 2 barW 9 cpuFrac else s2;
      s4 = sp.drawText s3 tagX 19 memLabel;
      s5 = if barW >= 8 then d.drawBar s4 barX 18 barW 9 memFrac else s4;
    in
    d.pack s5;

  layout64 =
    let
      s0 = d.drawText d.empty 0 0 ldStr;
      capY = (d.gallant.height - sp.height) / 2;
      s1b = sp.drawText s0 (d.textWidth ldStr + 6) capY "1 MINUTE";

      # Two gauges filling the band below the hero.
      tag = t: v: "${t} ${d.padLeft 3 (toString v)}%";
      tagW = sp.textWidth "MEM 100%"; # 8 chars
      barX = tagW + 4;
      barW = width - barX;
      bandTop = d.gallant.height + 3;
      bandH = height - bandTop;
      gap = 4;
      barH = (bandH - gap) / 2;
      row0Y = bandTop;
      row1Y = bandTop + barH + gap;
      tagOff = (barH - sp.height) / 2;

      c0 = sp.drawText s1b 0 (row0Y + tagOff) (tag "CPU" cpu);
      c1 = d.drawBar c0 barX row0Y barW barH cpuFrac;
      m0 = sp.drawText c1 0 (row1Y + tagOff) (tag "MEM" mem);
      m1 = d.drawBar m0 barX row1Y barW barH memFrac;
    in
    d.pack m1;
in
{
  bitmap = if height >= 64 then layout64 else layout32;
  nextMs = 500;
}
