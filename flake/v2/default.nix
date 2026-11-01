# This year's badge (SG2000): the v2 overlay and BSP module and the configurations built
# from them; the packages, Hydra jobs and deploy nodes read from those.
{
  self,
  inputs,
  flakever,
  ...
}:
let
  v2 = import ./lib.nix { inherit self inputs flakever; };
in
{
  imports = [
    ./packages.nix
    ./hydra.nix
    ./deploy.nix
  ];

  _module.args.v2 = v2;

  flake = {
    overlays.v2 = import ../../pkgs/v2 {
      inherit (inputs) sophgone;
      autopenOverlay = inputs.autopen.overlays.default;
      nixpkcsOverlay = inputs.nixpkcs.overlays.default;
    };
    overlays.default = self.overlays.v2;

    # The BSP for another flake: import it and set hardware.sg2k.enable.
    nixosModules.v2 =
      { config, lib, ... }:
      {
        imports = [ ../../modules/sg2k ];
        config = lib.mkMerge [
          {
            # Module arguments, so unconditional: a module takes them in its header.
            _module.args = {
              sophgone = inputs.sophgone;
              makeBootImage = v2.makeBootImageFor config.nixpkgs.buildPlatform.system;
              badgeNetboot = v2.netboot;
              badgeManual = v2.badgeManual;
              badgeVersion = v2.badgeVersion;
            };
          }
          (lib.mkIf config.hardware.sg2k.enable {
            nixpkgs.overlays = [ self.overlays.v2 ];
            nixpkgs.hostPlatform = lib.mkDefault (v2.hostPlatformCfgOf (lib.head config.hardware.sg2k.cores));
          })
        ];
      };

    nixosModules.default = self.nixosModules.v2;

    nixosConfigurations = v2.sg2kNixosConfigurations;
  };
}
