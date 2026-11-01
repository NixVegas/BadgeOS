# A scrolling ECG trace that beats faster as load1 rises. A screen keeps no state between
# frames, so the trace is a function of `scope.t` and shows only the current rate, not a
# history.
#
#   32px (one header row, then the trace owns the rest):
#   PULSE                         0.42    <- Spleen 5x8, rows 0..7
#        /\            /\            /\   <- R spike, band top (row 10)
#   _/\_/  \__/\__/\_/  \__/\__/\_/  \_   <- ECG trace, band rows 10..31
#
#   64px (header, trace band, two detail rows):
#   SYS PULSE                LOAD 0.42    <- Spleen 5x8, rows 0..7
#        /\            /\            /\   <- R spike, band top (row 12)
#   _/\_/  \__/\__/\_/  \__/\__/\_/  \_   <- ECG trace, band rows 12..45
#
#   CPU  12%   MEM  40%                   <- Spleen 5x8, rows 48..55
#   RATE 40/min  BAT 87%                  <- Spleen 5x8, rows 56..63
#
#   scope: { t; width; height; load1; cpuPct; memPct; batteryPct; ... }
#   -> { bitmap = [ width*height/8/4 ints ]; nextMs; }
let
  # One hand-drawn PQRST complex, 24 samples around a 0 baseline. Above `scope:` so it is
  # built once (see effects/README.md).
  ecg = [
    0
    1
    2
    3
    2
    1
    0
    0
    (-2)
    6
    14
    6
    (-4)
    (-1)
    0
    0
    1
    3
    4
    3
    2
    1
    0
    0
  ];
  ecgLen = 24;
  ecgHi = 14; # max sample (the R spike)
  ecgSpan = 18; # ecgHi - min sample (-4): the full vertical swing, in units
in
scope:
let
  d = (import ./draw.nix) { inherit (scope) width height; };
  inherit (d) width height;
  sp = d.spleen5x8;

  load1x100 = builtins.floor (scope.load1 * 100.0);
  ldStr = "${toString (load1x100 / 100)}.${d.pad2 (d.mod load1x100 100)}";
  cpu = if scope.cpuPct > 100 then 100 else scope.cpuPct;
  mem = if scope.memPct > 100 then 100 else scope.memPct;
  bat = if scope.batteryPct > 100 then 100 else scope.batteryPct;

  # Five load buckets -> beat periods of 56 px down to 24 (back-to-back complexes). The
  # phase comes from t and jumps when the period changes, so keep the changes rare.
  bucket =
    let
      b = builtins.floor (scope.load1 * 4.0);
    in
    if b < 0 then
      0
    else if b > 4 then
      4
    else
      b;
  period = 56 - 8 * bucket;

  # 4 px per 125 ms frame.
  pxPerSec = 32;
  shift = scope.t * pxPerSec / 1000;
  bpm = 60 * pxPerSec / period;

  bandTop = if height >= 64 then 12 else 10;
  bandH = if height >= 64 then 34 else 22;
  vspan = bandH - 1; # pixels the full unit swing maps onto
  # Row of the 0-unit baseline: the R spike (ecgHi) must land on bandTop.
  baseRow = bandTop + (ecgHi * vspan) / ecgSpan;
  rowOf = v: baseRow - (v * vspan) / ecgSpan;

  # One sample per column, plus one so the last column has a neighbour.
  ys = builtins.genList (
    x:
    let
      j = d.mod (x + shift) period;
    in
    rowOf (if j < ecgLen then builtins.elemAt ecg j else 0)
  ) (width + 1);

  # Join consecutive samples with a vertical run.
  traceEntries = builtins.concatLists (
    builtins.genList (
      x:
      let
        a = builtins.elemAt ys x;
        b = builtins.elemAt ys (x + 1);
        lo = if a < b then a else b;
        hi = if a < b then b else a;
      in
      d.vline d.empty x lo (hi - lo + 1)
    ) width
  );

  layout32 =
    let
      s0 = sp.drawText d.empty 1 0 "PULSE";
      s1 = sp.drawText s0 (width - sp.textWidth ldStr - 1) 0 ldStr;
    in
    d.pack (s1 ++ traceEntries);

  layout64 =
    let
      lab = "LOAD ${ldStr}";
      s0 = sp.drawText d.empty 1 0 "SYS PULSE";
      s1 = sp.drawText s0 (width - sp.textWidth lab - 1) 0 lab;
      s2 = (s1 ++ traceEntries);
      s3 = sp.drawText s2 1 48 "CPU ${d.padLeft 3 (toString cpu)}%   MEM ${d.padLeft 3 (toString mem)}%";
      s4 = sp.drawText s3 1 56 "RATE ${toString bpm}/min  BAT ${toString bat}%";
    in
    d.pack s4;
in
{
  bitmap = if height >= 64 then layout64 else layout32;
  # The slowest rate that still reads as a sweep.
  nextMs = 125;
}
