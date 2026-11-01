# The options declared under repoRoot, from a NixOS evaluation of `modules`, and their
# split into pages. Only option declarations are evaluated, so nothing is built.
{
  pkgs,
  lib,
  modules,
  specialArgs,
  modulePlatform,
  repoRoot,
  repoUrl,
  branch,
}:
let
  eval = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = null;
    inherit specialArgs;
    modules = modules ++ [ { nixpkgs.hostPlatform = lib.mkDefault modulePlatform; } ];
  };

  rootPrefix = toString repoRoot + "/";
  nixpkgsPrefix = toString pkgs.path + "/";
  repoName = baseNameOf repoUrl;

  isOurs = decl: lib.hasPrefix rootPrefix (toString decl);

  # The option tree with only the options declared here. Options declared elsewhere are
  # dropped whole, so their sub-options are never visited.
  ourOptions =
    let
      keep =
        opts:
        lib.filterAttrs (_: v: v != { }) (
          lib.mapAttrs (
            _: v:
            if lib.isOption v then
              lib.optionalAttrs (lib.any isOurs v.declarations) v
            else if lib.isAttrs v then
              keep v
            else
              { }
          ) opts
        );
    in
    keep (removeAttrs eval.options [ "_module" ]);

  declaration =
    decl:
    let
      path = toString decl;
      rel = lib.removePrefix rootPrefix path;
    in
    if isOurs path then
      {
        name = "<${repoName}/${rel}>";
        url = "${repoUrl}/blob/${branch}/${rel}";
      }
    else if lib.hasPrefix nixpkgsPrefix path then
      lib.removePrefix nixpkgsPrefix path
    else
      path;

  # Sub-options of an option declared here can come from elsewhere; hide those.
  transformOptions =
    opt:
    opt
    // {
      visible = opt.visible && lib.any isOurs opt.declarations;
      declarations = map declaration opt.declarations;
    };

  doc = pkgs.nixosOptionsDoc {
    options = ourOptions;
    inherit transformOptions;
  };

  optionList = lib.mapAttrsToList (name: opt: opt // { inherit name; }) doc.optionsNix;
  locs = map (opt: opt.loc) optionList;

  # A namespace is a top-level name, followed down while it has exactly one child and no
  # options of its own (hardware -> hardware.sg2k). Each child of a namespace gets a
  # page, and the options right under it share one.
  namespaceOf =
    loc:
    let
      go =
        prefix:
        let
          n = lib.length prefix;
          under = lib.filter (l: lib.take n l == prefix) locs;
          next = lib.unique (map (l: lib.elemAt l n) under);
          hasOwn = lib.any (l: lib.length l <= n + 1) under;
        in
        if !hasOwn && lib.length next == 1 then go (prefix ++ next) else prefix;
    in
    go [ (lib.head loc) ];

  pageOf =
    loc:
    let
      ns = namespaceOf loc;
    in
    if lib.length loc <= lib.length ns + 1 then ns else lib.take (lib.length ns + 1) loc;

  pageId = opt: lib.showOption (pageOf opt.loc);
  fileOf =
    id: "options/${lib.replaceStrings [ "\"" "<" ">" "*" " " "/" ] [ "" "_" "_" "_" "_" "_" ] id}.md";

  pages = lib.mapAttrsToList (id: opts: {
    inherit id;
    path = fileOf id;
    options = map (opt: opt.name) opts;
    sources = lib.unique (lib.concatMap (opt: lib.filter lib.isAttrs opt.declarations) opts);
  }) (lib.groupBy pageId optionList);
in
{
  inherit (doc) optionsJSON;
  pages = pkgs.writeText "badgeos-options-pages.json" (
    builtins.unsafeDiscardStringContext (builtins.toJSON pages)
  );
}
