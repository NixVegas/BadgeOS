# The running core's arch (from builtins.currentSystem) and the core the boot-select
# strap picks next. They differ while a core swap is pending.
#
#   32px:                             64px:
#   aarch64                           SYSTEM              <- Spleen caption (top)
#   STRAP ARM                         aarch64             <- Gallant arch hero, centred
#                                     STRAP ARM           <- Spleen strap readout (bottom)
#
#   scope: { t; width; height; strap; batteryMv; batteryPct; onUsb; load1; cpuPct; memPct; uptimeS }
#   -> { bitmap = [ width*height/8/4 ints ]; nextMs; }
scope:
let
  d = (import ./draw.nix) { inherit (scope) width height; };
  inherit (d) width height;
  sp = d.spleen5x8;

  sys = builtins.currentSystem;

  # Index of the first "-" in `s`, or its length.
  firstDash =
    s:
    let
      n = builtins.stringLength s;
      hit = builtins.filter (i: builtins.substring i 1 s == "-") (builtins.genList (i: i) n);
    in
    if hit == [ ] then n else builtins.head hit;

  dash = firstDash sys;
  arch = builtins.substring 0 dash sys; # e.g. "aarch64"

  # scope.strap: 0 unknown, 1 arm, 2 riscv.
  strapCode = scope.strap or 0;
  strapName =
    if strapCode == 1 then
      "ARM"
    else if strapCode == 2 then
      "RISCV"
    else
      "?";
  strapStr = "STRAP ${strapName}";

  centreX =
    face: s:
    let
      x = (width - face.textWidth s) / 2;
    in
    if x < 0 then 0 else x;

  layout32 =
    let
      s0 = d.drawText d.empty (centreX d.gallant arch) 0 arch;
      s1 = sp.drawText s0 (centreX sp strapStr) (height - sp.height) strapStr;
    in
    d.pack s1;

  layout64 =
    let
      topCap = "SYSTEM";
      s0 = sp.drawText d.empty (centreX sp topCap) 2 topCap;

      heroY = 18;
      s1 = d.drawText s0 (centreX d.gallant arch) heroY arch;

      s2 = sp.drawText s1 (centreX sp strapStr) (height - sp.height - 2) strapStr;
    in
    d.pack s2;
in
{
  bitmap = if height >= 64 then layout64 else layout32;
  nextMs = 1000;
}
