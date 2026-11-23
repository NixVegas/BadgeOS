# The eval manifests of master's Hydra jobs, evaluated by a Hydra jobset of their own (see
# ../jobsets.nix), so that the main jobsets list only BadgeOS's jobs. They go to the
# cache's series `badgeos`; the release branch's go to its own (./release).
{
  description = "Eval manifests of BadgeOS's Hydra jobs on master, for cache.nixos.lv";

  outputs =
    { self }:
    {
      hydraJobs = import ./manifests.nix {
        inherit self;
        series = "badgeos";
      };
    };
}
