# Last year's badge (ESP32-C6): its firmware and dev shell. Needs the esp-dev overlay.
{ flakever }:
final: prev: {
  inherit flakever;
  nix-badge-v1 = final.callPackage ./nix-badge-v1/package.nix {
    target = "esp32c6";
    esp-idf = final.esp-idf-riscv;
  };
}
