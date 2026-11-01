# Bad Apple!! as a "BADA" blob of packed 1-bit SSD1306 frames (format: README.md), the
# input to nix-badge-bling-badapple-live.
{
  pkgs,

  # A multiple of 8 (SSD1306 pages are 8 rows).
  width ? 128,
  height ? 32,

  fps ? 20,

  # A pixel is lit iff gray >= threshold.
  threshold ? 128,

  # null = the whole song (~219 s).
  durationSeconds ? null,

  # "stretch" fills the panel; "fit" letterboxes, "crop" center-crops to the panel aspect.
  scale ? "stretch",

  # A real 60 fps source: a 30 fps one baked at 60 only duplicates frames.
  badappleVideo ? pkgs.fetchurl {
    # https://archive.org/details/bad-apple-resources  (file bad_apple@60fps.mp4)
    url = "https://archive.org/download/bad-apple-resources/bad_apple%4060fps.mp4";
    name = "bad-apple-60fps.mp4";
    sha256 = "94d47ffcb5b8b045e257a52afb931059095a1b1d87c0da84e9e2a25a2c373517";
  },
}:

let
  lib = pkgs.lib;

  scaleFilter =
    let
      wh = "${toString width}:${toString height}";
    in
    {
      stretch = "scale=${wh}";
      fit = "scale=${wh}:force_original_aspect_ratio=decrease,pad=${wh}:(ow-iw)/2:(oh-ih)/2:color=black";
      crop = "crop=iw:iw*${toString height}/${toString width},scale=${wh}";
    }
    .${scale} or (throw "badapple: unknown scale strategy '${scale}' (use stretch|fit|crop)");

  durationArgs = lib.optionalString (durationSeconds != null) "-t ${toString durationSeconds}";

  fbLen = (width * height) / 8;
in

assert lib.assertMsg (height / 8 * 8 == height) "badapple: height must be a multiple of 8";

pkgs.stdenv.mkDerivation {
  pname = "badapple-blob";
  version = "1.0";

  # Not `src` or `footage`: callPackage would inject the nixpkgs attrs of those names.
  src = badappleVideo;
  dontUnpack = true;

  nativeBuildInputs = [
    pkgs.ffmpeg
    pkgs.gcc
  ];

  buildPhase = ''
    runHook preBuild

    gcc -O2 -Wall -Wextra -std=c11 -o pack ${./pack.c}

    # gray8 frames into the packer, which thresholds and packs them.
    echo "badapple: transcoding $src -> ${toString width}x${toString height} @ ${toString fps} fps (${scale})"
    ffmpeg -hide_banner -loglevel error -nostdin \
      ${durationArgs} -i "$src" \
      -vf "fps=${toString fps},${scaleFilter},format=gray" \
      -pix_fmt gray -f rawvideo - \
      | ./pack ${toString width} ${toString height} ${toString fps} ${toString threshold} \
        > badapple.bin

    runHook postBuild
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck

    size=$(stat -c%s badapple.bin)
    if [ "$size" -lt 16 ]; then
      echo "SELF-TEST FAIL: file smaller than header ($size bytes)" >&2
      exit 1
    fi

    read -r magic w h f flags fc < <(od -An -v -tx1 -N16 badapple.bin | tr -s ' ' | \
      awk '{
        # bytes: 0-3 magic, 4-5 w, 6-7 h, 8-9 fps, 10-11 flags, 12-15 count (LE)
        printf "%s%s%s%s ",$1,$2,$3,$4;                 # magic hex
        printf "%d ",   strtonum("0x"$6 $5);            # width
        printf "%d ",   strtonum("0x"$8 $7);            # height
        printf "%d ",   strtonum("0x"$10 $9);           # fps
        printf "%d ",   strtonum("0x"$12 $11);          # flags
        printf "%d\n",  strtonum("0x"$16 $15 $14 $13);  # frame_count
      }')

    echo "SELF-TEST: magic=$magic width=$w height=$h fps=$f flags=$flags frames=$fc size=$size"

    [ "$magic" = "42414441" ] || { echo "SELF-TEST FAIL: magic not 'BADA' (got $magic)" >&2; exit 1; }
    [ "$w" -eq ${toString width} ]   || { echo "SELF-TEST FAIL: width $w != ${toString width}" >&2; exit 1; }
    [ "$h" -eq ${toString height} ]  || { echo "SELF-TEST FAIL: height $h != ${toString height}" >&2; exit 1; }
    [ "$flags" -eq 0 ] || { echo "SELF-TEST FAIL: flags $flags != 0" >&2; exit 1; }
    [ "$fc" -gt 0 ]    || { echo "SELF-TEST FAIL: zero frames" >&2; exit 1; }

    expected=$(( 16 + fc * ${toString fbLen} ))
    [ "$size" -eq "$expected" ] || {
      echo "SELF-TEST FAIL: size $size != 16 + $fc*${toString fbLen} = $expected" >&2; exit 1; }

    echo "SELF-TEST PASS"

    echo "$fc $f $size" > .stats

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    install -Dm644 badapple.bin "$out/badapple.bin"

    read -r fc f size < .stats
    {
      echo "badapple.bin: packed 1-bit frame blob for a ${toString width}x${toString height} SSD1306 OLED"
      echo "format:       BADA (flags=0, uncompressed raw frames)"
      echo "width:        ${toString width}"
      echo "height:       ${toString height}"
      echo "fps:          $f"
      echo "frame_count:  $fc"
      echo "bytes/frame:  ${toString fbLen}"
      echo "total_bytes:  $size"
      echo "scale:        ${scale}"
      echo "threshold:    ${toString threshold}"
      echo "duration_cap: ${
        if durationSeconds == null then "none (full song)" else toString durationSeconds + " s"
      }"
    } > "$out/badapple.info"

    runHook postInstall
  '';

  # The source video, for other renders of it.
  passthru.video = badappleVideo;

  meta = {
    description = "Bad Apple!! as a packed 1-bit frame blob for the badge's 128x32 SSD1306 OLED";
    longDescription = ''
      badapple.bin: a 16-byte "BADA" header, then frames in SSD1306 page-major
      GDDRAM layout.
    '';
    platforms = pkgs.lib.platforms.all; # build-host tool; output is arch-neutral data
  };
}
