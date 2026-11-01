# Uptime clock: HH:MM:SS (or "NdHH:MM" past a day) with a blinking colon, the raw
# seconds, and a seconds-of-minute bar.
#
#   32px:                             64px:
#   12:34:56                          UPTIME              <- Spleen caption (top)
#   UP 90061s                         12:34:56            <- Gallant clock, centred
#   [===seconds bar===]               UP 90061s           <- Spleen raw seconds
#                                     [===seconds bar===]  <- tall seconds-of-minute bar
#
#   scope: { t; width; height; batteryMv; batteryPct; onUsb; load1; cpuPct; memPct; uptimeS }
#   -> { bitmap = [ width*height/8/4 ints ]; nextMs; }
scope:
let
  d = (import ./draw.nix) { inherit (scope) width height; };
  inherit (d) width height;
  sp = d.spleen5x8;

  s = scope.uptimeS;
  days =
    let
      x = s / 86400;
    in
    if x > 999 then 999 else x;
  hh = d.mod (d.mod s 86400) 86400 / 3600;
  mm = d.mod (d.mod s 3600) 3600 / 60;
  ss = d.mod s 60;

  # The colon shows in the first half of each second.
  sep = if d.mod scope.t 1000 < 500 then ":" else " ";

  bigStr =
    if days > 0 then
      "${toString days}d${d.pad2 hh}${sep}${d.pad2 mm}"
    else
      "${d.pad2 hh}${sep}${d.pad2 mm}${sep}${d.pad2 ss}";

  tx =
    let
      x = (width - d.textWidth bigStr) / 2;
    in
    if x < 0 then 0 else x;

  secsFrac = (d.mod s 60) * 1.0 / 60.0;
  cap = "UP ${toString s}s";
  cx =
    let
      x = (width - sp.textWidth cap) / 2;
    in
    if x < 0 then 0 else x;

  layout32 =
    let
      s0 = d.drawText d.empty tx 0 bigStr;
      capY = height - 2 - sp.height; # rows 22..29, leaving 2px for the bar
      s1 = sp.drawText s0 cx capY cap;
      s2 = d.drawBar s1 0 (height - 2) width 2 secsFrac;
    in
    d.pack s2;

  layout64 =
    let
      topCap = "UPTIME";
      tcX =
        let
          x = (width - sp.textWidth topCap) / 2;
        in
        if x < 0 then 0 else x;
      s0 = sp.drawText d.empty tcX 2 topCap;

      clockY = (height - d.gallant.height) / 2;
      s1 = d.drawText s0 tx clockY bigStr;

      capY = clockY + d.gallant.height + 2;
      s2 = sp.drawText s1 cx capY cap;

      barH = 8;
      s3 = d.drawBar s2 0 (height - barH) width barH secsFrac;
    in
    d.pack s3;
in
{
  bitmap = if height >= 64 then layout64 else layout32;
  nextMs = 250;
}
