# The badge's cache

Every laptop that installs NixOS from the badge wants the same few gigabytes of packages,
and at DEF CON they all come over the same WiFi. So the badge keeps them. It's a binary
cache for everything on its network: the netbooted installer asks the badge first, the
badge fetches each path once, from cache.nixos.lv or else cache.nixos.org, hands it to you
as it arrives, and keeps a copy. The next laptop gets that copy over Ethernet. Everyone
wins, especially the WiFi.

## When it runs

The cache runs with a [data card](data-cards.md) in, or on a badge booted from its SD
card, and only in the default profile, where the badge is a [router](router.md). The eMMC
has about 800 MB to spare, which is roughly one web browser, so the cache stays off there.

To check, from a computer on the badge's network:

```console
$ curl http://10.55.0.1/nix-cache-info
StoreDir: /nix/store
WantMassQuery: 1
Priority: 30
```

A 404 means it isn't running. Nix asks caches in priority order, lowest first, and 30
beats cache.nixos.org's 40, so a laptop asks the badge before it asks the internet.

## What it keeps

The first fetch of a path goes at the speed of the badge's WiFi. After that it comes off
the card, at up to the Ethernet port's 100 Mbit/s.

Nix only keeps a path once everything it refers to is there too, and a netbooted laptop
already has the installer's own packages, so it never asks the badge for those. The badge
fetches them itself, in the background, and only while no laptop is downloading from it:
your install gets the WiFi first. So the first install on a card pulls the
installer's base system over the WiFi one more time, and every install after that gets
all of it from the badge.

Everything lives on the card, next to whatever else the badge writes. Every five minutes
the badge checks: under 4 GiB free, it stops keeping new paths and collects garbage until
8 GiB are free again. The cache is only packages the badge can fetch again, so nothing
is lost but time.

## Trust but verify

The badge signs nothing. It passes on the signatures the paths came with, from
cache.nixos.org and our Hydra, so your laptop trusts exactly what it would have trusted
anyway. That's also why plain HTTP is fine. A path signed by anyone else is neither kept
on the badge nor accepted by your laptop.

See for yourself. Ask the badge about any package from nixpkgs on your laptop, using the
first 32 characters of its name, and the signature is right there in the answer, even for
a path the badge has never seen:

```console
$ curl -s http://10.55.0.1/<hash>.narinfo | grep ^Sig:
Sig: cache.nixos.org-1:...
```

## Use it from another machine

Any NixOS machine on the badge's network can use it too. Allow it once in your
configuration:

```nix
nix.settings.trusted-substituters = [ "http://10.55.0.1" ];
nix.settings.extra-trusted-public-keys = [
  "citadel.build.dc.nixos.lv-1:UZbkvFcWZr/VP7cvNPLRpcMTCvaYw7X5XQDzA+nPVxY="
];
```

That key is our Hydra's. Leave it out and you still get everything from cache.nixos.org,
just not what we built. Then, while you're plugged into the badge, ask for it:

```console
$ sudo nixos-rebuild switch --option extra-substituters http://10.55.0.1
```

`nix build` and friends take the same `--option`. We don't recommend making the badge a
permanent substituter: once you've left its network, Nix would knock on 10.55.0.1 before
every download, and wait a good while for nobody to answer.

## Options

[`badge.cache.enable`](options/badge.cache.md#opt-badge.cache.enable) follows
[`badge.ipxe.enable`](options/badge.ipxe.md#opt-badge.ipxe.enable) and needs it: the
cache answers on the same web server as the netboot files. And
[`badge.cache.upstreams`](options/badge.cache.md#opt-badge.cache.upstreams) lists where
misses come from, in order.
