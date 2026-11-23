# The release branch: v<major>.<minor> of the flake's version template (flake/version.nix,
# which flakever reads; read here without the inputs). hydra/jobsets.nix gives it jobsets,
# and hydra/nidhogg/release names its manifests' series after it.
let
  inherit ((import ../flake/version.nix { inputs = { }; }).flake) versionTemplate;
in
"v" + builtins.head (builtins.match "([0-9]+\\.[0-9]+).*" versionTemplate)
