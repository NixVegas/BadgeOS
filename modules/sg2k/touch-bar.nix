# The touch menu, its settings and managed session applications.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.badge.graphics.touchBar;
  graphics = config.badge.graphics;
  sg2k = config.hardware.sg2k;
  enabled = sg2k.enable && graphics.enable && cfg.enable;
  managedAudio = config.services.pipewire.enable && !config.services.pipewire.socketActivation;
  tools = pkgs.badge-panel-tools.override { withAudio = managedAudio; };
  wifi = sg2k.wifi.enable && sg2k.wifi.onDemand;
  bluetooth = wifi && config.hardware.bluetooth.enable;
  settings =
    lib.optional wifi {
      id = "wifi";
      label = "WiFi";
      unit = "nix-badge-wifi.service";
      status_command = lib.getExe' tools "badge-panel-wifi-status";
      stop_command = lib.getExe' tools "badge-panel-wifi-disable";
      join_app = "wifi-join";
      join_label = "Join…";
    }
    ++ lib.optional bluetooth {
      id = "bluetooth";
      label = "Bluetooth";
      unit = "badge-panel-bluetooth.service";
      status_command = lib.getExe' tools "badge-panel-bluetooth-status";
      stop_command = lib.getExe' tools "badge-panel-bluetooth-disable";
      join_app = "bluetooth-devices";
      join_label = "Devices…";
    };
  barHeight = 48;
  fontSize = 14;
  font = "DejaVu Sans";
  footApp = args: "${lib.getExe pkgs.foot} ${args} --font=DejaVuSansMono:size=10";
  keyboard = pkgs.writeShellApplication {
    name = "badge-panel-keyboard";
    runtimeInputs = [ pkgs.wvkbd ];
    runtimeEnv = {
      BADGE_FONT = font;
    };
    text = builtins.readFile ../../pkgs/v2/by-name/badge-touch-bar/keyboard.sh;
  };
  keyboardReady = pkgs.writeShellApplication {
    name = "badge-keyboard-ready";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.readFile ../../pkgs/v2/by-name/badge-touch-bar/wait-keyboard.sh;
  };
  appType = lib.types.submodule (
    { name, ... }: {
      options = {
        label = lib.mkOption {
          type = lib.types.str;
          description = "Label in the launcher.";
        };
        command = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Command of the generated user service; null for a system app.";
        };
        unit = lib.mkOption {
          type = lib.types.str;
          default = "badge-app-${name}.service";
          description = "Service owning the app process.";
        };
        appId = lib.mkOption {
          type = lib.types.str;
          default = "badge-${name}";
          description = "Wayland app_id of the main window.";
        };
        group = lib.mkOption {
          type = lib.types.nullOr (lib.types.strMatching "[A-Za-z0-9][A-Za-z0-9_-]*");
          default = null;
          description = "Launcher group, or null for Home.";
        };
        hidden = lib.mkEnableOption "launching this app from Settings instead of Home";
        system = lib.mkEnableOption "system service control by the session user";
        keyboard = lib.mkEnableOption "the on-screen keyboard for this app";
        hideBar = lib.mkEnableOption "hiding the bar while the app provides its own exit";
      };
    }
  );
  visibleApps = lib.filterAttrs (_: app: !app.hidden) cfg.apps;
  groups = lib.unique (
    lib.filter (g: g != null) (map (app: app.group) (builtins.attrValues visibleApps))
  );
  swaymsg = "${config.programs.sway.package}/bin/swaymsg";
  windowReady = pkgs.writeShellScript "badge-window-ready" ''
    while ! ${swaymsg} -r -t get_tree | ${lib.getExe pkgs.jq} -e --arg id "$1" 'any(.. | objects; .app_id? == $id)' >/dev/null; do
      ${pkgs.coreutils}/bin/sleep 0.5
    done
  '';
  windowClose = pkgs.writeShellScript "badge-window-close" ''
    ${swaymsg} -q "[app_id=\"$1\"] kill"
    exec ${pkgs.coreutils}/bin/tail --pid="$MAINPID" -f /dev/null
  '';
  appUnits = lib.mapAttrs' (
    _: app:
    lib.nameValuePair (lib.removeSuffix ".service" app.unit) {
      description = lib.mkDefault "Panel ${app.label}";
      unitConfig.ConditionUser = "badge";
      serviceConfig = {
        Type = lib.mkDefault "exec";
        ExecStart = app.command;
        ExecStartPre = lib.mkIf app.hideBar "-${swaymsg} -q bar touch mode invisible";
        ExecStartPost = "${windowReady} ${lib.escapeShellArg app.appId}";
        TimeoutStartSec = cfg.limits.start;
        ExecStop = lib.mkIf (!app.hideBar) "${windowClose} ${lib.escapeShellArg app.appId}";
        ExecStopPost = lib.mkIf app.hideBar "-${swaymsg} -q bar touch mode dock";
        TimeoutStopSec = lib.mkIf (!app.hideBar) (lib.mkDefault cfg.limits.stop);
        SuccessExitStatus = lib.optionals (lib.hasPrefix "${lib.getExe pkgs.foot} " app.command) [ 1 ];
      };
    }
  ) (lib.filterAttrs (_: app: !app.system) cfg.apps);
  systemApps = map (a: a.unit) (lib.filter (a: a.system) (builtins.attrValues cfg.apps));
  settingUnits = map (s: s.unit) settings;
  # Games lead the menu in this order; the other apps follow by name.
  rank =
    id:
    lib.lists.findFirstIndex (n: n == id) 4 [
      "doom"
      "quake"
      "demo"
      "cube"
    ];
  configFile = pkgs.writeText "badge-touch-bar.json" (
    builtins.toJSON {
      output = graphics.outputName;
      inherit (cfg) backlight;
      inherit settings;
      apps = lib.sort (a: b: rank a.id < rank b.id) (
        lib.mapAttrsToList (id: app: {
          inherit id;
          inherit (app)
            label
            hidden
            group
            unit
            system
            ;
          app_id = app.appId;
          keyboard_unit =
            if app.keyboard then
              "badge-panel-keyboard@${lib.removeSuffix ".service" app.unit}.service"
            else
              null;
        }) cfg.apps
      );
    }
  );
