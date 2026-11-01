{
  description = "Board support packages for Nix Vegas badges";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # badgeOS builds on 26.05; the ESP32 badge on unstable.
    nixpkgs-2605.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-esp-dev.url = "github:mirrexagon/nixpkgs-esp-dev";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-compat.url = "https://flakehub.com/f/edolstra/flake-compat/1.tar.gz";
    flakever.url = "github:numinit/flakever";
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs-2605";
    };
    # The fix evaluator (no flake.nix; built from its default.nix overlay).
    fix = {
      url = "github:psyclyx/fix";
      flake = false;
    };
    zippy = {
      url = "git+https://git.lilithsemi.com/LilithSemi/zippy";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flakever.follows = "flakever";
      };
    };
    # The FIP builders (lib.*) and the mask-ROM exploit.
    sophgone = {
      url = "github:NixVegas/sophgone";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # The TPM signing stack for signed fips, FITs and bundles.
    nixpkcs = {
      url = "github:numinit/nixpkcs";
      inputs.nixpkgs.follows = "nixpkgs-2605";
    };
    autopen = {
      url = "github:NixVegas/autopen/hardware-signing-experiments";
      inputs.nixpkgs.follows = "nixpkgs-2605";
    };
  };

  outputs = inputs: inputs.flake-parts.lib.mkFlake { inherit inputs; } ./flake;
}
