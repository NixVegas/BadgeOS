# What the v2 flake files share: the platforms, the nixpkgs with the v2 overlay, the
# board table, and the configurations and SD cards built from them.
{
  self,
  inputs,
  flakever,
}:
let
  inherit (inputs) nixpkgs-2605;
  sg2kLib = nixpkgs-2605.lib;

  hostPlatformOf = core: if core == "arm" then "aarch64-linux" else "riscv64-linux";

  # Codegen flags for the C/C++ closure. The A53 has CRC32 but no crypto extensions;
  # nixpkgs drops tune/abi on riscv, so only `arch` takes effect there.
  gccFlagsOf =
    core:
    if core == "arm" then
      {
        arch = "armv8-a+crc";
        tune = "cortex-a53";
      }
    else
      {
        arch = "rv64gc";
        abi = "lp64d";
        tune = "thead-c906";
      };
  hostPlatformCfgOf = core: {
    system = hostPlatformOf core;
    gcc = gccFlagsOf core;
  };

  buildHosts = [
    "x86_64-linux"
    "aarch64-linux"
    "riscv64-linux"
  ];

  # nixpkgs 26.05 with the badge's packages, per build system.
  pkgsBySystem = sg2kLib.genAttrs buildHosts (
    system: nixpkgs-2605.legacyPackages.${system}.extend self.overlays.v2
  );
  pkgsFor = system: pkgsBySystem.${system};

  # The generation image is assembled (and signed) on the build host.
  makeBootImageFor = buildSystem: (pkgsFor buildSystem).nix-badge-boot-image;

  # The Nix Vegas installer the badge netboots, and the directory the badge serves of it.
  netbootSystem = nixpkgs-2605.lib.nixosSystem { modules = [ ../../modules/installer ]; };
  netboot = netbootSystem.config.system.build.badgeNetboot;

  # This manual, built to be served at / by a badge. Its NixOS is every badge's
  # system.nixos.label: no badge sets system.nixos.tags.
  badgeManual = import ../../site {
    pkgs = pkgsFor "x86_64-linux";
    modules = [ self.nixosModules.v2 ];
    specialArgs = { inherit inputs; };
    baseHref = "/";
    version = badgeVersion;
    nixosLabel = sg2kLib.version;
  };

  # Boards, by hardware.sg2k.board: the prefix of the generic configurations, the
  # per-device host modules, the address deploy-rs uses for each, and the fips a
  # two-core card carries, from the card's build host.
  sg2kBoards = {
    nix-badge = {
      prefix = "sg2k";
      # Taking the chain's U-Boot (secureUboot) and its key (fitKeyCert).
      fips = pkgs: pkgs.nix-badge-fips;
      hosts = {
        # Badge #1: the signed fip with the plain FIT U-Boot.
        badge1 = [ ../../modules/hosts/badge1.nix ];

        # badge1 with the verified-boot chain on: the secure U-Boot inside the signed
        # fip, and signed generation and slot vbmeta images.
        badge1-secure = [
          ../../modules/hosts/badge1.nix
          { hardware.sg2k.secureBoot = true; }
        ];
      };

      # The installer refuses a node whose secure mode differs from the card's /secure,
      # so deploy the one matching the booted card. Override with --hostname.
      deployHosts = {
        sg2k = "nix-badge-01.arena.dc.nixos.lv";
        badge1 = "nix-badge-01.arena.dc.nixos.lv";
        badge1-secure = "nix-badge-01.arena.dc.nixos.lv";
      };
    };
    licheerv-nano = {
      prefix = "licheerv-nano";
      fips = pkgs: _: pkgs.sg2k-fips-licheerv-nano;
      hosts = { };

      # Over the USB gadget link.
      deployHosts.licheerv-nano = "10.55.0.1";
    };
  };
  sg2kBoardTable = import ../../modules/sg2k/boards/table.nix;

  # The BadgeOS release every badge carries, on top of its NixOS release: the flake's
  # version without its date and rev.
  badgeVersion = flakever.cleanVersion;

  mkSg2k =
    {
      board,
      core,
      buildPlatform,
      # modules/hosts/<badge>.nix and the like
      extraModules ? [ ],
    }:
    nixpkgs-2605.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        self.nixosModules.v2
        {
          hardware.sg2k = {
            enable = true;
            inherit board;
          };
          nixpkgs.hostPlatform = hostPlatformCfgOf core;
          nixpkgs.buildPlatform = buildPlatform;
        }
      ]
      ++ extraModules;
    };

  # <prefix>-<core> natively, and <prefix>-<core>-<buildArch> cross (never from riscv64).
  configsFor =
    {
      board,
      core,
      prefix,
      extraModules ? [ ],
    }:
    let
      hostPlatform = hostPlatformOf core;
      valid = sg2kLib.filter (b: b == hostPlatform || b != "riscv64-linux") buildHosts;
    in
    sg2kLib.mapAttrs'
      (
        buildPlatform: cfg:
        sg2kLib.nameValuePair (
          "${prefix}-${core}"
          + sg2kLib.optionalString (
            buildPlatform != hostPlatform
          ) "-${sg2kLib.head (sg2kLib.splitString "-" buildPlatform)}"
        ) cfg
      )
      (
        sg2kLib.genAttrs valid (
          buildPlatform:
          mkSg2k {
            inherit
              board
              core
              buildPlatform
              extraModules
              ;
          }
        )
      );

  shortArch = p: sg2kLib.head (sg2kLib.splitString "-" p);
  sg2kBuildSystems = [
    "x86_64-linux"
    "aarch64-linux"
  ];

  # An SD image from the `<prefix>-<core>` configs (the board's generic `sg2k-<core>` by
  # default), for each of `cores` (the board's by default). Two cores boot the polyglot
  # fip, with plaintext recovery fips beside it; one core boots its own fip, so a
  # two-core board can make a card for each core as well. `secure`: the part is
  # fused, so fip.bin is the TPM-signed + encrypted polyglot and the recovery fips are
  # dropped; it signs through autopen, so it cannot build with --max-jobs 0.
  sdcardFor =
    {
      buildSystem,
      board ? "nix-badge",
      prefix ? sg2kBoards.${board}.prefix,
      cores ? sg2kBoardTable.${board}.cores,
      secure ? false,
    }:
    let
      pkgs = pkgsFor buildSystem;
      dualCore = sg2kLib.length cores > 1;
      systems = sg2kLib.genAttrs cores (
        core:
        self.nixosConfigurations."${prefix}-${core}${
          sg2kLib.optionalString (hostPlatformOf core != buildSystem) "-${shortArch buildSystem}"
        }"
      );
      first = systems.${sg2kLib.head cores};

      # The verified-boot chain (hardware.sg2k.secureBoot) is separate from `secure`, the
      # fused part: badge1 is fused with the chain off.
      chainSecure = first.config.hardware.sg2k.secureBoot;
      fitKeyCert = first.config.hardware.sg2k.fitKeyCert;
      fips = sg2kBoards.${board}.fips pkgs {
        inherit fitKeyCert;
        secureUboot = chainSecure;
      };
      coreFip =
        first.config.hardware.sg2k.firmware.fips.${
          if sg2kLib.head cores == "arm" then "fipArm" else "fipRiscv"
        };
      fip =
        if !dualCore then
          coreFip
        else if secure then
          fips.signedEncFipPolyglot
        else
          fips.fipPolyglot;

      # The rooted store for every core, with each core's stage-0 at /init-<core>.
      storeImage = pkgs.nix-badge-store-squashfs {
        secure = chainSecure;
        inherit fitKeyCert;
        systems = map (core: systems.${core}) cores;
        stage0s = sg2kLib.mapAttrs (_: sys: sys.pkgs.nix-badge-stage0) systems;
      };
      bootImages = sg2kLib.mapAttrs (_: sys: sys.config.system.build.bootImage) systems;
      bootDir = pkgs.nix-badge-boot-dir (
        {
          inherit bootImages;
          inherit (storeImage) vbmeta;
        }
        // (
          if secure && dualCore then
            { fip = "${fip}/fip.bin"; }
          else
            {
              inherit fip;
              recoveryFips = sg2kLib.optionalAttrs dualCore {
                arm = fips.fipArm;
                riscv = fips.fipRiscv;
              };
            }
        )
      );
      image = pkgs.nix-badge-sd-image-gpt {
        inherit bootDir storeImage cores;
        envText = "env_loaded=1\nBOOT_ORDER=A B\nBOOT_A_LEFT=3\nBOOT_B_LEFT=3\n";
      };
    in
    assert sg2kLib.assertMsg (sg2kLib.all (
      core: sg2kLib.elem core sg2kBoardTable.${board}.cores
    ) cores) "sdcardFor: ${toString cores} is not a subset of ${board}'s cores";
    assert sg2kLib.assertMsg (
      secure -> dualCore
    ) "sdcardFor: a fused card boots the signed polyglot, which needs two cores";
    image.overrideAttrs (_: {
      passthru = {
        inherit
          storeImage
          bootDir
          bootImages
          fip
          ;
      };
    });

  # Each board's generic configurations and its hosts', for every core it has.
  sg2kNixosConfigurations = sg2kLib.mergeAttrsList (
    sg2kLib.concatLists (
      sg2kLib.mapAttrsToList (
        board: b:
        sg2kLib.concatLists (
          sg2kLib.mapAttrsToList (
            prefix: extraModules:
            map (
              core:
              configsFor {
                inherit
                  board
                  core
                  prefix
                  extraModules
                  ;
              }
            ) sg2kBoardTable.${board}.cores
          ) ({ ${b.prefix} = [ ]; } // b.hosts)
        )
      ) sg2kBoards
    )
  );
in
{
  inherit
    sg2kLib
    hostPlatformOf
    hostPlatformCfgOf
    pkgsFor
    makeBootImageFor
    sg2kBoards
    sg2kBoardTable
    badgeVersion
    mkSg2k
    shortArch
    sg2kBuildSystems
    sdcardFor
    sg2kNixosConfigurations
    netbootSystem
    netboot
    badgeManual
    ;
}
