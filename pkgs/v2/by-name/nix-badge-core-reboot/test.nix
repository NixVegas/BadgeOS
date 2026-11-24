# core-reboot.sh against a fake card: requests, refusals and the markers each one leaves.
{
  runCommand,
  python3,
  util-linux,
}:
runCommand "nix-badge-core-reboot-test"
  {
    nativeBuildInputs = [
      python3
      util-linux
    ];
  }
  ''
    python3 ${./.}/tests/check.py
    touch $out
  ''
