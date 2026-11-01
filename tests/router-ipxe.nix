# The router and netboot in VMs, with the BSP imported but off: eth1 and eth2 bridged as
# lan0 for a LAN client, a USB-side client, a DHCP prober and a PXE client, and eth3 the
# uplink to a network with DHCP and an HTTP server standing in for the internet.
{
  pkgs,
  # nixosModules.v2
  module,
}:
let
  inherit (pkgs) lib;

  # A kernel and an initrd that only says it booted, in the installer's layout.
  testInitrd = pkgs.makeInitrd {
    contents = [
      {
        object = pkgs.writeScript "init" (builtins.readFile ./router-ipxe/init.sh);
        symlink = "/init";
      }
      {
        object = "${pkgs.pkgsStatic.busybox}/bin/busybox";
        symlink = "/bin/busybox";
      }
    ];
  };
  testNetboot = pkgs.runCommand "test-netboot" { } ''
    mkdir $out
    ln -s ${pkgs.linuxPackages.kernel}/bzImage $out/bzImage
    ln -s ${testInitrd}/initrd $out/initrd
    printf '#!ipxe\nkernel bzImage console=ttyS0 rdinit=/init initrd=initrd\ninitrd initrd\nboot\n' > $out/netboot.ipxe
    cp ${pkgs.ipxe}/ipxe.efi ${pkgs.ipxe}/undionly.kpxe $out/
  '';
  testManual = pkgs.writeTextDir "index.html" "<h1>BADGE-MANUAL</h1>\n";

  dhcpClient = vlan: {
    virtualisation.vlans = [ vlan ];
    virtualisation.memorySize = 512;
    # TFTP data comes back from a new port, which a client firewall drops.
    networking.firewall.enable = false;
    networking.useDHCP = false;
    networking.interfaces.eth1 = {
      useDHCP = true;
      ipv4.addresses = lib.mkForce [ ];
    };
    environment.systemPackages = [
      pkgs.curl
      pkgs.dig
    ];
  };
