# Contributing

BadgeOS lives at [github.com/NixVegas/BadgeOS](https://github.com/NixVegas/BadgeOS), and
pull requests are welcome there. This page is also the repository's `CONTRIBUTING.md`.

## Finding your way around

- `flake.nix` only has the inputs; the outputs are flake-parts modules in `flake/`, with
  `flake/v2` for this year's badge and `flake/v1.nix` for last year's.
- `modules/sg2k` is the NixOS module, with the board files in `modules/sg2k/boards` and
  the per-badge host configurations in `modules/hosts`.
- `pkgs/v2` is the overlay: packages in `by-name`, the device trees in `firmware/dts`,
  the kernel patches in `kernel/patches`, our patches to nixpkgs packages (wlroots,
  sway, pixman and SDL3) in `patches`, and our trims of them (Mesa, SDL3, mpd) in
  `overlays`. `pkgs/v1` is last year's ESP32-C6 firmware.
- `tests` has the checks, `site` is this documentation, and `hydra` declares the Hydra
  jobsets.

## Building and checking

`nix develop` gives you a shell with `deploy` (deploy-rs) for putting your builds on a
badge (see [Updating](site/src/updating.md#deploy-rs)), and `nix fmt` formats the tree with
nixfmt.

The checks are flake checks, so you can build one at a time:

```console
$ nix build .#checks.x86_64-linux.sg2k-no-emmc
```

Most of them evaluate a whole NixOS system or two, which takes a few GB of memory each, so
build them one at a time on a small machine rather than running `nix flake check`. A few
checks and Hydra jobs sign things with our real sg1-image key through autopen (the badge1
cards and bundles, and `rauc-bundle-wrong-compatible`), and those only build on a machine
with the `autopen` system feature.

Hydra builds `hydraJobs`, which has `v1.firmware`, and under `v2` each board's toplevels,
SD card images and fips (`toplevels.<board>`, `images.<board>` and `bootloader.<board>`,
where the badge is `nixbadge`), sophgone's fips (`bootloader.sophgone`), and badge #1's
signed cards and bundles (`badge1`). This site is `nix build .#docs`, and its options reference
is generated from the module, so new options should have a description.

## Branches and releases

Development happens on `master`. When we cut a release, it gets its own
`v<major>.<minor>` branch off `master`, and Hydra builds both: `hydra/jobsets.nix` makes a
jobset for each, and the [download links](site/src/getting-started.md#download-the-sd-card-image)
point at the release's.

The version lives in one place, the flakever template in `flake/version.nix`. BadgeOS's
version, the release branch's name, and the branch in the download links all come from
it. To start a new release, bump the template on `master` and cut the branch. Then add the
old release branch to `branches` in `hydra/jobsets.nix`, or its jobset quietly goes away.

## Style

- Write Nix in nixpkgs style, and run `nix fmt`.
- Keep comments short, and about the code rather than the history of how it got there.
- Don't put big chunks of C, shell, device tree or config inline in Nix. Put them in their
  own files, or in patches, and reference them.
- Keep `flake.nix`, the flake-parts modules, the overlays and the module's `default.nix`
  short, and put test wiring in `tests`.
- When you add an argument to a `package.nix`, check that nixpkgs doesn't have a package
  with the same name, since `callPackage` will pass that package in instead of using your
  default.
- Don't commit keys or other secrets. The two test keys in the repository are there on
  purpose (see [How BadgeOS boots](site/src/under-the-hood.md#signed-firmware-and-verified-boot)).
- Commit messages start with the area they touch, like `sg2k:`, `site:` or `flake:`.

## Using LLMs on BadgeOS

LLMs are often invaluable assistants for hardware bringup. Feel free to contribute using
them, and submit pull requests with code that you understand. We follow Oxide Computer's
[RFD 576](https://rfd.shared.oxide.computer/rfd/0576), "Using LLMs at Oxide".

## Testing on a badge

Deploy with deploy-rs and `--boot`, then reboot, so a bad generation doesn't leave the
badge half switched. Changes to the boot chain or the device tree can stop a badge from
booting, so have the serial console on the DEBUG port handy, and see the
[SoM](site/src/som.md#resetting-a-hung-badge) page for resetting a hung badge.
