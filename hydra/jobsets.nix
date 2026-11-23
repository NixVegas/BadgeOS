# Declarative jobset generator for Hydra. hydra/spec.json is the project-level spec: Hydra
# evaluates this file from the `src` input (master), and the `jobsets` job's output,
# jobsets.json, becomes the project's jobsets.
#
# Each entry is a flake jobset (type 1) that builds a branch's `hydraJobs` from the public
# upstream: master, and the release branch v<major>.<minor> of the flake's version template
# (hydra/release.nix). Each branch also has a jobset of the eval manifests cache.nixos.lv
# keeps builds by: `nidhogg` for master (hydra/nidhogg, series `badgeos`), `nidhogg-<branch>`
# for the others (hydra/nidhogg/release, series `badgeos-<branch>`), so the main jobsets list
# only BadgeOS's jobs and the cache lists each branch's builds apart. The badge1 jobs need a builder with the
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

  release = import (src + "/hydra/release.nix");

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

  # Master's manifests go to the series `badgeos`, a release branch's to its own.
  manifestDir = branch: if branch == "master" then "hydra/nidhogg" else "hydra/nidhogg/release";

  mkManifestJobset =
    branch:
    mkJobset branch
    // {
      description = "BadgeOS ${branch}: eval manifests for cache.nixos.lv";
      flake = "${upstream}?ref=${branch}&dir=${manifestDir branch}";
    };

  jobsetsJson = builtins.toJSON (
    builtins.listToAttrs (
      map (branch: {
        name = branch;
        value = mkJobset branch;
      }) branches
      ++ map (branch: {
        name = if branch == "master" then "nidhogg" else "nidhogg-${branch}";
        value = mkManifestJobset branch;
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