in
{
  options.badge.graphics.touchBar = {
    enable = lib.mkEnableOption "touch menu and managed applications on the panel desktop" // {
      default = sg2k.dsiPanel.enable && graphics.enable;
      defaultText = lib.literalExpression "config.hardware.sg2k.dsiPanel.enable && config.badge.graphics.enable";
    };
    limits.start = lib.mkOption {
      type = lib.types.ints.positive;
      default = if pkgs.stdenv.hostPlatform.isRiscV then 140 else 30;
      defaultText = lib.literalExpression "if pkgs.stdenv.hostPlatform.isRiscV then 140 else 30";
      description = "Seconds an app or a setting may take to start.";
    };
    limits.stop = lib.mkOption {
      type = lib.types.ints.positive;
      default = if pkgs.stdenv.hostPlatform.isRiscV then 35 else 25;
      defaultText = lib.literalExpression "if pkgs.stdenv.hostPlatform.isRiscV then 35 else 25";
      description = "Seconds an app or a setting may take to stop.";
    };
    backlight = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = if sg2k.dsiPanel.enable then "/sys/class/backlight/backlight" else null;
      defaultText = lib.literalExpression ''if config.hardware.sg2k.dsiPanel.enable then "/sys/class/backlight/backlight" else null'';
      description = "Backlight that Display's Brightness buttons step, or null for none.";
    };
    apps = lib.mkOption {
      type = lib.types.attrsOf appType;
      default = { };
      description = "Managed applications indexed by launcher identifier.";
    };
  };
  config = lib.mkIf enabled (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = lib.all (
              a: if a.system then a.command == null && !a.hideBar && !a.keyboard else a.command != null
            ) (builtins.attrValues cfg.apps);
            message = "badge.graphics.touchBar.apps: an app has a command or is a system unit, which cannot use user keyboard or bar hooks";
          }
          {
            assertion = builtins.length (builtins.attrNames cfg.apps) <= 16;
            message = "badge.graphics.touchBar.apps: the touch bar supports at most 16 apps";
          }
          {
            assertion =
              builtins.length groups
              + builtins.length (lib.filter (a: a.group == null) (builtins.attrValues visibleApps)) <= 3;
            message = "badge.graphics.touchBar.apps: Home supports three entries plus Settings";
          }
          {
            assertion = lib.all (
              g: builtins.length (lib.filter (a: a.group == g) (builtins.attrValues visibleApps)) <= 3
            ) groups;
            message = "badge.graphics.touchBar.apps: groups support three apps plus Back";
          }
          {
            assertion = lib.all (a: !a.hidden || a.group == null) (builtins.attrValues cfg.apps);
            message = "badge.graphics.touchBar.apps: hidden apps cannot belong to a launcher group";
          }
        ];
        badge.graphics.backgroundImage = lib.mkDefault "${pkgs.nixos-icons}/share/icons/hicolor/128x128/apps/nix-snowflake.png";
        hardware.sg2k.wifi.onDemand = lib.mkDefault true;
        hardware.sg2k.wifi.bluetooth = lib.mkIf sg2k.wifi.enable (lib.mkOverride 900 "sdio");
        # The radios take the bar's limits.
        systemd.services = {
          badge-panel-radio-stack = lib.mkIf wifi { serviceConfig.TimeoutStartSec = cfg.limits.start; };
          nix-badge-wifi = lib.mkIf wifi {
            serviceConfig = {
              TimeoutStartSec = cfg.limits.start;
              TimeoutStopSec = cfg.limits.stop;
            };
          };
          badge-panel-bluetooth = lib.mkIf bluetooth {
            serviceConfig = {
              ExecStartPost = lib.mkIf managedAudio "-${config.systemd.package}/bin/systemctl --user --machine=badge@.host --no-block start badge-panel-bluetooth-audio-watch.service";
              TimeoutStartSec = cfg.limits.start;
              TimeoutStopSec = cfg.limits.stop;
            };
          };
          bluetooth = lib.mkIf bluetooth {
            serviceConfig.TimeoutStartSec = cfg.limits.start;
          };
        };
        badge.graphics.extraConfig = ''
          bar {
            id touch
            output ${graphics.outputName}
            position bottom
            height ${toString barHeight}
            font pango:${font} ${toString fontSize}
            workspace_buttons no
            binding_mode_indicator no
            status_padding 0
            status_edge_padding 0
            status_command ${
              lib.getExe (
                pkgs.badge-touch-bar.override {
                  inherit (pkgs.pkgsStatic) stdenv json_c;
                  sway = config.programs.sway.package;
                }
              )
            } ${configFile}
          }
        '';
        services.udev.extraRules = lib.mkIf (cfg.backlight != null) ''
          ACTION=="add", SUBSYSTEM=="backlight", KERNEL=="${baseNameOf cfg.backlight}", RUN+="${pkgs.coreutils}/bin/chgrp video /sys%p/brightness", RUN+="${pkgs.coreutils}/bin/chmod g+w /sys%p/brightness"
        '';
        security.polkit.extraConfig = ''
          polkit.addRule(function(action, subject) {
            if (subject.user != "badge" || action.id != "org.freedesktop.systemd1.manage-units") return;
            var unit = action.lookup("unit"), verb = action.lookup("verb");
            if (${builtins.toJSON settingUnits}.indexOf(unit) >= 0 &&
                (verb == "start" || verb == "stop" || verb == "restart"))
              return polkit.Result.YES;
            if (${builtins.toJSON systemApps}.indexOf(unit) >= 0 &&
                (verb == "start" || verb == "stop") && subject.local && subject.active)
              return polkit.Result.YES;
          });
        '';
        badge.graphics.touchBar.apps = {
          terminal = {
            label = "Terminal";
            group = lib.mkDefault "Tools";
            keyboard = true;
            command = footApp "--login-shell --app-id=badge-terminal";
          };
          info = {
            label = "Info";
            group = lib.mkDefault "Tools";
            command = "${footApp "--app-id=badge-info"} ${lib.getExe' tools "badge-panel-info"}";
          };
          wifi-join = lib.mkIf wifi {
            label = "Join WiFi";
            hidden = true;
            keyboard = true;
            command = "${footApp "--app-id=badge-wifi-join"} ${lib.getExe' tools "badge-panel-wifi-join"}";
          };
          bluetooth-devices = lib.mkIf bluetooth {
            label = "Bluetooth devices";
            hidden = true;
            keyboard = true;
            command = "${footApp "--app-id=badge-bluetooth-devices"} ${lib.getExe' tools "badge-panel-bluetooth-devices"}";
          };
        };
        # Session sound starts with a connected Bluetooth audio device, not at login.
        services.pipewire.socketActivation = lib.mkIf bluetooth (lib.mkDefault false);
        systemd.user.services = {
          "badge-panel-keyboard@" = lib.mkIf (lib.any (a: a.keyboard) (builtins.attrValues cfg.apps)) {
            description = "Panel app keyboard";
            bindsTo = [ "%i.service" ];
            partOf = [ "%i.service" ];
            after = [ "%i.service" ];
            unitConfig.ConditionUser = "badge";
            serviceConfig = {
              Type = "exec";
              ExecStart = lib.getExe keyboard;
              ExecStartPost = lib.getExe keyboardReady;
              TimeoutStartSec = cfg.limits.start;
            };
          };
          badge-panel-bluetooth-audio-watch = lib.mkIf (managedAudio && bluetooth) {
            description = "Audio for connected Bluetooth audio devices";
            unitConfig.ConditionUser = "badge";
            serviceConfig = {
              ExecStart = lib.getExe' tools "badge-panel-bluetooth-audio-watch";
              Restart = "on-failure";
              RestartSec = 5;
              TimeoutStopSec = cfg.limits.stop;
            };
          };
        };
      }
      { systemd.user.services = appUnits; }
    ]
  );
}
