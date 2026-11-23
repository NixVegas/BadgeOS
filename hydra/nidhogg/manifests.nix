# The eval manifests of BadgeOS's Hydra jobs, for the flakes in this directory: each names
# the cache's `[[series]]` its manifests go to. A manifest lists the out paths of the main
# flake's jobs with the rev they were evaluated at; cache.nixos.lv keeps what the manifests
# of recent evals list, and lists their build products for download.
#
# The main flake is loaded from the flake's own source tree, at the same rev and date, so
# it evaluates with its own flake.lock and names the same out paths as its jobset does. A
# flake input would copy the main lock into a lock of this flake's own, which would go stale
# whenever the main lock is updated.
{ self, series }:
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
# A dirty tree has no rev for a manifest to name. Hydra evaluates a commit.
if self ? rev then
  nidhogg-manifest.lib.manifestJobs {
    # Only builds the manifest: bash and coreutils.
    pkgs = nixpkgs-2605.legacyPackages.x86_64-linux;
    inherit series jobs;
    source = self;
    # A manifest for each job. A manifest evaluates the out paths it lists, and one that
    # listed every job would evaluate them all in one of Hydra's workers.
    shards = lib.length (lib.collect lib.isDerivation jobs);
  }
else
  { }
