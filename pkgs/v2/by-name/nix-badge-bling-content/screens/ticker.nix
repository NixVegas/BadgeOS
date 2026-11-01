# A marquee of every scope field. Only the cells that can land on the panel are drawn,
# so the cost does not grow with the message.
#
#   32px (5x8 marquee; caption and clock share the top row):
#   STATUS                    1d 01:01     <- Spleen 5x8, rows 0..7
#     NIXOS 26.05.20260830.1a2b            <- 5x8 MARQUEE, y=12 (sub-page offset 4)
#   =============                          <- scroll-position line, y=24 (2 px)
#
#   64px (8x16 marquee; one detail row under it):
#   STATUS                    1d 01:01     <- Spleen 5x8, rows 2..9
#
#     NIXOS 26.05.20    <- 8x16 MARQUEE, y=25 (rows 25..40, sub-page offset 1)
#
#   ==================                     <- scroll-position line, y=45 (2 px)
#   CPU  12%   MEM  40%                    <- Spleen 5x8, rows 54..61
#
#   scope: { t; width; height; uptimeS; load1; cpuPct; memPct; batteryMv;
#            batteryPct; onUsb; ethIp; wlanIp; ethName; wlanName;
#            nixosVersion; kernelVersion; ... }
#   -> { bitmap = [ width*height/8/4 ints ]; nextMs; }
scope:
let
  d = (import ./draw.nix) { inherit (scope) width height; };
  inherit (d) width height;
  sp = d.spleen5x8;
  sp16 = d.spleen8x16;

  s = scope.uptimeS;
  days = s / 86400;
  hh = (d.mod s 86400) / 3600;
  mm = (d.mod s 3600) / 60;
  ss = d.mod s 60;
  # ~8 chars either way, so the caption row does not reflow.
  upStr =
    if days > 0 then
      "${toString days}d ${d.pad2 hh}:${d.pad2 mm}"
    else
      "${d.pad2 hh}:${d.pad2 mm}:${d.pad2 ss}";

  load1x100 = builtins.floor (scope.load1 * 100.0);
  ldStr = "${toString (load1x100 / 100)}.${d.pad2 (d.mod load1x100 100)}";

  cpu = if scope.cpuPct > 100 then 100 else scope.cpuPct;
  mem = if scope.memPct > 100 then 100 else scope.memPct;
  pct = if scope.batteryPct > 100 then 100 else scope.batteryPct;
  src = if scope.onUsb then "USB" else "BAT";

  # As in net.nix.
  shown = v: if v == "" then "--" else v;
  orQ = v: if v == "" then "?" else v;

  # Opens with a gap, so the loop point shows no seam.
  gap = "   ";
  msg =
    "${gap}UP ${upStr}"
    + "${gap}LOAD ${ldStr}"
    + "${gap}CPU ${toString cpu}% MEM ${toString mem}%"
    + "${gap}${d.fixed2 scope.batteryMv}V ${toString pct}% ${src}"
    + "${gap}${scope.ethName or "eth0"} ${shown (scope.ethIp or "")}"
    + "${gap}${scope.wlanName or "wlan0"} ${shown (scope.wlanIp or "")}"
    + "${gap}NIXOS ${orQ (scope.nixosVersion or "")}"
    + "${gap}KERNEL ${orQ (scope.kernelVersion or "")}";
  msgLen = builtins.stringLength msg;

  # 3-4 px per 120 ms frame; offset and character index both wrap, so the loop is seamless.
  pxPerSec = 30;
  scrollOf =
    face:
    let
      adv = face.advance;
      span = msgLen * adv;
      shift = d.mod (scope.t * pxPerSec / 1000) span;
    in
    {
      inherit adv shift;
      first = shift / adv; # index of the leftmost partly-visible character
      sub = d.mod shift adv; # how much of that character has already left
      nVis = width / adv + 2; # cells that can touch the panel (+1 partial each end)
      # Progress through the message, as underline pixels.
      lit = shift * width / span;
    };

  marquee =
    face: w: y:
    builtins.concatLists (
      builtins.genList (
        i:
        face.drawChar d.empty (i * w.adv - w.sub) y (builtins.substring (d.mod (w.first + i) msgLen) 1 msg)
      ) w.nVis
    );

  # A bare fillRect: far fewer entries than a drawBar.
  underline = w: y: if w.lit <= 0 then d.empty else d.fillRect d.empty 0 y w.lit 2;

  layout32 =
    let
      w = scrollOf sp;
      s0 = sp.drawText d.empty 0 0 "STATUS";
      s1 = sp.drawText s0 (width - sp.textWidth upStr) 0 upStr;
      s2 = s1 ++ marquee sp w 12; # y=12 -> sub-page offset 4
      s3 = s2 ++ underline w 24;
    in
    d.pack s3;

  layout64 =
    let
      w = scrollOf sp16;
      s0 = sp.drawText d.empty 0 2 "STATUS";
      s1 = sp.drawText s0 (width - sp.textWidth upStr) 2 upStr;
      s2 = s1 ++ marquee sp16 w 25; # y=25 -> sub-page offset 1
      s3 = s2 ++ underline w 45;
      s4 = sp.drawText s3 0 54 "CPU ${d.padLeft 3 (toString cpu)}%   MEM ${d.padLeft 3 (toString mem)}%";
    in
    d.pack s4;
in
{
  bitmap = if height >= 64 then layout64 else layout32;
  # Slower and the text visibly hops.
  nextMs = 120;
}
