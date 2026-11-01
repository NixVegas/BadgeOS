# Copy the eMMC's U-Boot env (boot area 2) into its UBOOT partition, U-Boot's fallback.
{
  writeShellApplication,
  coreutils,
  gnused,
  util-linux,
}:
writeShellApplication {
  name = "nix-badge-env-mirror";
  runtimeInputs = [
    coreutils
    gnused
    util-linux
  ];
  text = builtins.readFile ./env-mirror.sh;
}
