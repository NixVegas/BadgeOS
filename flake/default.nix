# One flake-parts module per badge, and what they share.
{
  lib,
  flake-parts-lib,
  inputs,
  ...
}:
{
  imports = [
    ./version.nix
    ./v1.nix
    ./v2
  ];

  options.flake = flake-parts-lib.mkSubmoduleOptions {
    hydraJobs = lib.mkOption {
      type = lib.types.lazyAttrsOf lib.types.raw;
      default = { };
      description = "Hydra jobs, one attribute set per badge.";
    };
  };

  config = {
    systems = [
      "x86_64-linux"
      "aarch64-linux"
    ];

    perSystem =
      { pkgs, system, ... }:
      {
        # `nix fmt` formats the tree with nixfmt, except the generated font data.
        formatter = pkgs.nixfmt-tree.override {
          settings.global.excludes = [
            "pkgs/v2/by-name/nix-badge-bling-content/screens/*-font-data.nix"
            # Copied from NixVegas/systems as they are.
            "modules/installer/flake.nix"
            "modules/installer/nix-vegas-defaults.nix"
          ];
        };

        devShells.default = pkgs.mkShellNoCC {
          packages = [
            inputs.deploy-rs.packages.${system}.default
            pkgs.openssh
            inputs.zippy.packages.${system}.default
          ];
        };
      };
  };
}
