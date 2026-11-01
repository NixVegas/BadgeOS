# Router and netboot

In the default profile, the badge is a small router. Its Ethernet port and its USB-C port
are one network, and the badge routes that network out over WiFi. Plug a laptop into
either port and it gets an address from the badge, reaches the internet through it, and
can boot a NixOS installer from it over the network.

## The badge's network

| | Address |
|---|---|
| Badge | `10.55.0.1/24` |
| Everything plugged into it | from `10.55.0.100` to `10.55.0.200` |

The badge offers itself as the gateway and DNS server only while its WiFi is connected.
Until you [join a network](getting-started.md#wifi), a computer on the USB port keeps
using its own internet, and you can still reach the badge at `10.55.0.1`. The badge's
addresses are leased for two minutes, so within about a minute of its WiFi connecting or
dropping, everything on its network picks up the change.

The badge serves DHCP, DNS, TFTP and HTTP only on its Ethernet and USB ports, never on
WiFi. It forwards traffic from its network out to WiFi, but nothing on the WiFi side can
reach its network.

## Netboot a laptop

The badge serves the Nix Vegas NixOS installer to any x86_64 PC that can boot from the
network:

1. Turn off Secure Boot in the laptop's firmware settings. The iPXE the badge serves isn't
   signed by Microsoft.
2. Plug the laptop into the badge's Ethernet port.
3. Boot it from the network: look for "network boot", "PXE" or "IPv4" in its boot menu.
   UEFI and legacy BIOS both work.
4. iPXE shows the Nix Vegas banner and offers to play Bad Apple. Press a key to watch it,
   or wait five seconds to boot NixOS.

The installer is about 780 MB and the badge's Ethernet runs at 100 Mbit/s, so it takes a
minute or two to load. Once it's up, it has internet through the badge, the Nix Vegas
extras, and a flake in `/etc/nixos` to start your configuration from. It carries firmware
for the common WiFi chips and for Intel and AMD graphics. NVIDIA's doesn't fit on the
badge, so an NVIDIA laptop gets a plainer screen until you install.

Netbooting through the USB port rarely works, since few laptops can boot through a USB
network adapter, so use the Ethernet port.

When you run `nixos-install`, the packages come from [the badge's cache](cache.md) first.
The first laptop fills it; every laptop after that gets most of its packages off the
badge instead of the WiFi.

The badge also serves this manual, at `http://10.55.0.1/`.

## Choosing the uplink

[`badge.router.upstream`](options/badge.router.md#opt-badge.router.upstream) picks the
port the badge routes out of: `"wifi"`, the default, `"ethernet"` or `"usb"`. The other
wired ports make up the badge's network. With `"ethernet"`, the badge is a client on your
wired network and routes for whatever is on its USB port. With `"usb"`, the computer on
the USB port is the uplink, so share its internet connection with the badge, and the
Ethernet port is the badge's network.

## Joining a wired network

In the default profile, a badge plugged into a wired network hands out addresses on it,
the way any router would. To join a wired network as a client instead, set
`badge.router.upstream = "ethernet"`, or boot the [desktop profile](profiles.md#desktop),
where the Ethernet port is always a plain DHCP client and the badge doesn't route.

## Turning it off

[`badge.router.enable`](options/badge.router.md#opt-badge.router.enable) turns the router
off: Ethernet does DHCP again, and the USB link offers no gateway.
[`badge.ipxe.enable`](options/badge.ipxe.md#opt-badge.ipxe.enable) turns off just netboot,
the manual's web server and [the cache](cache.md).
