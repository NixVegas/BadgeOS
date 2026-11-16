# The eval manifest for cache.nixos.lv: a Hydra job that lists the out paths of every other
# job, with the rev they were evaluated at. The cache keeps what the manifests of recent
# evals list, and deletes what no manifest lists once nobody has fetched it for a month.
{
  self,
  inputs,
  lib,
  ...
}:
let
  inherit (inputs.nidhogg-manifest.lib) manifestJobs;
  jobs = removeAttrs self.hydraJobs [ "nidhogg-manifest" ];
in
{
  # A dirty tree has no rev for a manifest to name, so it has no manifest job. Hydra
  # evaluates a commit.
  flake.hydraJobs = lib.optionalAttrs (self ? rev) {
    nidhogg-manifest = manifestJobs {
      # Only builds the manifest: bash and coreutils.
      pkgs = inputs.nixpkgs-2605.legacyPackages.x86_64-linux;
      # The cache's `[[series]]` of this name takes these manifests.
      series = "badgeos";
      source = self;
      inherit jobs;
      # A manifest for each job. A manifest evaluates the out paths it lists, and one that
      # listed every job would evaluate them all in one of Hydra's workers.
      shards = lib.length (lib.collect lib.isDerivation jobs);
    };
  };
}
