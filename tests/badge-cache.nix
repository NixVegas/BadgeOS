# The badge's binary cache in VMs: an upstream serving two signed file caches, the badge
# (router, iPXE and cache, as on an SD boot) pulling through from them, and a LAN client
# that substitutes only from the badge.
{
  pkgs,
  # nixosModules.v2
  module,
}:
let
  inherit (pkgs) lib;

  # test-cache-1 is trusted by the badge and the client, test-cache-2 by neither. Each
  # trust-N.conf is a nix.conf fragment, so the keys never pass through evaluation.
  keys = pkgs.runCommand "test-cache-keys" { nativeBuildInputs = [ pkgs.nix ]; } ''
    export HOME=$TMPDIR
    mkdir $out
    for n in 1 2; do
      nix --extra-experimental-features nix-command key generate-secret --key-name test-cache-$n > $out/secret-$n
      nix --extra-experimental-features nix-command key convert-secret-to-public < $out/secret-$n > $out/public-$n
      echo "extra-trusted-public-keys = $(cat $out/public-$n)" > $out/trust-$n.conf
    done
  '';

  testNetboot = pkgs.runCommand "test-netboot" { } ''
    mkdir $out
    printf '#!ipxe\necho netboot\n' > $out/netboot.ipxe
    cp ${pkgs.ipxe}/ipxe.efi ${pkgs.ipxe}/undionly.kpxe $out/
  '';
  testManual = pkgs.writeTextDir "index.html" "<h1>BADGE-MANUAL</h1>\n";
