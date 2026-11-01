# The two-tier Nix store of a data card boot (nix-badge-stage0/tier2.sh), proven in a VM.
{ pkgs }:
pkgs.testers.nixosTest {
  name = "external-storage-store";
  nodes.machine = {
    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 4096;
    nix.settings.experimental-features = [
      "nix-command"
      "local-overlay-store"
      "read-only-local-store"
    ];
    system.extraDependencies = [
      pkgs.hello
      pkgs.figlet
      pkgs.busybox
    ];
    environment.systemPackages = [ pkgs.e2fsprogs ];
    environment.etc."es/env".text = ''
      HELLO=${pkgs.hello}
      FIGLET=${pkgs.figlet}
      BUSYBOX=${pkgs.busybox}
    '';
    environment.etc."es/tier2.sh".source = ../pkgs/v2/by-name/nix-badge-stage0/tier2.sh;
    environment.etc."es/check.sh".source = ./external-storage-store/check.sh;
  };
  testScript = ''
    machine.wait_for_unit("multi-user.target")
    print(machine.succeed("bash /etc/es/check.sh 2>&1"))
  '';
}
