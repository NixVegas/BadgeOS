# Trim the assembled runtime tree, including external modules, before depmod.
final: prev: {
  aggregateModules =
    modules:
    (prev.aggregateModules modules).overrideAttrs (old: {
      postBuild = ''
        bash ${./module-symbols.sh} $out ${prev.stdenv.cc.bintools}/bin/${prev.stdenv.cc.targetPrefix}strip
      ''
      + (old.postBuild or "");
    });
}
