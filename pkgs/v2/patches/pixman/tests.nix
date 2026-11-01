# pixman's blitters-test and lowlevel-blt-bench, linked statically against the
# given pixman so they run on the badge with nothing but glibc.
{ pixman }:
pixman.overrideAttrs (old: {
  pname = "pixman-badge-tests";

  mesonFlags = (old.mesonFlags or [ ]) ++ [
    "-Ddefault_library=static"
    "-Dtests=enabled"
    # Both would add shared libraries beyond glibc to the test programs.
    "-Dlibpng=disabled"
    "-Dopenmp=disabled"
  ];

  doCheck = false;

  postInstall = (old.postInstall or "") + ''
    install -Dm755 -t $out/bin test/blitters-test test/lowlevel-blt-bench
  '';
})
