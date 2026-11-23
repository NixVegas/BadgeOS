# PNG-only swaybg avoids the general image loader and its extra dependencies.
{
  swaybg,
  meson,
  ninja,
  pkg-config,
  wayland-scanner,
  wayland,
  wayland-protocols,
  cairo,
}:
swaybg.overrideAttrs {
  nativeBuildInputs = [
    meson
    ninja
    pkg-config
    wayland-scanner
  ];
  buildInputs = [
    wayland
    wayland-protocols
    cairo
  ];
  mesonFlags = [
    "-Dgdk-pixbuf=disabled"
    "-Dman-pages=disabled"
  ];
  postInstall = "";
}
