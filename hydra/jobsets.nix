# Declarative jobset generator for Hydra. hydra/spec.json is the project-level spec: Hydra
# evaluates this file from the `src` input (master), and the `jobsets` job's output,
# jobsets.json, becomes the project's jobsets.
#
# Each entry is a flake jobset (type 1) that builds a branch's `hydraJobs` from the public
# upstream: master, and the release branch v<major>.<minor> of the flake's version template
# (flake/version.nix, which flakever reads). The badge1 jobs need a builder with the
# `autopen` system feature (see flake/v2/hydra.nix). When master moves to the next release,
# add the old release branch to `branches` to keep its jobset.
#
# Hydra needs `jobsets` to be a derivation it can build. Rather than pull in all of nixpkgs
# for writeText, use Nix's builtin fetcher on the toFile'd JSON: a fixed-output derivation
# whose "fetch" is a file:// read of a file we already wrote, with the flat sha256 of the
# same string. The only input is `src`.
{ src, ... }:
let
  upstream = "git+https://git.nixos.lv/NixVegas/BadgeOS";

  inherit ((import (src + "/flake/version.nix") { inputs = { }; }).flake) versionTemplate;
  release = "v" + builtins.head (builtins.match "([0-9]+\\.[0-9]+).*" versionTemplate);

  branches = [
    "master"
    release
  ];

  mkJobset = branch: {
    enabled = 1;
    hidden = false;
    description = "BadgeOS ${branch}";
    type = 1; # flake jobset
    flake = "${upstream}?ref=${branch}";
    checkinterval = 300;
    schedulingshares = 100;
    enableemail = false;
    emailoverride = "";
    keepnr = 3;
  };

  jobsetsJson = builtins.toJSON (
    builtins.listToAttrs (
      map (branch: {
        name = branch;
        value = mkJobset branch;
      }) branches
    )
  );
  jsonFile = builtins.toFile "jobsets.json" jobsetsJson;
in
{
  jobsets = derivation {
    name = "jobsets.json";
    system = "builtin";
    builder = "builtin:fetchurl";
    url = "file://${jsonFile}";
    urls = [ "file://${jsonFile}" ];
    outputHashMode = "flat";
    outputHashAlgo = "sha256";
    outputHash = builtins.hashString "sha256" jobsetsJson;
    preferLocalBuild = true;
  };
}
