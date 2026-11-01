# An input-addressed path holding its own name, built offline. Unlike a content-addressed
# path, which Nix accepts without a signature, it is trusted only if a trusted key signed it.
# With `ref`, a store path it names, so that path is its reference.
{
  name,
  ref ? null,
}:
derivation {
  inherit name;
  system = builtins.currentSystem;
  builder = "/bin/sh";
  args = [
    "-c"
    "echo ${name}${if ref == null then "" else " " + builtins.storePath ref} > $out"
  ];
}
