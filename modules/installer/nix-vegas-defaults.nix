{
  lib,
  config,
  pkgs,
  ...
}:

let
  extras = [
    "git"
    "wget"
    "htop"
    "tmux"
    "aircrack-ng"
    "nmap"
    "rogue"
    "opencode"
  ];

  consoleTmux = pkgs.writeShellApplication {
    name = "nixvegas-console-tmux";
    runtimeInputs = [ pkgs.tmux ];
    text = ''
      session="nixvegas"
      if ! tmux has-session -t "$session" 2>/dev/null; then
        tmux new-session -d -s "$session" -n shell
        tmux new-window -t "$session" -n opencode 'opencode; exec bash'
        tmux new-window -t "$session" -n rogue 'rogue; exec bash'
        tmux select-window -t "$session:shell"
      fi
      exec tmux attach-session -t "$session"
    '';
  };
in
{
  # Work on serial consoles
  boot.kernelParams = lib.mkAfter [
    "console=tty0"
    "console=ttyS0,115200n8"
  ];

  environment.systemPackages = map (x: pkgs.${x}) extras;

  environment.interactiveShellInit = ''
    cat ${config.users.motdFile}
  '';

  # On the autologin console (nixos user), land in the tmux session above. Only
  # the first VT and first serial console, so switching to another VT (or a
  # second serial) gets a plain shell rather than another mirrored client. Also
  # guard on $TMUX so a shell opened inside tmux doesn't recurse, and on SSH/pty
  # logins (whose tty is /dev/pts/*) getting a plain shell.
  environment.loginShellInit = ''
    case "$(tty)" in
      /dev/tty1|/dev/ttyS0)
        if [ -z "''${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
          echo "About to launch tmux..." >&2
          sleep 5
          ${lib.getExe consoleTmux} || true
        fi
        ;;
    esac
  '';

  # Banner shown at login.
  users.motdFile = pkgs.writeText "motd" ''
    ${lib.readFile ./motd.txt}

    You can edit this configuration in /etc/nixos/configuration.nix,
    and run `nixos-rebuild switch --flake .` from there to rebuild

    We gave you some extras by default, have fun:
    ${lib.concatStringsSep " " extras}
  '';

  # Customize the vendor name and hostname
  system.nixos.vendorName = "Nix Vegas";
  networking.hostName = lib.mkDefault "nixvegas";
  console.font = lib.mkDefault "sun12x22";

  networking.wireless = {
    enable = true;
  };

  # Defaults to include in case they decide to modify their config.
  environment.etc."nixos/flake.nix" = {
    mode = "0644";
    text = lib.readFile ./flake.nix;
  };
  environment.etc."nixos/flake.lock" = {
    mode = "0644";
    text = lib.readFile ./flake.lock;
  };
  environment.etc."nixos/nix-vegas-defaults.nix" = {
    mode = "0644";
    text = lib.readFile ./nix-vegas-defaults.nix; # it us
  };
  environment.etc."nixos/motd.txt" = {
    mode = "0644";
    text = config.users.motd;
  };

  nix.settings.extra-experimental-features = [
    "nix-command"
    "flakes"
  ];
  # What the Nix Vegas Hydra builds is signed on citadel; this file goes to /etc/nixos,
  # so the key is spelled out rather than read from the repo.
  nix.settings.extra-trusted-public-keys = [
    "citadel.build.dc.nixos.lv-1:UZbkvFcWZr/VP7cvNPLRpcMTCvaYw7X5XQDzA+nPVxY="
  ];

  # So people's wifi actually works
  hardware.enableAllFirmware = true;

  nixpkgs = {
    system = lib.mkDefault "x86_64-linux";
    config.allowUnfree = true;
  };
}