in
pkgs.testers.nixosTest {
  name = "badge-cache";

  nodes = {
    upstream = {
      virtualisation.vlans = [ 3 ];
      virtualisation.memorySize = 768;
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
        {
          address = "192.168.3.1";
          prefixLength = 24;
        }
      ];
      networking.firewall.enable = false;
      services.dnsmasq = {
        enable = true;
        settings = {
          interface = "eth1";
          bind-interfaces = true;
          port = 0;
          dhcp-range = [ "192.168.3.100,192.168.3.200,1h" ];
          dhcp-option = [ "option:router,192.168.3.1" ];
        };
      };
      services.nginx = {
        enable = true;
        virtualHosts.upstream-a.root = "/var/cache-a";
        virtualHosts.upstream-b.root = "/var/cache-b";
      };
      nix.settings.experimental-features = [ "nix-command" ];
      environment.etc."cache-test-path.nix".source = ./badge-cache/path.nix;
    };

    badge = {
      imports = [ module ];
      virtualisation.vlans = [
        1
        3
      ];
      virtualisation.memorySize = 1024;
      boot.kernelParams = [ "nixbadge.bootmedium=1" ];
      networking.useDHCP = false;
      # The test network's static addresses, IPv6 included: NetworkManager takes a port that
      # already has an address as configured elsewhere, and never asks DHCP for the uplink.
      networking.interfaces = lib.genAttrs [ "eth1" "eth2" ] (_: {
        ipv4.addresses = lib.mkForce [ ];
        ipv6.addresses = lib.mkForce [ ];
      });
      networking.networkmanager.unmanaged = [ "eth0" ];
      networking.hosts."192.168.3.1" = [
        "upstream-a"
        "upstream-b"
      ];
      badge.router = {
        enable = true;
        interfaces = {
          ethernet = "eth1";
          wifi = "eth2";
        };
      };
      badge.ipxe = {
        enable = true;
        netboot = testNetboot;
        manual = testManual;
        badapple = pkgs.writeText "badapple.ipxe" "#!ipxe\necho apple\n";
      };
      badge.cache.upstreams = [
        "http://upstream-a"
        "http://upstream-b"
      ];
      # The VM's disk is smaller than the card's free-space floor.
      services.harmonia.cache.settings.miss_min_free_bytes = lib.mkForce 0;
      # The daemon fetches missing references from its own substituters.
      nix.settings.substituters = lib.mkForce [
        "http://upstream-a"
        "http://upstream-b"
      ];
      nix.extraOptions = "include ${keys}/trust-1.conf";
    };

    client = {
      virtualisation.vlans = [ 1 ];
      virtualisation.memorySize = 768;
      networking.firewall.enable = false;
      networking.useDHCP = false;
      networking.interfaces.eth1 = {
        useDHCP = true;
        ipv4.addresses = lib.mkForce [ ];
      };
      nix.settings = {
        substituters = lib.mkForce [ "http://10.55.0.1" ];
        trusted-public-keys = lib.mkForce [ ];
        connect-timeout = 5;
      };
      nix.extraOptions = "include ${keys}/trust-1.conf";
      environment.systemPackages = [ pkgs.curl ];
      environment.etc."cache-test-path.nix".source = ./badge-cache/path.nix;
    };
  };

  testScript = ''
    import os
    import re

    def add(name):
        """A new input-addressed path, in upstream's store only."""
        return upstream.succeed(
            f"nix-build --no-out-link /etc/cache-test-path.nix --argstr name {name}"
        ).strip()

    def add_ref(name, ref):
        """A new path in upstream's store that refers to `ref`."""
        return upstream.succeed(
            f"nix-build --no-out-link /etc/cache-test-path.nix --argstr name {name} --argstr ref {ref}"
        ).strip()

    def to_cache(cache, key, path):
        upstream.succeed(
            f"nix copy --to 'file:///var/cache-{cache}?secret-key=${keys}/secret-{key}' {path}"
        )

    def hash_of(path):
        return os.path.basename(path)[:32]

    def status(url, timeout=2):
        return client.succeed(
            f"curl -s -o /dev/null -w '%{{http_code}}' --max-time {timeout} http://10.55.0.1/{url}"
        ).strip()

    start_all()

    upstream.wait_for_unit("nginx.service")
    upstream.succeed("mkdir -p /var/cache-a /var/cache-b")
    a = add("cache-test-a")
    b = add("cache-test-b")
    u = add("cache-test-u")
    c = add("cache-test-c")
    q = add("cache-test-q")
    r = add_ref("cache-test-r", q)
    to_cache("a", 1, a)
    to_cache("b", 1, b)
    to_cache("a", 2, u)
    to_cache("a", 1, r)

    badge.wait_for_unit("nginx.service")
    badge.wait_until_succeeds("ip -4 route show default dev eth2 | grep -q via")
    client.wait_until_succeeds("ip -4 addr show eth1 | grep -q 'inet 10\\.55\\.0\\.'")

    with subtest("the badge says it is the better cache"):
        client.succeed("curl -sf http://10.55.0.1/nix-cache-info | grep -qx 'Priority: 30'")

    with subtest("a path is pulled through from the second upstream"):
        client.succeed(f"nix-store -r {b}")
        client.succeed(f"grep -qx cache-test-b {b}")
        badge.wait_until_succeeds(f"nix-store --check-validity {b}")

    with subtest("a hit comes from the badge's store, with upstream's signature"):
        upstream.succeed("systemctl stop nginx.service")
        narinfo = client.succeed(f"curl -sf http://10.55.0.1/{hash_of(b)}.narinfo")
        assert re.search(r"^URL: nar/[0-9a-z]+\.nar\?hash=", narinfo, re.M), narinfo
        assert re.search(r"^Sig: test-cache-1:", narinfo, re.M), narinfo
        # A freshly netbooted laptop has no narinfo disk cache either.
        client.succeed(
            f"nix-store --delete {b} && nix-store -r {b} --option narinfo-cache-positive-ttl 0"
        )
        upstream.succeed("systemctl start nginx.service")

    with subtest("a path no upstream has is a 404"):
        assert status(f"{hash_of(c)}.narinfo", timeout=30) == "404"

    with subtest("upstream's signatures pass through"):
        client.succeed(f"curl -sf http://10.55.0.1/{hash_of(a)}.narinfo | grep -q '^Sig: test-cache-1:'")
        client.succeed(f"nix-store -r {a}")

    with subtest("a path is cached with the reference the client already had"):
        # The client builds Q itself, so it asks the badge for R alone.
        assert client.succeed(
            "nix-build --no-out-link /etc/cache-test-path.nix --argstr name cache-test-q"
        ).strip() == q
        client.succeed(f"nix-store -r {r}")
        badge.wait_until_succeeds(f"nix-store --check-validity {r}")
        badge.succeed(f"nix-store --check-validity {q}")

    with subtest("a path signed by an untrusted key is neither accepted nor kept"):
        client.fail(f"nix-store -r {u}")
        narinfo = client.succeed(f"curl -sf http://10.55.0.1/{hash_of(u)}.narinfo")
        url = next(l[5:] for l in narinfo.splitlines() if l.startswith("URL: "))
        client.execute(f"curl -s --max-time 30 -o /dev/null 'http://10.55.0.1/{url}'")
        badge.wait_until_succeeds(
            f"journalctl -u harmonia.service | grep -F 'nar job' | grep -F {os.path.basename(u)} | grep -q failed"
        )
        badge.fail(f"nix-store --check-validity {u}")
        client.succeed(f"nix-store --delete {a} && nix-store -r {a}")

    with subtest("the manual and the netboot files are unchanged"):
        client.succeed("curl -sf http://10.55.0.1/ | cmp - ${testManual}/index.html")
        client.succeed("curl -sf http://10.55.0.1/boot/netboot.ipxe | cmp - ${testNetboot}/netboot.ipxe")

    with subtest("with Harmonia down every cache URL is a 404, at once"):
        badge.succeed("systemctl stop harmonia.socket harmonia.service")
        assert status("nix-cache-info") == "404"
        assert status(f"{hash_of(a)}.narinfo") == "404"
        client.succeed("curl -sf http://10.55.0.1/ | grep -q BADGE-MANUAL")
  '';
}
