# The generation image: each toplevel links its boot.itb (every profile, signed under
# hardware.sg2k.secureBoot) as ${toplevel}/boot-image. makeBootImage is a specialArg bound
# to the build host, where the signing runs.
{
  config,
  lib,
  makeBootImage,
  ...
}:
{
  config = lib.mkIf config.hardware.sg2k.enable {
    system.build.bootImage = makeBootImage {
      sys = { inherit config; };
      inherit (config.hardware.sg2k) core fitKeyCert;
      secure = config.hardware.sg2k.secureBoot;
      raucExternal = config.hardware.sg2k.emmc.enable;
      dataCard = config.hardware.sg2k.externalStorage.enable;
    };

    # One image covers every profile, so only the base toplevel links it.
    system.systemBuilderCommands = lib.mkIf (!config.badge.isSpecialisation) ''
      ln -s ${config.system.build.bootImage} $out/boot-image
    '';
  };
}
