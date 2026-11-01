# The badge's IPv4 addresses. wlan0 draws a fresh MAC, and so a fresh lease, every boot.
#   scope.ethIp / scope.wlanIp     the addresses; empty with no interface or no lease
#   scope.ethName / scope.wlanName the names, from badge.oled.{eth,wlan}Interface
#
#   32px:                             64px:
#   eth0 192.0.2.10                   net                 <- Spleen caption
#   wlan0 192.0.2.11                  eth0                <- name
#                                     192.0.2.10          <- address
#                                     wlan0
#                                     192.0.2.11
#
#   scope: { t; width; height; ethIp; wlanIp; ethName; wlanName; ... }
#   -> { bitmap = [ width*height/8/4 ints ]; nextMs; }
scope:
let
  d = (import ./draw.nix) { inherit (scope) width height; };
  inherit (d) width height;
  sp = d.spleen5x8;

  # "--", so no lease looks different from a drawing bug.
  shown = s: if s == "" then "--" else s;
  eth = shown (scope.ethIp or "");
  wlan = shown (scope.wlanIp or "");

  ethName = scope.ethName or "eth0";
  wlanName = scope.wlanName or "wlan0";

  centreX =
    face: s:
    let
      x = (width - face.textWidth s) / 2;
    in
    if x < 0 then 0 else x;

  # 25 columns fit; "wlan0 255.255.255.255" is 21.
  layout32 =
    let
      s0 = sp.drawText d.empty 0 2 "${ethName} ${eth}";
      s1 = sp.drawText s0 0 (2 + sp.height + 4) "${wlanName} ${wlan}";
    in
    d.pack s1;

  layout64 =
    let
      cap = "net";
      s0 = sp.drawText d.empty (centreX sp cap) 2 cap;
      s1 = sp.drawText s0 2 16 ethName;
      s2 = sp.drawText s1 2 26 eth;
      s3 = sp.drawText s2 2 40 wlanName;
      s4 = sp.drawText s3 2 50 wlan;
    in
    d.pack s4;
in
{
  bitmap = if height >= 64 then layout64 else layout32;
  # Live, for someone waiting on a lease.
  nextMs = 1000;
}
