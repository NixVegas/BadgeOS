# Last year's badge (ESP32-C6): the v1 overlay, the firmware and its dev shell, read from
# nixpkgs with the esp-dev and v1 overlays, and a Hydra job for the firmware.
{
  self,
  inputs,
  flakever,
  ...
}:
let
  # The nixpkgs nixpkgs-esp-dev pins: its overlay needs packages (python310) that
  # current unstable has dropped.
  pkgsFor =
    system:
    import inputs.nixpkgs-esp-dev.inputs.nixpkgs {
      inherit system;
      overlays = [
        inputs.nixpkgs-esp-dev.overlays.default
        self.overlays.v1
      ];
      config.permittedInsecurePackages = [ "python3.13-ecdsa-0.19.1" ];
    };
in
{
  flake = {
    overlays.v1 = import ../pkgs/v1 { inherit flakever; };
    hydraJobs.v1.firmware = (pkgsFor "x86_64-linux").nix-badge-v1;
  };

  perSystem =
    { system, ... }:
    let
      pkgs = pkgsFor system;
    in
    {
      packages.v1 = pkgs.nix-badge-v1;
      devShells.v1 = pkgs.nix-badge-v1.shell;
    };
}
