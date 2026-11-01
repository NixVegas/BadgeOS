# Board variations, as evaluation checks: each scenario evaluates a nix-badge riscv
# system with its modules on top and fails naming every expectation it breaks.
{
  pkgs,
  mkSystem,
}:
let
  inherit (pkgs) lib;

  # failuresOf takes the evaluated system; scenario's takes its config.
  scenarioOf =
    name: modules: failuresOf:
    let
      failures = failuresOf (mkSystem modules);
    in
    if failures == [ ] then
      pkgs.runCommand name { } "touch $out"
    else
      throw ("${name}:\n  " + lib.concatStringsSep "\n  " failures);
  scenario =
    name: modules: failuresOf:
    scenarioOf name modules (sys: failuresOf sys.config);

  has = needle: haystack: lib.hasInfix needle haystack;
  nameOf = p: p.pname or (lib.getName p);
  citadelKey = "citadel.build.dc.nixos.lv-1:UZbkvFcWZr/VP7cvNPLRpcMTCvaYw7X5XQDzA+nPVxY=";
in
{
  sg2k-no-emmc = scenario "sg2k-no-emmc" [ { hardware.sg2k.emmc.enable = false; } ] (
    config:
    let
      rauc = config.services.rauc;
      etc = config.environment.etc;
      rules = config.services.udev.extraRules;
      packages = map nameOf config.environment.systemPackages;
      services = config.systemd.services;
    in
    lib.optional (rauc.slots ? fip) "RAUC has a fip slot"
    ++ lib.optional (
      map (s: s.device) rauc.slots.boot != [ "/dev/boot1" ]
    ) "the RAUC boot slot is not /dev/boot1"
    ++ lib.optional (
      map (s: s.device) rauc.slots.nix != [
        "/dev/nixA1"
        "/dev/nixB1"
      ]
    ) "the RAUC nix slots are not /dev/nixA1 and /dev/nixB1"
    ++ lib.optional (rauc.settings.handlers or { } ? post-install) "RAUC has a post-install handler"
    ++ lib.optional (
      etc."fw_env.config".text != "/dev/uboot1 0x0 0x20000 0x20000\n/dev/uboot1 0x20000 0x20000 0x20000\n"
    ) "fw_env.config does not name /dev/uboot1"
    ++ lib.optional (etc ? "fw_env-sd.config") "fw_env-sd.config exists"
    ++ lib.optional (has ''ATTRS{type}=="MMC"'' rules) "a udev rule matches the eMMC"
    ++ lib.optional (has "mmcblk[0-9]boot" rules) "a udev rule matches an eMMC boot area"
    ++ map (n: "package ${n} is installed") (
      lib.filter (
        n:
        lib.any (p: lib.hasPrefix p n) [
          "nix-badge-install"
          "nix-badge-emmc-init"
          "nix-badge-env-mirror"
        ]
      ) packages
    )
    ++ map (n: "service ${n} is defined") (
      lib.filter (n: services ? ${n}) [
        "nix-badge-env-mirror"
        "nix-badge-mark-good-sd"
        "nix-badge-board-id"
      ]
    )
    ++ lib.optional (has "nix-badge-install" config.environment.interactiveShellInit) "the login hint names nix-badge-install"
    ++ lib.optional config.hardware.sg2k.externalStorage.enable "hardware.sg2k.externalStorage is on"
    ++ lib.optional (services ? nix-badge-storage-mode) "the storage-mode service is defined"
    ++ lib.optional (has "cardboot" rules) "a udev rule names the data card"
    ++ lib.optional (has "/dev/fip" config.system.build.installBootLoader.text) "the bootloader installer writes /dev/fip"
    ++ lib.optional (has "rauc_ext" config.system.build.bootImage.scripts.script_default) "the boot script carries rauc_ext"
  );

  # Data cards are on for a board with an eMMC: the kernel parameter stage 0 waits for,
  # the daemon's store from the storage-mode service, the card's udev links and BOOT
  # mount, the RAUC refusal, and the eMMC USERDATA writers held off in case 3.
  sg2k-external-storage-default = scenario "sg2k-external-storage-default" [ ] (
    config:
    let
      services = config.systemd.services;
      rules = config.services.udev.extraRules;
      held = n: (services.${n}.unitConfig.ConditionPathIsMountPoint or null) == "!/.lower-userdata";
    in
    lib.optional (!config.hardware.sg2k.externalStorage.enable) "hardware.sg2k.externalStorage is off"
    ++ lib.optional (
      !lib.elem "nixbadge.datacard=1" config.boot.kernelParams
    ) "no nixbadge.datacard=1 kernel parameter"
    ++ lib.optional (!(services ? nix-badge-storage-mode)) "no storage-mode service"
    ++ lib.optional (
      !lib.elem "nix-daemon.service" (services.nix-badge-storage-mode.before or [ ])
    ) "the storage-mode service does not run before nix-daemon"
    ++ lib.optional (
      !has "\n!include /run/nix-badge/store.conf" services.nix-daemon.environment.NIX_CONFIG
    ) "the daemon's NIX_CONFIG does not include /run/nix-badge/store.conf"
    ++ lib.optional (!has ''SYMLINK+="cardboot"'' rules) "no /dev/cardboot udev link"
    ++ lib.optional (!has ''SYMLINK+="carduserdata"'' rules) "no /dev/carduserdata udev link"
    ++ lib.optional (
      !has ''ENV{PARTNAME}=="EXT_USERDATA", ATTRS{type}=="SD", SYMLINK+="carduserdata"'' rules
    ) "/dev/carduserdata is not the SD's EXT_USERDATA"
    ++ lib.optional (
      !lib.any (
        m: m.where == "/boot-card" && (m.unitConfig.ConditionPathIsMountPoint or null) == "/.lower-userdata"
      ) config.systemd.mounts
    ) "no /boot-card mount for case 3"
    ++ lib.optional (
      !(config.services.rauc.settings.handlers or { } ? pre-install)
    ) "RAUC has no pre-install handler"
    ++ map (n: "${n} is not held off with a data card in") (
      lib.filter (n: !held n) [
        "growpart"
        "systemd-growfs@\\x2euserdata"
      ]
    )
    ++ lib.optional (
      (services."mkswap-x2euserdata-swap".unitConfig.ConditionPathIsMountPoint or null) != null
    ) "the swap file is held off, but it belongs on the card in case 3"
    ++ lib.optional (!(services ? nix-badge-card-boot-reset)) "no card-boot-reset service"
    ++ lib.optional (
      !lib.elem "nix-badge-card-boot-reset.service" (
        config.systemd.units."boot\\x2dcard.mount".wants or [ ]
      )
      && !lib.elem "boot\\x2dcard.mount" (services.nix-badge-card-boot-reset.wantedBy or [ ])
    ) "mounting the card's BOOT does not start card-boot-reset"
    ++ lib.optional (
      !has "Data card in use: writes go to" config.environment.interactiveShellInit
    ) "the login message does not mention a data card"
    ++ lib.optional (
      !has "/boot-card" config.system.build.installBootLoader.text
    ) "the bootloader installer never writes /boot-card"
  );

  # Off, nothing of it is there and the daemon's store is case 1's, exactly as before.
  sg2k-external-storage-off =
    scenario "sg2k-external-storage-off" [ { hardware.sg2k.externalStorage.enable = false; } ]
      (
        config:
        let
          services = config.systemd.services;
        in
        lib.optional (lib.elem "nixbadge.datacard=1" config.boot.kernelParams) "the nixbadge.datacard=1 kernel parameter is set"
        ++ lib.optional (services ? nix-badge-storage-mode) "the storage-mode service is defined"
        ++ lib.optional (
          services.nix-daemon.environment.NIX_CONFIG
          != "store = local-overlay://?lower-store=local%%3Froot%%3D%%2Fnix%%2F.ro-store%%26read-only%%3Dtrue&upper-layer=/.userdata/nix/upper"
        ) "the daemon's NIX_CONFIG is not case 1's: ${services.nix-daemon.environment.NIX_CONFIG}"
        ++ lib.optional (has "cardboot" config.services.udev.extraRules) "a udev rule names the data card"
        ++ lib.optional (lib.any (m: m.where == "/boot-card") config.systemd.mounts) "/boot-card is mounted"
        ++ lib.optional (
          config.services.rauc.settings.handlers or { } ? pre-install
        ) "RAUC has a pre-install handler"
        ++ lib.optional (
          services.growpart.unitConfig ? ConditionPathIsMountPoint
        ) "growpart has a mount condition"
        ++ lib.optional (services ? nix-badge-card-boot-reset) "the card-boot-reset service is defined"
        ++ lib.optional (has "Data card" config.environment.interactiveShellInit) "the login message mentions a data card"
        ++ lib.optional (has "/boot-card" config.system.build.installBootLoader.text) "the bootloader installer names /boot-card"
      );

  sg2k-no-wifi =
    scenario "sg2k-no-wifi"
      [
        {
          hardware.sg2k.wifi = {
            enable = false;
            bluetooth = "none";
          };
        }
      ]
      (
        config:
        let
          modulePackages = map nameOf config.boot.extraModulePackages;
        in
        map (n: "kernel module package ${n}") (
          lib.filter (n: has "aic8800" n || has "sdhci-cv181x" n) modulePackages
        )
        ++ map (m: "kernel module ${m} loads at boot") (
          lib.intersectLists [ "aic8800_bsp" "sdhci-cv181x" ] config.boot.kernelModules
        )
        ++ lib.optional config.hardware.bluetooth.enable "Bluetooth is enabled"
        # hardware.firmware applies to one buildEnv over its (compressed) list.
        ++ map (n: "firmware ${n}") (lib.filter (has "aic8800") (map nameOf config.hardware.firmware.paths))
        ++ lib.optional (config.systemd.services ? nix-badge-net-scan) "the net-scan service is defined"
        ++ lib.optional (config.systemd.paths ? nix-badge-net-scan) "the net-scan path unit is defined"
        ++ lib.optional (has "aicwf_sdio" config.services.udev.extraRules) "the aic8800 MAC udev rule exists"
        ++ lib.optional config.badge.router.enable "the router is on"
      );

  sg2k-wifi-no-bluetooth =
    scenario "sg2k-wifi-no-bluetooth" [ { hardware.sg2k.wifi.bluetooth = "none"; } ]
      (
        config:
        let
          scan = config.systemd.services.nix-badge-net-scan;
        in
        lib.optional config.hardware.bluetooth.enable "Bluetooth is enabled"
        ++ lib.optional (has "-bluez-" config.system.build.netScanScript.text) "the scan feed scans for Bluetooth"
        ++ lib.optional (lib.elem "bluetooth.target" scan.after) "the net-scan service is ordered after bluetooth.target"
        ++ lib.optional (lib.elem "bluetooth.target" scan.wants) "the net-scan service wants bluetooth.target"
      );

  sg2k-no-leds-oled =
    scenario "sg2k-no-leds-oled"
      [
        {
          hardware.sg2k = {
            ledRing.enable = false;
            oled.enable = false;
            sharpPanel.enable = false;
          };
        }
      ]
      (
        config:
        map (n: "service ${n} is defined") (
          lib.filter (n: config.systemd.services ? ${n}) [
            "nix-badge-bling"
            "nix-badge-spidev-announce"
            "nix-badge-oled"
            "nix-badge-content"
          ]
        )
        ++ lib.optional (lib.any (has "/etc/nix-badge") config.systemd.tmpfiles.rules) "a tmpfiles rule creates /etc/nix-badge"
        ++ lib.optional (has "spidev" config.services.udev.extraRules) "a udev rule matches spidev"
        ++ map (p: "kernel parameter ${p}") (
          lib.intersectLists [ "console=tty1" "fbcon=rotate:2" ] config.boot.kernelParams
        )
        ++ lib.optional (has "spleen" (toString config.console.font)) "the console font is Spleen"
        ++ lib.optional (config.systemd.services."getty@tty1".enable or false) "getty@tty1 is enabled"
      );

  sg2k-no-hdmi =
    scenario "sg2k-no-hdmi"
      [
        {
          hardware.sg2k = {
            hdmi.enable = false;
            hdmi.audio = false;
            display.drmDevice = "";
          };
        }
      ]
      (
        config:
        map (p: "specialisation ${p} exists") (
          lib.filter (p: config.specialisation ? ${p}) [
            "desktop"
            "video"
            "usb-host"
            "usb-device"
          ]
        )
        ++ lib.optional (
          config.system.build.bootImage.profiles != [ "default" ]
        ) "the boot image has profiles ${toString config.system.build.bootImage.profiles}"
        ++ map (n: "kernel module package ${n}") (
          lib.filter (has "soph-display") (map nameOf config.boot.extraModulePackages)
        )
        ++ lib.optional (config.systemd.services ? soph-display-load) "the VIP stack loads at boot"
        ++ lib.optional config.services.pipewire.enable "PipeWire is enabled"
        ++ lib.optional config.services.mpd.enable "mpd is enabled"
        ++ lib.optional (has "soph-drm" config.services.udev.extraRules) "a udev rule names soph-drm"
      );

  # The USB role is an option: a device by default, a host in the desktop profile, and
  # neither role a specialisation of its own.
  sg2k-usb-role = scenario "sg2k-usb-role" [ ] (
    config:
    let
      desktop = config.specialisation.desktop.configuration;
      role = c: toString (c.hardware.sg2k.usb.role or null);
      hostDtb = c: lib.hasSuffix "-usb-host" (nameOf c.hardware.deviceTree.package);
    in
    lib.optional (role config != "device") "the default boot's role is ${role config}"
    ++ lib.optional (!config.hardware.sg2k.usb.gadget.enable) "the default boot has no gadget"
    ++ lib.optional (hostDtb config) "the default boot has the host DTB"
    ++ lib.optional (role desktop != "host") "the desktop profile's role is ${role desktop}"
    ++ lib.optional desktop.hardware.sg2k.usb.gadget.enable "the desktop profile runs the gadget"
    ++ lib.optional (!hostDtb desktop) "the desktop profile has the device DTB"
    ++ map (p: "specialisation ${p} exists") (
      lib.filter (p: config.specialisation ? ${p}) [
        "usb-host"
        "usb-device"
      ]
    )
    ++ lib.optional (config.environment.etc ? badge-usb-role) "/etc/badge-usb-role exists"
  );

  # A configuration that pins the device role still gets a host in the desktop profile.
  sg2k-usb-role-pinned = scenario "sg2k-usb-role-pinned" [ { hardware.sg2k.usb.role = "device"; } ] (
    config:
    let
      role = c: toString (c.hardware.sg2k.usb.role or null);
    in
    lib.optional (role config != "device") "the default boot's role is ${role config}"
    ++ lib.optional (
      role config.specialisation.desktop.configuration != "host"
    ) "the desktop profile's role is ${role config.specialisation.desktop.configuration}"
  );

  # Sway starts what badge.graphics.autostart lists, and the games add theirs to it.
  sg2k-graphics-autostart =
    scenario "sg2k-graphics-autostart"
      [
        {
          badge.graphics = {
            enable = true;
            autostart = [ "/run/current-system/sw/bin/foot" ];
            autostartQuake = true;
          };
        }
      ]
      (
        config:
        let
          sway = config.environment.etc."sway/config".source.text;
        in
        lib.optional (!has "\nexec /run/current-system/sw/bin/foot\n" sway) "sway does not start foot"
        ++ lib.optional (
          builtins.match ".*\nexec [^\n]*/bin/badge-quake3\n.*" sway == null
        ) "sway does not start Quake"
        ++ lib.optional (
          !lib.any (lib.hasSuffix "/bin/badge-quake3") (config.badge.graphics.autostart or [ ])
        ) "Quake is not in badge.graphics.autostart"
      );

  # The LT8912B's module options and the DRM card rules are display.nix's. The bridge's
  # options are for sway's HDMI only: its node is in the desktop profile's DTB alone.
  sg2k-display-settings = scenarioOf "sg2k-display-settings" [ { badge.graphics.enable = true; } ] (
    sys:
    let
      fromElsewhere =
        what: needle: option:
        map (d: "${what} is defined in ${d.file}") (
          lib.filter (
            d: has needle (toString d.value) && !lib.hasSuffix "/modules/sg2k/display.nix" d.file
          ) option.definitionsWithLocations
        );
      modprobe = sys.config.boot.extraModprobeConfig;
      plain = (mkSystem [ ]).config.boot.extraModprobeConfig;
      inherit (sys.config.hardware.sg2k) hdmi;
    in
    fromElsewhere "an LT8912B option" "lontium_lt8912b" sys.options.boot.extraModprobeConfig
    ++ fromElsewhere "a DRM card rule" ''SUBSYSTEM=="drm"'' sys.options.services.udev.extraRules
    ++ map (o: "the LT8912B lacks ${o}") (
      lib.filter (o: !has o modprobe) [
        "hactive_offset=${toString hdmi.hactiveOffset}"
        "hdmi_audio=${if hdmi.audio then "1" else "0"}"
        "force_720p=1"
      ]
    )
    ++ lib.optional (has "lontium_lt8912b" plain) "the LT8912B has options without sway"
  );

  # The desktop profile's 128 MiB CMA pool does not fit a quarter of 256 MiB.
  sg2k-cma-too-big =
    scenario "sg2k-cma-too-big" [ { hardware.sg2k.memory.sizeMiB = lib.mkForce 256; } ]
      (
        config:
        lib.optional (
          !lib.any (
            a: !a.assertion && has "memory.cmaMiB" a.message
          ) config.specialisation.desktop.configuration.assertions
        ) "no failed assertion names hardware.sg2k.memory.cmaMiB in the desktop profile"
      );

  sg2k-single-core =
    scenario "sg2k-single-core"
      [
        {
          hardware.sg2k = {
            cores = lib.mkForce [ "riscv" ];
            coreSelect.enable = false;
          };
        }
      ]
      (
        config:
        lib.optional (
          config.boot.binfmt.emulatedSystems != [ ]
        ) "binfmt emulates ${toString config.boot.binfmt.emulatedSystems}"
        ++ lib.optional (config.boot.binfmt.registrations != { }) "binfmt has registrations"
        ++ lib.optional (config.systemd.services ? nix-badge-bootswap) "the bootswap service is defined"
        ++ lib.optional (has "recovery" config.system.build.installBootLoader.text) "the bootloader installer writes a recovery fip"
        ++ lib.optional (
          config.system.build.activeFip.drvPath != config.hardware.sg2k.firmware.fips.fipRiscv.drvPath
        ) "the active fip is not the riscv fip"
      );

  # Board facts are defaults: a plain definition replaces them instead of conflicting or
  # (for lists) concatenating.
  sg2k-board-overrides =
    scenario "sg2k-board-overrides"
      [
        {
          hardware.sg2k = {
            cores = [ "riscv" ];
            memory.sizeMiB = 1024;
            dtb.name = "sophgo/my-board.dtb";
          };
        }
      ]
      (
        config:
        let
          cfg = config.hardware.sg2k;
        in
        lib.optional (cfg.cores != [ "riscv" ]) "cores is ${toString cfg.cores}"
        ++ lib.optional (cfg.memory.sizeMiB != 1024) "memory.sizeMiB is ${toString cfg.memory.sizeMiB}"
        ++ lib.optional (cfg.dtb.name != "sophgo/my-board.dtb") "dtb.name is ${cfg.dtb.name}"
      );

  # Your own update key replaces the sg1-image certificate as the RAUC keyring.
  sg2k-own-keyring =
    let
      cert = "${pkgs.nix-badge-rauc-dev-keyring}/cert.pem";
    in
    scenario "sg2k-own-keyring" [ { hardware.sg2k.fitKeyCert = cert; } ] (
      config:
      lib.optional (
        config.services.rauc.settings.keyring.path != cert
      ) "the RAUC keyring is ${config.services.rauc.settings.keyring.path}"
    );

  # No update key at all is refused, rather than trusting the committed development key.
  sg2k-no-keyring = scenario "sg2k-no-keyring" [ { hardware.sg2k.fitKeyCert = null; } ] (
    config:
    lib.optional (
      !lib.any (a: !a.assertion && has "fitKeyCert" a.message) config.assertions
    ) "no failed assertion names hardware.sg2k.fitKeyCert"
  );

  # The development key is trusted only on request.
  sg2k-dev-keyring =
    scenario "sg2k-dev-keyring"
      [
        {
          hardware.sg2k.fitKeyCert = null;
          hardware.sg2k.rauc.trustDevKeyring = true;
        }
      ]
      (
        config:
        lib.optional (lib.any (
          a: !a.assertion && has "fitKeyCert" a.message
        ) config.assertions) "a failed assertion names hardware.sg2k.fitKeyCert"
        ++ lib.optional (
          !lib.hasSuffix "-nix-badge-rauc-dev-keyring/cert.pem" config.services.rauc.settings.keyring.path
        ) "the RAUC keyring is ${config.services.rauc.settings.keyring.path}"
      );

  # BadgeOS 2.1.0 on an unchanged NixOS: its own name, image and links, while VERSION,
  # VERSION_ID and BUILD_ID still carry the NixOS release and the nixpkgs revision.
  sg2k-os-release = scenario "sg2k-os-release" [ ] (
    config:
    let
      nixos = config.system.nixos;
      inherit (lib.trivial) release codeName;
      fields = lib.listToAttrs (
        map (
          line:
          let
            m = builtins.match "([A-Z_]+)=\"?([^\"]*)\"?" line;
          in
          lib.nameValuePair (lib.elemAt m 0) (lib.elemAt m 1)
        ) (lib.filter (l: l != "") (lib.splitString "\n" config.environment.etc."os-release".text))
      );
      expect =
        n: v:
        lib.optional ((fields.${n} or null) != v) "${n} is ${toString (fields.${n} or null)}, not ${v}";
      shortRev = lib.substring 0 7 (toString nixos.revision);
      variant = s: config.specialisation.${s}.configuration.system.nixos.variant_id;
      manual = config.badge.ipxe.manual;
    in
    expect "NAME" "BadgeOS"
    ++ expect "ID" "badgeos"
    ++ expect "ID_LIKE" "nixos"
    ++ expect "PRETTY_NAME" "BadgeOS 2.1.0 (NixOS ${release})"
    ++ expect "IMAGE_ID" "badgeos"
    ++ expect "IMAGE_VERSION" "2.1.0"
    ++ expect "VENDOR_NAME" "Nix Vegas"
    ++ expect "HOME_URL" "https://nix.vegas/"
    ++ expect "DOCUMENTATION_URL" "https://badge.nix.vegas/"
    ++ expect "BUG_REPORT_URL" "https://github.com/NixVegas/BadgeOS/issues"
    ++ expect "VERSION" "${release} (${codeName})"
    ++ expect "VERSION_ID" release
    ++ expect "BUILD_ID" nixos.version
    ++ lib.optional (nixos.revision == null) "system.nixos.revision is unset"
    ++ lib.optional (
      !lib.hasPrefix "${release}." nixos.version || !lib.hasSuffix ".${shortRev}" nixos.version
    ) "system.nixos.version ${nixos.version} is not the NixOS release with the nixpkgs revision"
    ++ lib.optional (config.system.configurationRevision != null) "system.configurationRevision is set"
    ++ lib.optional (
      config.services.getty.greetingLine != "<<< BadgeOS 2.1.0 on NixOS ${nixos.label} (\\m) - \\l >>>"
    ) "the greeting is ${config.services.getty.greetingLine}"
    ++ lib.optional (nixos.variant_id != null) "the default profile is variant ${nixos.variant_id}"
    ++ map (s: "the ${s} profile is variant ${toString (variant s)}") (
      lib.filter (s: variant s != s) [
        "desktop"
        "video"
      ]
    )
    ++ lib.optional ((manual.badgeVersion or null) != "2.1.0") "the manual is not for BadgeOS 2.1.0"
    ++ lib.optional (
      (manual.nixosLabel or null) != nixos.label
    ) "the manual is not for NixOS ${nixos.label}"
  );

  # The router, on by default: eth0 and usb0 bridged as lan0, NATed out over WiFi.
  sg2k-router-default = scenario "sg2k-router-default" [ ] (
    config:
    let
      ds = config.services.dnsmasq.settings;
      fw = config.networking.firewall;
      nat = config.networking.nat;
      net = config.systemd.network;
      lanUdp = fw.interfaces.lan0.allowedUDPPorts or [ ];
      bridge = net.netdevs."40-lan0" or { };
      lan = net.networks."40-lan0" or { };
      lanPorts = net.networks."41-lan0-ports" or { };
      unmanaged = config.networking.networkmanager.unmanaged;
      dispatchers = lib.filter (e: e.enable && lib.hasPrefix "NetworkManager/dispatcher.d/" e.target) (
        lib.attrValues config.environment.etc
      );
    in
    lib.optional (!config.badge.router.enable) "the router is off"
    ++
      lib.optional ((config.badge.lan.interface or null) != "lan0")
        "the badge's network is on ${toString (config.badge.lan.interface or null)}, not lan0"
    ++ lib.optional (
      config.badge.router.upstream != "wifi"
    ) "the upstream is ${config.badge.router.upstream}"
    ++ lib.optional (!net.enable) "systemd-networkd is off"
    ++ lib.optional net.wait-online.enable "networkd waits for online"
    ++ lib.optional config.services.resolved.enable "networkd brought systemd-resolved with it"
    ++ lib.optional (
      (bridge.netdevConfig.Name or null) != "lan0" || (bridge.netdevConfig.Kind or null) != "bridge"
    ) "no lan0 bridge netdev"
    ++ lib.optional ((bridge.bridgeConfig.STP or null) != false) "lan0 runs STP"
    ++ lib.optional ((lan.address or [ ]) != [ "10.55.0.1/24" ]) "lan0 is not 10.55.0.1/24"
    ++ lib.optional (
      (lan.networkConfig.ConfigureWithoutCarrier or null) != true
    ) "lan0 waits for a carrier"
    ++
      lib.optional ((lanPorts.matchConfig.Name or null) != "eth0 usb0")
        "the lan0 ports are ${toString (lanPorts.matchConfig.Name or "none")}"
    ++ lib.optional (
      (lanPorts.networkConfig.Bridge or null) != "lan0"
    ) "the ports are not bridged into lan0"
    ++ map (i: "NetworkManager manages ${i}") (
      lib.filter (i: !lib.elem "interface-name:${i}" unmanaged) [
        "lan0"
        "eth0"
        "usb0"
      ]
    )
    ++ lib.optional (
      config.networking.networkmanager.ensureProfiles.profiles ? badge-lan
    ) "NetworkManager has a lan0 profile"
    ++ lib.optional (
      nat.externalInterface != "wlan0"
    ) "NAT goes out of ${toString nat.externalInterface}"
    ++ lib.optional (nat.internalInterfaces != [ "lan0" ]) "NAT is not from lan0"
    ++ lib.optional (!config.networking.nftables.enable) "nftables is off"
    ++ lib.optional (!fw.filterForward) "forwarding is not filtered"
    ++ lib.optional (lib.toList (ds.interface or [ ]) != [ "lan0" ]) "dnsmasq is not on lan0"
    ++ lib.optional (lib.toList (ds.bind-dynamic or [ ]) != [ true ]) "dnsmasq does not bind-dynamic"
    ++
      lib.optional ((ds.dhcp-range or null) != [ "10.55.0.100,10.55.0.200,2m" ])
        "the DHCP range is ${toString (ds.dhcp-range or [ ])}"
    ++ lib.optional (
      lib.toList (ds.dhcp-optsfile or [ ]) != [ "/run/nix-badge/router/dhcp-opts" ]
    ) "dnsmasq has no gateway options file"
    ++ lib.optional (!(lib.elem 67 lanUdp && lib.elem 53 lanUdp)) "lan0 does not open DHCP and DNS"
    ++ lib.optional (
      !lib.any (e: has "nix-badge-router-dispatch" (toString e.source)) dispatchers
    ) "no dispatcher script runs nix-badge-router-gateway"
    # /etc is noexec on the badge, so a script copied there never runs.
    ++ map (e: "${e.target} is a copy in /etc, not a link into the store") (
      lib.filter (e: e.mode != "symlink") dispatchers
    )
    ++ lib.optional (fw.interfaces ? usb0) "the firewall opens usb0"
    ++ lib.optional (fw.interfaces ? wlan0) "the firewall opens wlan0"
    ++ lib.optional (has "ip addr replace" config.system.build.usbGadgetUp.text) "the gadget addresses usb0"
    ++ lib.optional config.specialisation.desktop.configuration.badge.router.enable "the desktop profile routes"
    ++ lib.optional (
      !config.specialisation.video.configuration.badge.router.enable
    ) "the video profile does not route"
  );

  sg2k-router-upstream-ethernet =
    scenario "sg2k-router-upstream-ethernet" [ { badge.router.upstream = "ethernet"; } ]
      (
        config:
        let
          lanPorts = config.systemd.network.networks."41-lan0-ports" or { };
          unmanaged = config.networking.networkmanager.unmanaged;
        in
        lib.optional ((lanPorts.matchConfig.Name or null) != "usb0")
          "the lan0 ports are ${toString (lanPorts.matchConfig.Name or "none")}"
        ++ lib.optional (lib.elem "interface-name:eth0" unmanaged) "NetworkManager leaves the eth0 uplink alone"
        ++ lib.optional (
          config.networking.nat.externalInterface != "eth0"
        ) "NAT goes out of ${toString config.networking.nat.externalInterface}"
      );

  sg2k-router-upstream-usb =
    scenario "sg2k-router-upstream-usb" [ { badge.router.upstream = "usb"; } ]
      (
        config:
        let
          lanPorts = config.systemd.network.networks."41-lan0-ports" or { };
          nm = config.networking.networkmanager;
          usbDevice = nm.settings."device-badge-usb" or { };
        in
        lib.optional ((lanPorts.matchConfig.Name or null) != "eth0")
          "the lan0 ports are ${toString (lanPorts.matchConfig.Name or "none")}"
        ++ lib.optional (lib.elem "interface-name:usb0" nm.unmanaged) "NetworkManager leaves the usb0 uplink alone"
        # NetworkManager's own udev rule leaves gadget devices unmanaged.
        ++ lib.optional (
          (usbDevice.match-device or null) != "interface-name:usb0" || (usbDevice.managed or null) != 1
        ) "NetworkManager is not told to manage the usb0 gadget"
        ++ lib.optional (
          config.networking.nat.externalInterface != "usb0"
        ) "NAT goes out of ${toString config.networking.nat.externalInterface}"
      );

  # Router off: the USB link as before the router.
  sg2k-router-off = scenario "sg2k-router-off" [ { badge.router.enable = false; } ] (
    config:
    let
      ds = config.services.dnsmasq.settings;
      usb0 = config.networking.firewall.interfaces.usb0 or { };
    in
    lib.optional ((config.badge.lan.interface or null) != "usb0")
      "the badge's network is on ${toString (config.badge.lan.interface or null)}, not usb0"
    ++ lib.optional (lib.toList (ds.interface or [ ]) != [ "usb0" ]) "dnsmasq is not on usb0"
    ++
      lib.optional ((ds.dhcp-range or null) != [ "10.55.0.100,10.55.0.200,24h" ])
        "the DHCP range is ${toString (ds.dhcp-range or [ ])}"
    ++ lib.optional (lib.toList (ds.dhcp-option or [ ]) != [ "option:router" ]) "the gateway is offered"
    ++ lib.optional (
      !has "ip addr replace 10.55.0.1/24 dev usb0" config.system.build.usbGadgetUp.text
    ) "the gadget does not address usb0"
    ++ lib.optional (config.systemd.network.netdevs ? "40-lan0") "there is a lan0 bridge"
    ++ lib.optional config.networking.nat.enable "NAT is on"
    ++ lib.optional config.badge.ipxe.enable "netboot is on"
    ++ lib.optional (
      !(lib.elem 67 (usb0.allowedUDPPorts or [ ]) && lib.elem 53 (usb0.allowedUDPPorts or [ ]))
    ) "usb0 does not open DHCP and DNS"
    ++ lib.optional config.services.nginx.enable "nginx is on"
  );

  # The hardware.sg2k.usb.gadget.hostNetwork names still set badge.lan.
  sg2k-lan-renamed =
    scenario "sg2k-lan-renamed"
      [
        {
          badge.router.enable = false;
          hardware.sg2k.usb.gadget.hostNetwork = {
            address = "10.66.0.1";
            poolStart = "10.66.0.10";
            poolEnd = "10.66.0.20";
            offerGateway = true;
          };
        }
      ]
      (
        config:
        let
          ds = config.services.dnsmasq.settings;
        in
        lib.optional ((config.badge.lan.address or null) != "10.66.0.1")
          "badge.lan.address is ${toString (config.badge.lan.address or null)}"
        ++
          lib.optional ((ds.dhcp-range or null) != [ "10.66.0.10,10.66.0.20,24h" ])
            "the DHCP range is ${toString (ds.dhcp-range or [ ])}"
        ++ lib.optional (
          lib.toList (ds.dhcp-option or [ ]) != [ "option:router,10.66.0.1" ]
        ) "the gateway offered is ${toString (ds.dhcp-option or [ ])}"
        ++ lib.optional (
          !has "ip addr replace 10.66.0.1/24 dev usb0" config.system.build.usbGadgetUp.text
        ) "the gadget does not address usb0 as 10.66.0.1"
      );

  # USB as the uplink in USB host mode: there is no usb0.
  sg2k-router-usb-without-gadget =
    scenario "sg2k-router-usb-without-gadget"
      [
        {
          hardware.sg2k.usb.role = "host";
          badge.router.upstream = "usb";
        }
      ]
      (
        config:
        lib.optional (
          !lib.any (a: !a.assertion && has "usb" a.message) config.assertions
        ) "no failed assertion names usb"
      );

  # The router serves its LAN through badge.lan, so it can't be turned off under it.
  sg2k-lan-off-with-router = scenario "sg2k-lan-off-with-router" [ { badge.lan.enable = false; } ] (
    config:
    lib.optional (
      !lib.any (
        a: !a.assertion && has "badge.lan" a.message && has "badge.router" a.message
      ) config.assertions
    ) "no failed assertion names badge.lan and badge.router"
  );

  # Netboot, on with the router: dnsmasq's PXE classes and TFTP root on lan0, and nginx
  # with the manual and the netboot tree.
  sg2k-ipxe-default = scenario "sg2k-ipxe-default" [ ] (
    config:
    let
      ds = config.services.dnsmasq.settings;
      fw = config.networking.firewall;
      tftpRoot = toString (lib.head (lib.toList (ds.tftp-root or [ "" ])));
      root = lib.removeSuffix "/tftp,lan0" tftpRoot;
      vhost = config.services.nginx.virtualHosts.badge or { };
      setting =
        name: want:
        lib.optional (lib.toList (ds.${name} or [ ]) != want)
          "${name} is ${toString (lib.toList (ds.${name} or [ ]))}";
    in
    lib.optional (!config.badge.ipxe.enable) "netboot is off"
    ++ setting "enable-tftp" [ true ]
    ++ lib.optional (
      !lib.hasSuffix "-nix-badge-netboot-root/tftp,lan0" tftpRoot
    ) "the TFTP root is ${tftpRoot}"
    ++ setting "dhcp-match" [
      "set:ipxe,175"
      "set:efi64,option:client-arch,7"
      "set:efi64,option:client-arch,8"
      "set:efi64,option:client-arch,9"
      "set:bios,option:client-arch,0"
    ]
    ++ setting "dhcp-userclass" [ "set:ipxe,iPXE" ]
    ++ setting "dhcp-vendorclass" [ "set:httpclient,HTTPClient" ]
    ++ setting "dhcp-boot" [
      "tag:bios,tag:!ipxe,undionly.kpxe"
      "tag:efi64,tag:!ipxe,ipxe.efi"
      "tag:httpclient,tag:!ipxe,http://10.55.0.1/boot/ipxe.efi"
      "tag:ipxe,http://10.55.0.1/boot/menu.ipxe"
    ]
    ++ setting "dhcp-option-force" [ "tag:httpclient,60,HTTPClient" ]
    ++ lib.optional (!(vhost.default or false)) "nginx has no default badge host"
    ++ lib.optional (
      toString (vhost.root or "") != toString config.badge.ipxe.manual
    ) "nginx's root is not the manual"
    ++ lib.optional (
      (vhost.locations."/boot/".alias or null) != "${root}/boot/"
    ) "/boot/ is not the netboot tree"
    ++ lib.optional (!lib.elem 69 (fw.interfaces.lan0.allowedUDPPorts or [ ])) "lan0 does not open TFTP"
    ++ lib.optional (!lib.elem 80 (fw.interfaces.lan0.allowedTCPPorts or [ ])) "lan0 does not open HTTP"
    ++ lib.optional config.specialisation.desktop.configuration.services.nginx.enable "the desktop profile serves HTTP"
  );

  # /dev/mem reaches neither RAM nor a register a driver claimed: media buffers go
  # through /dev/soph-ion, and iomem=relaxed typed at boot is the way to peek and poke.
  sg2k-strict-devmem = scenario "sg2k-strict-devmem" [ ] (
    config:
    let
      settings = config.boot.kernelPackages.kernel.configfile.structuredConfig;
      value = n: settings.${n}.tristate or "unset";
    in
    map (n: "${n} is ${value n}, not y") (
      lib.filter (n: value n != "y") [
        "STRICT_DEVMEM"
        "IO_STRICT_DEVMEM"
      ]
    )
  );

  sg2k-ipxe-without-router =
    scenario "sg2k-ipxe-without-router"
      [
        {
          badge.router.enable = false;
          badge.ipxe.enable = true;
        }
      ]
      (
        config:
        lib.optional (
          !lib.any (a: !a.assertion && has "badge.router" a.message) config.assertions
        ) "no failed assertion names badge.router"
      );

  # The badge's cache, on with iPXE: Harmonia on localhost behind the badge vhost, only
  # with a data card in use or on an SD boot, pulling through from cache.nixos.lv and
  # then cache.nixos.org.
  sg2k-cache-default = scenario "sg2k-cache-default" [ ] (
    config:
    let
      h = config.services.harmonia;
      s = h.cache.settings;
      service = config.systemd.services.harmonia or { };
      socket = config.systemd.sockets.harmonia or { };
      conditions = u: [
        (u.unitConfig.ConditionPathIsMountPoint or null)
        (u.unitConfig.ConditionKernelCommandLine or null)
      ];
      wanted = [
        "|/.lower-userdata"
        "|nixbadge.bootmedium=1"
      ];
      locations = config.services.nginx.virtualHosts.badge.locations;
      cacheLocations = lib.filter (l: locations ? ${l}) [
        "= /nix-cache-info"
        # Quoted: nginx reads an unquoted { in a location as the start of its block.
        "~ \"^/[0-9a-z]{32}\\.(narinfo|ls)$\""
        "/nar/"
        "/log/"
      ];
      lan0 = config.networking.firewall.interfaces.lan0;
      gcService = config.systemd.services.nix-badge-cache-gc or { };
      gcTimer = config.systemd.timers.nix-badge-cache-gc or { };
    in
    lib.optional (!h.cache.enable) "Harmonia is off"
    ++ lib.optional (nameOf h.package != "nix-badge-harmonia") "Harmonia is ${nameOf h.package}"
    ++ lib.optional h.daemon.enable "Harmonia's own daemon is on"
    ++ lib.optional ((s.bind or null) != "127.0.0.1:5000") "Harmonia binds ${toString (s.bind or null)}"
    ++ lib.optional ((s.workers or null) != 1) "Harmonia runs ${toString (s.workers or null)} workers"
    ++ lib.optional (s.enable_compression or true) "Harmonia compresses on the fly"
    ++ lib.optional (
      (s.priority or 50) >= 40
    ) "clients try cache.nixos.org (priority 40) before the badge"
    ++ lib.optional (!(s.substitute_on_miss or false)) "Harmonia doesn't pull through"
    ++ lib.optional (
      (s.miss_upstream_urls or [ ]) != [
        "https://cache.nixos.lv"
        "https://cache.nixos.org"
      ]
    ) "the upstreams are ${toString (s.miss_upstream_urls or [ ])}"
    ++ lib.optional (
      (s.miss_daemon_socket or null) != "/nix/var/nix/daemon-socket/socket"
    ) "imports don't go through the nix-daemon socket"
    ++ lib.optional (
      (s.virtual_nix_store or null) != "/nix/store" || (s.real_nix_store or null) != "/nix/store"
    ) "Harmonia's store isn't /nix/store"
    ++ lib.optional (
      (s.nix_db_path or null) != "/nix/var/nix/db/db.sqlite"
    ) "Harmonia's database isn't the booted slot's"
    ++ lib.optional (
      s ? miss_import_buffer_bytes
    ) "Harmonia is given the old import buffer, which it refuses"
    ++ lib.optional (
      (s.miss_spool_dir or null) != "/var/cache/harmonia"
    ) "Harmonia doesn't spool to the card"
    ++ lib.optional (
      (s.miss_min_free_bytes or null) != 4 * 1024 * 1024 * 1024
    ) "Harmonia's free-space floor isn't the GC's 4 GiB"
    ++ lib.optional ((s.miss_max_jobs or null) != 4) "Harmonia streams other than 4 NARs at once"
    ++ lib.optional (
      (service.serviceConfig.CacheDirectory or null) != "harmonia"
    ) "Harmonia has no spool directory"
    ++ lib.optional (
      (service.serviceConfig.MemoryHigh or null) != "128M"
      || (service.serviceConfig.MemoryMax or null) != "192M"
    ) "Harmonia's memory isn't limited"
    ++ lib.optional (
      (s.miss_connect_timeout_secs or null) != 10 || (s.miss_read_timeout_secs or null) != 30
    ) "the upstream timeouts aren't 10 s and 30 s"
    ++ lib.optional (
      conditions service != wanted
    ) "the Harmonia service runs without a data card or an SD boot"
    ++ lib.optional (
      conditions socket != wanted
    ) "the Harmonia socket listens without a data card or an SD boot"
    ++ lib.optional (service.serviceConfig.PrivateNetwork or true) "Harmonia can't reach the upstreams"
    ++ lib.optional (
      !lib.elem "AF_INET" (lib.toList (service.serviceConfig.RestrictAddressFamilies or [ ]))
    ) "Harmonia can't open IPv4 sockets"
    ++ lib.optional (lib.length cacheLocations != 4) "the badge vhost lacks Harmonia's locations"
    ++ map (l: "${l} doesn't go to Harmonia") (
      lib.filter (l: (locations.${l}.proxyPass or null) != "http://127.0.0.1:5000") cacheLocations
    )
    ++ map (l: "${l} doesn't turn Harmonia being down or failing into a 404") (
      lib.filter (
        l:
        let
          c = locations.${l}.extraConfig or "";
        in
        !(has "error_page 500 502 503 504 =404" c && has "proxy_intercept_errors on" c)
      ) cacheLocations
    )
    ++ map (l: "${l} buffers what Harmonia streams") (
      lib.filter (l: !has "proxy_buffering off" (locations.${l}.extraConfig or "")) cacheLocations
    )
    ++ lib.optional (
      config.nix.settings.substituters != [
        "https://cache.nixos.lv?priority=30"
        "https://cache.nixos.org/"
      ]
    ) "the badge's substituters are ${toString config.nix.settings.substituters}"
    ++ lib.optional (
      (config.nix.settings.max-substitution-jobs or null) != 2
    ) "the badge's daemon fetches other than 2 references at once"
    ++ lib.optional (
      !lib.elem citadelKey (config.nix.settings.extra-trusted-public-keys or [ ])
    ) "the badge doesn't trust citadel's key"
    ++ lib.optional (lib.elem 5000 (
      lan0.allowedTCPPorts ++ config.networking.firewall.allowedTCPPorts
    )) "the firewall opens Harmonia's port"
    ++ lib.optional config.specialisation.desktop.configuration.services.harmonia.cache.enable "the desktop profile runs Harmonia"
    ++ lib.optional (
      conditions gcService != wanted
    ) "the cache GC runs without a data card or an SD boot"
    ++ lib.optional (
      conditions gcTimer != wanted
    ) "the cache GC timer runs without a data card or an SD boot"
    ++ lib.optional ((gcService.serviceConfig.Type or null) != "oneshot") "the cache GC isn't a oneshot"
    ++ lib.optional (
      (gcTimer.timerConfig.OnCalendar or null) != "*:0/5"
    ) "the cache GC timer doesn't check every five minutes"
    ++ lib.optional (!(gcTimer.timerConfig.Persistent or false)) "the cache GC timer isn't persistent"
    ++ lib.optional (
      !lib.elem "timers.target" (gcTimer.wantedBy or [ ])
    ) "nothing starts the cache GC timer"
  );

  # Router off, so iPXE and the cache are off; the key is trusted on every badge.
  sg2k-cache-off = scenario "sg2k-cache-off" [ { badge.router.enable = false; } ] (
    config:
    lib.optional config.services.harmonia.cache.enable "Harmonia is on"
    ++ lib.optional config.specialisation.desktop.configuration.services.harmonia.cache.enable "the desktop profile runs Harmonia"
    ++ lib.optional (
      !lib.elem citadelKey (config.nix.settings.extra-trusted-public-keys or [ ])
    ) "the badge doesn't trust citadel's key"
  );

  # The cache lives on the vhost iPXE serves, so it needs iPXE.
  sg2k-cache-without-ipxe =
    scenario "sg2k-cache-without-ipxe"
      [
        {
          badge.ipxe.enable = false;
          badge.cache.enable = true;
        }
      ]
      (
        config:
        lib.optional (
          !lib.any (
            a: !a.assertion && has "badge.cache" a.message && has "badge.ipxe" a.message
          ) config.assertions
        ) "no failed assertion names badge.cache and badge.ipxe"
      );

  # The installer substitutes from http://10.55.0.1, so the cache needs that address.
  sg2k-cache-other-address =
    scenario "sg2k-cache-other-address" [ { badge.lan.address = "10.66.0.1"; } ]
      (
        config:
        lib.optional (
          !lib.any (
            a: !a.assertion && has "badge.cache" a.message && has "10.55.0.1" a.message
          ) config.assertions
        ) "no failed assertion names badge.cache and 10.55.0.1"
      );
}
