# deploy-rs nodes, one per board host and core, read from the configurations.
{
  self,
  inputs,
  v2,
  ...
}:
let
  inherit (inputs) nixpkgs-2605 deploy-rs;
  inherit (v2)
    sg2kLib
    sg2kBoards
    sg2kBoardTable
    hostPlatformOf
    ;
in
{
  flake.deploy.nodes =
    let
      # deploy-rs ships no riscv64 lib, so cross-build its overlay for each target.
      crossName = {
        "aarch64-linux" = "aarch64-multiplatform";
        "riscv64-linux" = "riscv64";
      };
      deployLibFor =
        system:
        (import nixpkgs-2605 {
          system = "x86_64-linux";
          overlays = [ deploy-rs.overlays.default ];
        }).pkgsCross.${crossName.${system}}.deploy-rs.lib;

      # A profile per core, so garbage collection never takes the idle core's system.
      coreOf = s: if s == "aarch64-linux" then "arm" else "riscv";
      mkNodeAt = hostname: system: nixosCfg: {
        inherit hostname;
        sshUser = "badge";
        user = "root";
        profiles.system = {
          path = (deployLibFor system).activate.nixos nixosCfg;
          profilePath = "/nix/var/nix/profiles/system-${coreOf system}";
        };
      };
    in
    sg2kLib.concatMapAttrs (
      board: b:
      sg2kLib.concatMapAttrs (
        name: hostname:
        sg2kLib.listToAttrs (
          map (
            core:
            sg2kLib.nameValuePair "${name}-${core}" (
              mkNodeAt hostname (hostPlatformOf core) self.nixosConfigurations."${name}-${core}-x86_64"
            )
          ) sg2kBoardTable.${board}.cores
        )
      ) b.deployHosts
    ) sg2kBoards;
}
