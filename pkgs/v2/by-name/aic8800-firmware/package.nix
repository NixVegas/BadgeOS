# Firmware for the AICSemi AIC8800 SDIO WiFi chips, where the aic8800 driver filp_open()s
# it (through hardware.firmware): one directory per variant, aic8800D80 by default.
{
  pkgs,
  # Directories of the tree's src/SDIO/driver_fw/fw, such as aic8800D80 or aic8800.
  variants ? [ "aic8800D80" ],
}:
let
  # The aic8800 driver pins the same rev. A let binding, not a formal: callPackage
  # would inject nixpkgs' top-level `src` alias.
  src = pkgs.fetchFromGitHub {
    owner = "radxa-pkg";
    repo = "aic8800";
    rev = "bd11969265809a0fc948f1107c8256bbb2c1aa60";
    hash = "sha256-7M02L7G/cadlUWF3YG5CAumtmV7RmEbRHWqZQTddRUI=";
  };
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "aic8800-firmware";
  version = "6.4.3.0-unstable-2026-06-20";

  inherit src;

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    dst="$out/lib/firmware/aic8800_fw/SDIO"
    mkdir -p "$dst"
  ''
  + pkgs.lib.concatMapStrings (
    v:
    ''
      cp -r src/SDIO/driver_fw/fw/${v} "$dst/${v}"
      chmod -R u+w "$dst/${v}"
    ''
    + pkgs.lib.optionalString (v == "aic8800D80") ''

      # The radxa and milkv fmac builds never confirm START_APP on this chip: overlay the
      # cv181x set from the Debian image's firmware-aic8800-cv181x 2024.10.14-2.
      cp -f ${./debian-fw}/* "$dst/aic8800D80/"
    ''
  ) variants
  + ''
    runHook postInstall
  '';

  # The driver filp_open()s the bare .bin names, which does not decompress.
  passthru.compressFirmware = false;

  meta = {
    description = "AICSemi AIC8800 SDIO WiFi vendor firmware blobs";
    license = pkgs.lib.licenses.unfreeRedistributableFirmware;
  };
}
