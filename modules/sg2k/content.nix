# The default OLED/LED content (oled.d/, bling.d/, lib/): nix-badge-content seeds
# /etc/nix-badge from it, for either engine, and it is hackable in place there.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  contentTree = pkgs.buildPackages.nix-badge-bling-content {
    height = 64;
    fps = 60;
    durationSeconds = null;
    keyframeInterval = 60;
  };
  seedContent = config.badge.bling.enable || config.badge.oled.enable;
in
{
  config = lib.mkIf config.hardware.sg2k.enable {
    badge.bling.evalPattern = "${contentTree}/bling.d/10-rainbow.nix";
    badge.oled.evalDir = "/etc/nix-badge/oled.d";

    systemd.tmpfiles.rules = lib.mkIf seedContent [ "d /etc/nix-badge 0755 root root -" ];

    systemd.services.nix-badge-content = lib.mkIf seedContent {
      description = "Seed /etc/nix-badge with default OLED/LED content (hackable in place)";
      # In sysinit, so the oled engine (ordered after it) starts early.
      wantedBy = [ "sysinit.target" ];
      before = [ "nix-badge-oled.service" ];
      after = [
        "systemd-tmpfiles-setup.service"
        "local-fs.target"
      ];
      unitConfig.DefaultDependencies = false;
      unitConfig.ConditionPathIsReadWrite = "/etc";
      path = [
        pkgs.coreutils
        pkgs.findutils
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -eu
        src="${contentTree}"
        dst=/etc/nix-badge
        # A store symlink at /etc/nix-badge becomes a real directory.
        [ -L "$dst" ] && rm -f "$dst"
        mkdir -p "$dst"
        # Link every default, but never over a user's regular file.
        while IFS= read -r -d "" f; do
          rel="''${f#"$src"/}"
          target="$dst/$rel"
          mkdir -p "$(dirname "$target")"
          if [ -f "$target" ] && [ ! -L "$target" ]; then
            continue
          fi
          ln -sfn "$f" "$target"
        done < <(find "$src" \( -type f -o -type l \) -print0)
        # Prune store links that are no longer defaults (a user's own store link too).
        while IFS= read -r -d "" l; do
          rel="''${l#"$dst"/}"
          case "$(readlink "$l")" in
            /nix/store/*) [ -e "$src/$rel" ] || rm -f "$l" ;;
          esac
        done < <(find "$dst" -type l -print0)
        # And dangling ones.
        find "$dst" -type l ! -exec test -e {} \; -delete
      '';
    };
  };
}
