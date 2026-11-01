# Populate a blank eMMC from a running SD boot: the SD's layout, fip, env, BOOT and NIX_A.
{
  writeShellApplication,
  callPackage,
  gptfdisk,
  dosfstools,
  e2fsprogs,
  util-linux,
  coreutils,
}:
writeShellApplication {
  name = "nix-badge-emmc-init";
  runtimeInputs = [
    gptfdisk
    dosfstools
    e2fsprogs
    util-linux
    coreutils
  ];
  text = builtins.readFile ./emmc-init.sh;
  passthru.tests.plan = callPackage ./test.nix { };
}
