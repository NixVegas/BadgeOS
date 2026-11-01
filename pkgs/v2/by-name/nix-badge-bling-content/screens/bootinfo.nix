# Boot info, also the initrd splash: the NixOS version, kernel release and arch. The
# runtime reads the versions once at startup; an empty one renders as "?".
#
#   32px:                             64px:
#   NixOS 26.05      <- Spleen 8x16   NIXOS               <- Spleen caption (top)
#   6.18.44-xanmod1  <- Spleen 5x8    26.05               <- Gallant short-version hero
#   aarch64          <- Spleen 5x8    26.05.20260830.ab   <- Spleen full version
#                                     KERNEL 6.18.44-xan  <- Spleen kernel release
#                                     aarch64             <- Spleen arch (bottom)
#
#   With a data card in use (scope.storage is "card <device>", from
#   nix-badge-storage-mode) the arch line reads e.g. "aarch64 DATA CARD".
#
#   scope: { t; width; height; nixosVersion; kernelVersion; storage; ... }
#   -> { bitmap = [ width*height/8/4 ints ]; nextMs; }
scope:
let
  d = (import ./draw.nix) { inherit (scope) width height; };
  inherit (d) width height;
  sp = d.spleen5x8;
  sp16 = d.spleen8x16;

  orQ = s: if s == "" then "?" else s;
  ver = orQ (scope.nixosVersion or "");
  kern = orQ (scope.kernelVersion or "");

  # Arch = currentSystem up to the first "-".
  sys = builtins.currentSystem;
  firstIx =
    ch: s:
    let
      n = builtins.stringLength s;
      hit = builtins.filter (i: builtins.substring i 1 s == ch) (builtins.genList (i: i) n);
    in
    if hit == [ ] then n else builtins.head hit;
  arch = builtins.substring 0 (firstIx "-" sys) sys; # e.g. "aarch64"
  card = builtins.substring 0 5 (scope.storage or "") == "card ";
  archLine = if card then "${arch} DATA CARD" else arch;

  # Short version for the hero: up to the second dot ("26.05.20260830.ab" -> "26.05";
  # "26.05" and "?" pass through whole).
  verShort =
    let
      d1 = firstIx "." ver;
      rest = builtins.substring (d1 + 1) (builtins.stringLength ver) ver;
      d2 = d1 + 1 + firstIx "." rest;
    in
    builtins.substring 0 d2 ver;

  # The rest after the hero ("26.05.20260830.ab" -> "20260830.ab"); may be empty.
  verTail = builtins.substring (builtins.stringLength verShort + 1) (builtins.stringLength ver) ver;

  centreX =
    face: s:
    let
      x = (width - face.textWidth s) / 2;
    in
    if x < 0 then 0 else x;

  layout32 =
    let
      title = "NixOS ${verShort}";
      s0 = sp16.drawText d.empty (centreX sp16 title) 0 title;
      s1 = sp.drawText s0 (centreX sp kern) 16 kern;
      s2 = sp.drawText s1 (centreX sp archLine) 24 archLine;
    in
    d.pack s2;

  layout64 =
    let
      topCap = "NIXOS";
      s0 = sp.drawText d.empty (centreX sp topCap) 0 topCap;
      s1 = d.drawText s0 (centreX d.gallant verShort) 10 verShort;
      s2 = if verTail != "" then sp.drawText s1 (centreX sp verTail) 36 verTail else s1;
      s3 = sp.drawText s2 (centreX sp kern) 46 kern;
      s4 = sp.drawText s3 (centreX sp archLine) 56 archLine;
    in
    d.pack s4;
in
{
  bitmap = if height >= 64 then layout64 else layout32;
  nextMs = 5000; # static readout; nothing animates
}
