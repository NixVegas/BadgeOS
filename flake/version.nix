# The flake's version, the `flakever` module argument: BadgeOS and the v1 firmware take
# their versions from it, and Hydra builds a jobset for the release branch
# v<major>.<minor> (hydra/jobsets.nix reads the template from here, without the inputs).
{ inputs, ... }:
{
  flake.versionTemplate = "2.1.0-<lastModifiedDate>-<rev>";

  _module.args.flakever = inputs.flakever.lib.mkFlakever {
    inherit inputs;

    digits = [
      1
      2
      2
    ];
  };
}
