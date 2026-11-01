# PID 1 before NixOS stage 2: mounts USERDATA, the state binds and the store overlay on
# the read-only squashfs root, then execs the real init.
{
  writeShellApplication,
  callPackage,
  util-linux,
  coreutils,
  e2fsprogs,
  gnugrep,
  gawk,
  gnused,
}:
let
  tier2 = ./tier2.sh;
in
writeShellApplication {
  name = "nix-badge-stage0";
  runtimeInputs = [
    util-linux
    coreutils
    e2fsprogs
    gnugrep
    gawk
    gnused
  ];
  # errexit would turn a tolerable mount failure into a kernel panic.
  bashOptions = [
    "nounset"
    "pipefail"
  ];
  # tier2.sh: the data card's two-tier store, shared with the storage-mode service
  text = builtins.readFile tier2 + builtins.readFile ./stage0.sh;
  passthru = {
    tests.plan = callPackage ./test.nix { };
    inherit tier2;
  };
}
