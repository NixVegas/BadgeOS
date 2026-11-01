# The badge's binary cache (badge.cache): Harmonia on localhost behind the badge vhost. What
# it doesn't have it pulls from the upstreams in order, streaming to the client while the
# nix-daemon imports it. It runs only with a data card in use or on an SD boot: the eMMC's
# USERDATA is too small to cache into.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.badge.cache;
  address = config.badge.lan.address;
  listen = "127.0.0.1:5000";

  conditions = {
    ConditionPathIsMountPoint = "|/.lower-userdata";
    ConditionKernelCommandLine = "|nixbadge.bootmedium=1";
  };

  # With Harmonia down, stalled or failing, a client sees a miss and moves on to its next
  # substituter.
  harmonia = {
    proxyPass = "http://${listen}";
    extraConfig = ''
      proxy_buffering off;
      proxy_intercept_errors on;
      error_page 500 502 503 504 =404 @nocache;
    '';
  };
in
{
  options.badge.cache = {
    enable = lib.mkEnableOption "the badge's pull-through binary cache" // {
      default = config.badge.ipxe.enable;
      defaultText = lib.literalExpression "config.badge.ipxe.enable";
    };

    upstreams = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "https://cache.nixos.lv"
        "https://cache.nixos.org"
      ];
      description = "The binary caches a miss is pulled from, tried in order.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.badge.ipxe.enable;
        message = "badge.cache needs badge.ipxe: it is served on the vhost badge.ipxe sets up.";
      }
      {
        assertion = address == "10.55.0.1";
        message = "badge.cache needs the badge at 10.55.0.1 (badge.lan.address): the installer substitutes from http://10.55.0.1.";
      }
    ];

    services.harmonia = {
      package = pkgs.nix-badge-harmonia;
      cache = {
        enable = true;
        settings = {
          bind = listen;
          workers = 1;
          # Under cache.nixos.org's 40, so clients ask the badge first.
          priority = 30;
          enable_compression = false;
          virtual_nix_store = "/nix/store";
          real_nix_store = "/nix/store";
          nix_db_path = "/nix/var/nix/db/db.sqlite";
          substitute_on_miss = true;
          miss_upstream_urls = cfg.upstreams;
          miss_daemon_socket = "/nix/var/nix/daemon-socket/socket";
          # The spool shares the card with the store; nothing is spooled below the GC's floor.
          miss_spool_dir = "/var/cache/harmonia";
          miss_min_free_bytes = 4 * 1024 * 1024 * 1024;
          miss_max_jobs = 4;
          miss_connect_timeout_secs = 10;
          miss_read_timeout_secs = 30;
        };
      };
    };

    # The daemon fetches the references of what Harmonia imports. On event WiFi each fetch
    # takes uplink from the clients, so two at a time.
    nix.settings.max-substitution-jobs = 2;

    systemd.sockets.harmonia.unitConfig = conditions;

    systemd.services.harmonia = {
      unitConfig = conditions;
      after = [ "nix-daemon.socket" ];
      serviceConfig = {
        CacheDirectory = "harmonia";
        MemoryHigh = "128M";
        MemoryMax = "192M";
        # The upstreams are on the network.
        PrivateNetwork = lib.mkForce false;
        RestrictAddressFamilies = lib.mkForce [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        IPAddressDeny = lib.mkForce "";
      };
    };

    # What clients pulled stays until the card runs low.
    systemd.services.nix-badge-cache-gc = {
      description = "Collect garbage when the store runs low on space";
      unitConfig = conditions;
      after = [ "nix-daemon.socket" ];
      path = [ config.nix.package ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe pkgs.nix-badge-cache-gc;
      };
    };

    systemd.timers.nix-badge-cache-gc = {
      wantedBy = [ "timers.target" ];
      unitConfig = conditions;
      timerConfig = {
        OnCalendar = "*:0/5";
        Persistent = true;
      };
    };

    services.nginx.virtualHosts.badge.locations = {
      "= /nix-cache-info" = harmonia;
      # Quoted: nginx reads an unquoted { in a location as the start of its block.
      "~ \"^/[0-9a-z]{32}\\.(narinfo|ls)$\"" = harmonia;
      "/nar/" = harmonia;
      "/log/" = harmonia;
      "@nocache".return = "404";
    };
  };
}
