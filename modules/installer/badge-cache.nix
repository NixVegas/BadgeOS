# The live installer substitutes from the badge that netbooted it first (it advertises a
# better priority than cache.nixos.org), then from cache.nixos.org. Plain HTTP: the
# signatures carry the trust. Not in nix-vegas-defaults.nix, which goes home with the laptop.
{
  nix.settings.substituters = [ "http://10.55.0.1" ];
}
