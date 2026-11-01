# Per-board facts the flake needs before any evaluation. A system without a
# nixpkgs.hostPlatform runs on the first core.
{
  nix-badge = {
    cores = [
      "arm"
      "riscv"
    ];
  };
  # Strapped to riscv as it ships.
  licheerv-nano = {
    cores = [
      "riscv"
      "arm"
    ];
  };
}