in
pkgs.testers.nixosTest {
  name = "router-ipxe";

  nodes = {
    upstream = {
      virtualisation.vlans = [ 3 ];
      virtualisation.memorySize = 512;
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
        virtualHosts.internet = {
          default = true;
          locations."/".return = "200 internet";
        };
      };
      environment.systemPackages = [
        pkgs.curl
        pkgs.dig
      ];
    };

    badge = {
      imports = [ module ];
      virtualisation.vlans = [
        1
        2
        3
      ];
      virtualisation.memorySize = 1024;
      networking.useDHCP = false;
      networking.interfaces = lib.genAttrs [ "eth1" "eth2" "eth3" ] (_: {
        ipv4.addresses = lib.mkForce [ ];
      });
      networking.networkmanager.unmanaged = [ "eth0" ];
      # eth2 stands in for usb0, whose netdev u_ether marks DEVTYPE=gadget: NetworkManager's
      # 85-nm-unmanaged.rules leaves such devices unmanaged. udev can't set DEVTYPE, so this
      # sets what that rule sets.
      services.udev.packages = [
        (pkgs.writeTextDir "lib/udev/rules.d/80-usb-gadget-stand-in.rules" ''
          SUBSYSTEM=="net", KERNEL=="eth2", ENV{NM_UNMANAGED}="1"
        '')
      ];
      badge.router = {
        enable = true;
        interfaces = {
          ethernet = "eth1";
          usb = "eth2";
          wifi = "eth3";
        };
      };
      badge.ipxe = {
        enable = true;
        netboot = testNetboot;
        manual = testManual;
        badapple = pkgs.writeText "badapple.ipxe" "#!ipxe\necho apple\n";
      };
      # A saved profile for the Ethernet port must not keep it out of lan0.
      environment.etc."NetworkManager/system-connections/stale-eth1.nmconnection" = {
        mode = "0600";
        text = ''
          [connection]
          id=stale-eth1
          type=ethernet
          interface-name=eth1
          autoconnect=true

          [ipv4]
          method=auto
        '';
      };
    };

    lanclient = lib.mkMerge [
      (dhcpClient 1)
      {
        systemd.services.http8000 = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8000 --directory /etc";
        };
      }
    ];

    usbclient = dhcpClient 2;

    prober = {
      virtualisation.vlans = [ 1 ];
      virtualisation.memorySize = 512;
      networking.useDHCP = false;
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [ ];
      environment.etc."probe.sh" = {
        source = ./router-ipxe/probe.sh;
        mode = "0755";
      };
    };
  };

  testScript = ''
    udhcpc = "${pkgs.busybox}/bin/udhcpc"
    opts = "/run/nix-badge/router/dhcp-opts"


    def probe_until(expect, args=""):
        """Run DHCP probes from prober until a lease offers every line in expect."""
        checks = " && ".join(f"grep -qx '{line}' /tmp/lease" for line in expect)
        prober.wait_until_succeeds(
            "rm -f /tmp/lease; ip link set eth1 up; "
            f"{udhcpc} -i eth1 -n -q -f -t 3 -T 2 -s /etc/probe.sh {args} && {checks}"
        )


    def ip4(machine, dev):
        return machine.succeed(
            f"ip -4 -o addr show {dev} | awk '{{print $4}}' | cut -d/ -f1"
        ).strip()


    start_all()

    with subtest("the badge bridges its LAN ports and has an uplink"):
        badge.wait_for_unit("NetworkManager.service")
        badge.wait_until_succeeds("ip -4 route show default dev eth3 | grep -q via")
        for dev in ["eth1", "eth2"]:
            badge.wait_until_succeeds(f"ip -o link show {dev} | grep -q 'master lan0'")
        badge.wait_for_unit("dnsmasq.service")

    with subtest("a LAN client gets an address and the internet through the badge"):
        lanclient.wait_until_succeeds(
            "ip -4 addr show eth1 | grep -Eq 'inet 10\\.55\\.0\\.1[0-9]{2}/24'"
        )
        lanclient.wait_until_succeeds("ip -4 route show default | grep -q 'via 10.55.0.1'")
        lanclient.succeed("curl -sf --max-time 10 http://192.168.3.1/ | grep -qx internet")
        lanclient.succeed("dig +time=2 +tries=1 @10.55.0.1 example.com")
        lanclient.wait_for_unit("http8000.service")
        lan_ip = ip4(lanclient, "eth1")

    with subtest("the USB side is the same network"):
        usbclient.wait_until_succeeds(
            "ip -4 addr show eth1 | grep -Eq 'inet 10\\.55\\.0\\.1[0-9]{2}/24'"
        )
        usbclient.succeed(f"ping -c1 -W2 {lan_ip}")
        usbclient.succeed(f"curl -sf --max-time 5 http://{lan_ip}:8000/")

    with subtest("PXE clients get the boot file for their firmware"):
        probe_until(["boot_file=undionly.kpxe"], "-x 0x5d:0000")
        probe_until(["boot_file=ipxe.efi"], "-x 0x5d:0007")
        probe_until(["boot_file=ipxe.efi"], "-x 0x5d:0009")
        probe_until(["boot_file=http://10.55.0.1/boot/menu.ipxe"], "-x 0x4d:69505845")
        probe_until(["boot_file=http://10.55.0.1/boot/ipxe.efi"], "-V HTTPClient:Arch:00016")
        # iPXE built for UEFI HTTP boot says both; it must get the menu, not itself again.
        probe_until(
            ["boot_file=http://10.55.0.1/boot/menu.ipxe"],
            "-V HTTPClient:Arch:00016 -x 0x4d:69505845",
        )

    with subtest("TFTP serves the iPXE binaries and autoexec.ipxe on the LAN"):
        for f in ["ipxe.efi", "undionly.kpxe", "autoexec.ipxe"]:
            lanclient.succeed(f"curl -sf --max-time 30 -o /tmp/{f} tftp://10.55.0.1/{f}")
        lanclient.succeed("cmp /tmp/ipxe.efi ${testNetboot}/ipxe.efi")
        lanclient.succeed("cmp /tmp/undionly.kpxe ${testNetboot}/undionly.kpxe")
        lanclient.succeed("grep -qx autoboot /tmp/autoexec.ipxe")

    with subtest("HTTP serves the manual and the netboot tree on the LAN"):
        lanclient.succeed("curl -sf http://10.55.0.1/ | grep -q BADGE-MANUAL")
        lanclient.succeed("curl -sf http://10.55.0.1/boot/menu.ipxe | grep -qx 'chain netboot.ipxe'")
        lanclient.succeed(
            "curl -sf -o /tmp/initrd http://10.55.0.1/boot/initrd && cmp /tmp/initrd ${testNetboot}/initrd"
        )

    with subtest("the gateway and DNS follow the uplink"):
        probe_until(["router=10.55.0.1", "dns=10.55.0.1"])
        badge.succeed("nmcli device disconnect eth3")
        badge.wait_until_succeeds(f"grep -qx option:router {opts}")
        badge.succeed(f"grep -qx option:dns-server {opts}")
        probe_until(["router=", "dns="])
        badge.succeed("nmcli device connect eth3")
        badge.wait_until_succeeds(f"grep -qx option:router,10.55.0.1 {opts}")
        probe_until(["router=10.55.0.1", "dns=10.55.0.1"])

    with subtest("dnsmasq rewrites a missing gateway file when it starts"):
        badge.succeed(f"rm {opts} && systemctl restart dnsmasq")
        badge.succeed(f"grep -qx option:router,10.55.0.1 {opts}")

    with subtest("dnsmasq serves lan0 after the bridge goes away and comes back"):
        badge.succeed("ip link del lan0")
        badge.succeed("systemctl restart dnsmasq")
        badge.succeed("networkctl reload")
        badge.wait_until_succeeds("ip -4 addr show lan0 | grep -q 'inet 10.55.0.1/24'")
        for dev in ["eth1", "eth2"]:
            badge.wait_until_succeeds(f"ip -o link show {dev} | grep -q 'master lan0'")
        probe_until(["router=10.55.0.1"])

    with subtest("a LAN port that disappears and comes back rejoins lan0"):
        mac = badge.succeed("cat /sys/class/net/eth2/address").strip()
        badge.succeed(
            "p=$(readlink -f /sys/class/net/eth2/device); "
            "[ -e $p/remove ] || p=$(dirname $p); echo 1 > $p/remove"
        )
        badge.wait_until_fails("test -e /sys/class/net/eth2")
        badge.succeed("echo 1 > /sys/bus/pci/rescan")
        badge.wait_until_succeeds(
            "for i in /sys/class/net/*; do "
            f"[ \"$(cat $i/address)\" = {mac} ] && "
            "ip -o link show \"$(basename $i)\" | grep -q 'master lan0' && exit 0; "
            "done; exit 1"
        )
        usbclient.wait_until_succeeds(f"ping -c1 -W2 {lan_ip}")

    with subtest("nothing on the uplink reaches the LAN or the badge's services"):
        up_ip = ip4(badge, "eth3")
        upstream.succeed(f"ip route add 10.55.0.0/24 via {up_ip}")
        upstream.fail(f"curl -sf --max-time 5 http://{lan_ip}:8000/")
        upstream.fail(f"dig +time=2 +tries=1 @{up_ip} example.com")
        upstream.fail(f"curl -sf --max-time 5 http://{up_ip}/")
        upstream.fail(f"curl -sf --max-time 10 -o /tmp/ipxe.efi tftp://{up_ip}/ipxe.efi")

    with subtest("a PXE client boots the netboot image through iPXE"):
        pxe = create_machine(
            start_command="${pkgs.qemu_test}/bin/qemu-system-x86_64 -machine accel=kvm:tcg -m 768 -boot n "
            "-device virtio-net-pci,netdev=lan,mac=52:54:00:12:01:42 "
            "-netdev vde,id=lan,sock=$QEMU_VDE_SOCKET_1",
            name="pxe",
        )
        pxe.start()
        pxe.wait_for_console_text("BADGE-NETBOOT-OK")

    with subtest("the LAN does not depend on NetworkManager"):
        badge.succeed("systemctl stop NetworkManager.service")
        badge.succeed("ip -4 addr show lan0 | grep -q 'inet 10.55.0.1/24'")
        mac = badge.succeed("cat /sys/class/net/eth1/address").strip()
        badge.succeed(
            "p=$(readlink -f /sys/class/net/eth1/device); "
            "[ -e $p/remove ] || p=$(dirname $p); echo 1 > $p/remove"
        )
        badge.wait_until_fails("test -e /sys/class/net/eth1")
        badge.succeed("echo 1 > /sys/bus/pci/rescan")
        badge.wait_until_succeeds(
            "for i in /sys/class/net/*; do "
            f"[ \"$(cat $i/address)\" = {mac} ] && "
            "ip -o link show \"$(basename $i)\" | grep -q 'master lan0' && exit 0; "
            "done; exit 1",
            timeout=60,
        )
        lanclient.wait_until_succeeds("ping -c1 -W2 10.55.0.1", timeout=60)
  '';
}
