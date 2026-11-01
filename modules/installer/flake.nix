{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    dcwifi = {
      url = "github:NixVegas/dcwifi";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, dcwifi, ... }@inputs:
    let
      # NixOS prebuilds angle bracket paths into the release images still
      # but they start with <nixpkgs/...> so we can fix that issue right here:
      flakify =
        path:
        if builtins.typeOf path == "path" then
          builtins.scopedImport {
            __findFile =
              _: name:
              let
                split = nixpkgs.lib.splitString "/" name;
              in
              "${inputs.${builtins.head split}}/${builtins.concatStringsSep "/" (builtins.tail split)}";
          } path
        else
          path;
    in
    {
      nixosConfigurations = rec {
        default = nixpkgs.lib.nixosSystem {
          modules = map flakify [
            ./configuration.nix
            ./nix-vegas-defaults.nix
            dcwifi.nixosModules.default
          ];
          specialArgs = inputs;
        };
        nixvegas = default;
      };
    };
}
