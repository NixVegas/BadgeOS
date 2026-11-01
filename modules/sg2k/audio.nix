{
  config,
  lib,
  pkgs,
  ...
}:
{
  config = lib.mkIf config.hardware.sg2k.enable (
    lib.mkMerge [
      # mpd with PipeWire, unconditionally, so the package set does not depend on the board.
      {
        nixpkgs.overlays = [ (import ../../pkgs/v2/overlays/mpd.nix) ];
      }

      (lib.mkIf config.hardware.sg2k.hdmi.audio {
        services.pipewire = {
          enable = true;
          systemWide = true;
          alsa.enable = true;
          pulse.enable = true;
          wireplumber.enable = true;

          # The LT8912B's I2S input is 16-bit only: S24_LE, which PipeWire would pick,
          # plays silence.
          wireplumber.extraConfig."51-lt8912b-s16" = {
            "monitor.alsa.rules" = [
              {
                matches = [ { "node.name" = "~alsa_output.*"; } ];
                actions.update-props = {
                  "audio.format" = "S16LE";
                  "audio.rate" = 48000;
                };
              }
            ];
          };
        };

        security.rtkit.enable = true;
        users.users.badge.linger = true;
        users.users.badge.extraGroups = [ "pipewire" ];

        services.mpd = {
          enable = true;
          user = "badge";
          settings.audio_output = [
            {
              type = "pipewire";
              name = "PipeWire";
            }
          ];
        };

        systemd.services.mpd.environment.PIPEWIRE_RUNTIME_DIR = "/run/pipewire";

        environment.systemPackages = [
          pkgs.mpc
          pkgs.alsa-utils
        ];
      })
    ]
  );
}
