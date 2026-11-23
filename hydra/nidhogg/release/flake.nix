# The eval manifests of the release branch's Hydra jobs (see ../../jobsets.nix). They go to
# the cache's series `badgeos-v<major>.<minor>`, named after the release this tree's version
# belongs to, so that the cache lists the release's builds apart from master's.
{
  description = "Eval manifests of BadgeOS's Hydra jobs on a release branch, for cache.nixos.lv";

  outputs =
    { self }:
    {
      hydraJobs = import ../manifests.nix {
        inherit self;
        series = "badgeos-" + import ../../release.nix;
      };
    };
}
