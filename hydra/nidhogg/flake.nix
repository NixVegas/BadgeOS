# The eval manifests of BadgeOS's Hydra jobs, evaluated by Hydra jobsets of their own (see
# ../jobsets.nix), so that the main jobsets list only BadgeOS's jobs. A manifest lists the
# out paths of the main flake's jobs with the rev they were evaluated at; cache.nixos.lv
# keeps what the manifests of recent evals list.
#
# The main flake is loaded from this flake's own source tree, at the same rev and date, so
# it evaluates with its own flake.lock and names the same out paths as its jobset does. A
# flake input would copy the main lock into a lock of this flake's own, which would go stale
# whenever the main lock is updated.
{
  description = "Eval manifests of BadgeOS's Hydra jobs, for cache.nixos.lv";

  outputs =
    { self }:
    let
      src = self.sourceInfo;
      badgeos = builtins.getFlake (
        "path:${builtins.unsafeDiscardStringContext src.outPath}"
        + "?narHash=${src.narHash}&rev=${src.rev}&lastModified=${toString src.lastModified}"
      );
      inherit (badgeos.inputs) nixpkgs-2605 nidhogg-manifest;
      inherit (nixpkgs-2605) lib;
      jobs = badgeos.hydraJobs;
    in
    {
      # A dirty tree has no rev for a manifest to name. Hydra evaluates a commit.
      hydraJobs =
        if self ? rev then
          nidhogg-manifest.lib.manifestJobs {
            # Only builds the manifest: bash and coreutils.
            pkgs = nixpkgs-2605.legacyPackages.x86_64-linux;
            # The cache's `[[series]]` of this name takes these manifests.
            series = "badgeos";
            source = self;
            inherit jobs;
            # A manifest for each job. A manifest evaluates the out paths it lists, and one
            # that listed every job would evaluate them all in one of Hydra's workers.
            shards = lib.length (lib.collect lib.isDerivation jobs);
          }
        else
          { };
    };
}
