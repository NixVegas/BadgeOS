# The documentation site: the guide in src/ plus an options reference generated from
# `modules`, built with mdBook. Only option declarations are evaluated.
{
  pkgs,
  lib ? pkgs.lib,
  # The NixOS modules whose options are documented.
  modules,
  specialArgs ? { },
  # nixpkgs.hostPlatform for the evaluation, unless one of the modules sets it.
  modulePlatform ? "aarch64-linux",
  # Options declared under repoRoot are documented, linked to repoUrl at branch.
  repoRoot ? ../.,
  repoUrl ? "https://github.com/NixVegas/BadgeOS",
  branch ? "master",
  # The path the site is served under (https://badge.nix.vegas/ serves it at the root).
  baseHref ? "/",
  # The BadgeOS release and the NixOS label the manual is for; without them it names
  # neither.
  version ? null,
  nixosLabel ? null,
}:
let
  options = import ./options.nix {
    inherit
      pkgs
      lib
      modules
      specialArgs
      modulePlatform
      repoRoot
      repoUrl
      branch
      ;
  };

  servePath = lib.removeSuffix "/" (lib.removePrefix "/" baseHref);
in
pkgs.stdenvNoCC.mkDerivation (finalAttrs: {
  name = "badgeos-docs";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./book.toml
      ./src
      ./assets
    ];
  };

  nativeBuildInputs = [
    # lychee builds its HTTP client even with --offline.
    pkgs.cacert
    pkgs.jq
    pkgs.lychee
    pkgs.mdbook
    pkgs.nixos-render-docs
  ];

  inherit baseHref repoUrl servePath;
  badgeVersion = version;
  # The release branch, @RELEASE@ in the guide: v<major>.<minor>, or master without a version.
  release = if version != null then "v${lib.versions.majorMinor version}" else "master";
  inherit nixosLabel;
  optionsFile = "${options.optionsJSON}/share/doc/nixos/options.json";
  optionsPages = options.pages;
  manpageUrls = pkgs.path + "/doc/manpage-urls.json";
  # For declarations inside nixpkgs, should an option have one.
  nixpkgsRevision = lib.trivial.revisionWithDefault "master";

  buildPhase = ''
    runHook preBuild

    bash ${./render-options.sh} "$optionsFile" "$optionsPages" "$manpageUrls" "$nixpkgsRevision" src
    substituteInPlace src/SUMMARY.md \
      --replace-fail "@OPTIONS_PAGES@" "$(cat options-summary.md)"
    substituteInPlace src/options/index.md \
      --replace-fail "@OPTIONS_OVERVIEW@" "$(cat options-overview.md)"
    substituteInPlace book.toml \
      --replace-fail "@SITE_URL@" "$baseHref" \
      --replace-fail "@REPO_URL@" "$repoUrl" \
      --replace-fail "@VERSION@" "''${badgeVersion:+ $badgeVersion}"
    if [ -n "$badgeVersion" ]; then
      substituteInPlace src/index.md --replace-fail "<!-- @VERSION_NOTE@ -->" \
        "This manual is for BadgeOS $badgeVersion''${nixosLabel:+ on NixOS $nixosLabel}."
    fi
    substituteInPlace src/getting-started.md --replace-fail "@RELEASE@" "$release"

    # index.md and contributing.md are also the repository's README.md and CONTRIBUTING.md,
    # so their links start at the repository root.
    sed -i "s|](site/src/|](|g" src/*.md

    mdbook build --dest-dir "$PWD/book"

    runHook postBuild
  '';

  # Every relative link and #fragment resolves, from where the site is served (404.html
  # links through site-url); external links are not fetched.
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    root=$PWD/served
    mkdir -p "$root/$servePath"
    cp -r book/. "$root/$servePath"
    lychee --offline --include-fragments --no-progress --root-dir "$root" "$root"
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    cp -r book "$out"
    runHook postInstall
  '';

  passthru = {
    inherit (options) optionsJSON;

    # Serves the site on localhost under baseHref; PORT picks the port (8000).
    serve = pkgs.writeShellApplication {
      name = "serve-badgeos-docs";
      runtimeInputs = [ pkgs.python3 ];
      runtimeEnv = {
        site = finalAttrs.finalPackage;
        inherit baseHref servePath;
      };
      text = ''
        root=$site
        if [ -n "$servePath" ]; then
          root=$(mktemp -d)
          trap 'rm -rf "$root"' EXIT
          mkdir -p "$root/$(dirname "$servePath")"
          ln -s "$site" "$root/$servePath"
        fi
        port=''${PORT:-8000}
        echo "BadgeOS docs: http://localhost:$port$baseHref"
        python3 -m http.server --bind 127.0.0.1 --directory "$root" "$port"
      '';
    };
  };
})
