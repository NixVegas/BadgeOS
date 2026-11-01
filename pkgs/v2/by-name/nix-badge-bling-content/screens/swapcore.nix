# The core-swap hold indicator. `hidden` keeps it out of the cycle (the bootswap daemon
# jumps here when the BOOT hold starts) and `autoReturnMs` returns to the previous screen.
#
#   scope: { t; width; height; strap; ... } -> { bitmap; nextMs; hidden; autoReturnMs; }
scope:
let
  d = (import ./draw.nix) { inherit (scope) width height; };
  inherit (d) width height;
  sp = d.spleen5x8;

  sys = builtins.currentSystem;
  firstDash =
    s:
    let
      n = builtins.stringLength s;
      hit = builtins.filter (i: builtins.substring i 1 s == "-") (builtins.genList (i: i) n);
    in
    if hit == [ ] then n else builtins.head hit;
  arch = builtins.substring 0 (firstDash sys) sys;

  # The hold latches the strap to the other core, so NEXT is the opposite of the strap.
  strapCode = scope.strap or 0;
  targetName =
    if strapCode == 1 then
      "RISCV"
    else if strapCode == 2 then
      "ARM"
    else
      "?";

  centreX =
    face: s:
    let
      x = (width - face.textWidth s) / 2;
    in
    if x < 0 then 0 else x;

  # ~2 Hz blink
  mod = a: b: a - (a / b) * b;
  blink = mod (scope.t / 250) 2 == 0;

  hero = "CORE SWAP";
  nowStr = "NOW ${arch}";
  nextStr = "NEXT ${targetName}";
  holdStr = "HOLD TO SWAP";

  # NOW and NEXT side by side would collide (~126 of 128 px).
  #
  #   64px:                            32px (no room for a hero cell):
  #   CORE SWAP     <- Gallant hero    CORE SWAP   HOLD  <- title + blink
  #   NOW aarch64                      NOW aarch64
  #   NEXT RISCV                       NEXT RISCV
  #   HOLD TO SWAP  <- blinking
  layout64 =
    let
      s0 = d.drawText d.empty (centreX d.gallant hero) 0 hero;
      rowY = d.gallant.height + 4;
      s1 = sp.drawText s0 4 rowY nowStr;
      s2 = sp.drawText s1 4 (rowY + sp.height + 2) nextStr;
      s3 = if blink then sp.drawText s2 (centreX sp holdStr) (height - sp.height - 1) holdStr else s2;
    in
    d.pack s3;
  layout32 =
    let
      s0 = sp.drawText d.empty 1 1 hero;
      s1 = if blink then sp.drawText s0 (width - sp.textWidth "HOLD" - 1) 1 "HOLD" else s0;
      s2 = sp.drawText s1 4 12 nowStr;
      s3 = sp.drawText s2 4 22 nextStr;
    in
    d.pack s3;
in
{
  bitmap = if height >= 64 then layout64 else layout32;
  nextMs = 100;
  hidden = true;
  autoReturnMs = 5000;
}
