# The evaluator's own frame rate, against the 62 fps Bad Apple manages:
#   scope.fps         the measured rate over a 3-second window; 0 until the first closes
#   scope.backend     0 = fix, 1 = nix (an int, so no backend interns a string per frame)
#   scope.frameIndex  the applied-frame counter
#
#   32px:                              64px:
#   57   FPS                              EVAL RATE          <- Spleen caption
#        fix 17ms                             57             <- Gallant hero
#   [======= 57/62 ======]              fix    17 ms/frame    <- Spleen detail
#                                       FRAME 4242            <- Spleen counter
#                                       [===== 57/62 =====]   <- rate vs ceiling
#
#   scope: { t; width; height; fps; backend; frameIndex; ... }
#   -> { bitmap = [ width*height/8/4 ints ]; nextMs; }
scope:
let
  d = (import ./draw.nix) { inherit (scope) width height; };
  inherit (d) width height;
  sp = d.spleen5x8;

  fps = scope.fps or 0;

  backendName =
    let
      b = scope.backend or 0;
    in
    if b == 0 then
      "fix"
    else if b == 1 then
      "nix"
    else
      "?";

  # 0 fps: the first window has not closed yet.
  running = fps > 0;
  heroStr = if running then toString fps else "--";
  msStr = if running then "${toString (1000 / fps)} ms/frame" else "measuring";

  ceiling = 62;
  frac =
    let
      f = fps * 1.0 / (ceiling * 1.0);
    in
    if f > 1.0 then 1.0 else f;

  centreX =
    face: s:
    let
      x = (width - face.textWidth s) / 2;
    in
    if x < 0 then 0 else x;

  layout32 =
    let
      s0 = d.drawText d.empty 0 0 heroStr;
      colX = d.textWidth heroStr + 4;
      s1 = sp.drawText s0 colX 2 "FPS";
      s2 =
        sp.drawText s1 colX 12
          "${backendName} ${if running then "${toString (1000 / fps)}ms" else "--"}";
      s3 = d.drawBar s2 0 24 width 8 frac;
    in
    d.pack s3;

  layout64 =
    let
      cap = "EVAL RATE";
      s0 = sp.drawText d.empty (centreX sp cap) 1 cap;
      s1 = d.drawText s0 (centreX d.gallant heroStr) 12 heroStr;
      s2 = sp.drawText s1 1 37 backendName;
      s3 = sp.drawText s2 (width - sp.textWidth msStr - 1) 37 msStr;
      s4 = sp.drawText s3 1 46 "FRAME ${toString (scope.frameIndex or 0)}";
      s5 = d.drawBar s4 0 55 width 9 frac;
    in
    d.pack s5;
in
{
  bitmap = if height >= 64 then layout64 else layout32;
  # The measurement moves on a 3-second window; redrawing faster only costs the core.
  nextMs = 500;
}
