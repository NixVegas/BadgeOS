# The v2 Hydra jobs: every job is x86_64-linux (cross-built). The badge1 jobs sign through
# autopen, so they need a builder with the `autopen` system feature.
{
  self,
  v2,
  ...
}:
let
  inherit (v2) pkgsFor sg2kBoards sg2kBoardTable;
in
{
  flake.hydraJobs.v2 =
    let
      pkgs = pkgsFor "x86_64-linux";
      lib = pkgs.lib;
      fips = pkgs.nix-badge-fips { };

      withProducts =
        name: products:
        pkgs.runCommand "${name}-hydra" { } ''
          mkdir -p $out/nix-support
          ${lib.concatMapStringsSep "\n" (
            p:
            if (p.type or "file") == "nix-build" then
              ''
                ln -s ${p.path} $out/${p.file}
                echo "nix-build ${p.subtype} $out/${p.file}" >> $out/nix-support/hydra-build-products
              ''
            else
              ''
                cp -L ${p.path} $out/${p.file}
                echo "file ${p.subtype} $out/${p.file}" >> $out/nix-support/hydra-build-products
              ''
          ) products}
        '';

      # `drv` is the fip file itself: a fip builder's $out, or a file inside one.
      fipProduct =
        name: drv:
        withProducts name [
          {
            subtype = "fip";
            file = "${name}.bin";
            path = drv;
          }
        ];

      # The kernel Image and the DTB as files, and the closure.
      toplevelProducts =
        name: sys:
        let
          tl = sys.config.system.build.toplevel;
        in
        withProducts name [
          {
            subtype = "kernel";
            file = "${name}-Image";
            path = "${tl}/kernel";
          }
          {
            subtype = "dtb";
            file = "${name}.dtb";
            path = "${tl}/dtbs/${sys.config.hardware.deviceTree.name}";
          }
          {
            type = "nix-build";
            subtype = "system";
            file = "${name}-system";
            path = tl;
          }
        ];
      packages = self.packages.x86_64-linux;
      nanoFips = pkgs.sg2k-fips-licheerv-nano;

      # Each board's jobs, under its name in toplevels, images and bootloader: its board in
      # sg2kBoards, its cards, and its fips (`fip` is the polyglot).
      boards = {
        nixbadge = {
          board = "nix-badge";
          cards.sdcard = packages.sg2k-sdcard;
          fips = {
            fip = fips.fipPolyglot;
            fip-arm = fips.fipArm;
            fip-riscv = fips.fipRiscv;
          };
        };
        licheerv-nano = {
          board = "licheerv-nano";
          cards = {
            sdcard = packages.licheerv-nano-sdcard;
            sdcard-arm = packages.licheerv-nano-sdcard-arm;
            sdcard-riscv = packages.licheerv-nano-sdcard-riscv;
          };
          fips = {
            fip = nanoFips.fipPolyglot;
            fip-arm = nanoFips.fipArm;
            fip-riscv = nanoFips.fipRiscv;
          };
        };
      };
    in
    {
      # Each board's generic configuration, per core.
      toplevels = lib.mapAttrs (
        name: b:
        lib.genAttrs sg2kBoardTable.${b.board}.cores (
          core:
          toplevelProducts "${name}-${core}"
            self.nixosConfigurations."${sg2kBoards.${b.board}.prefix}-${core}-x86_64"
        )
      ) boards;
      images = lib.mapAttrs (_: b: b.cards) boards;

      # Badge #1's signed cards and bundles, and the graft a fused badge boots sophgone from.
      badge1 = {
        sdcard = packages.badge1-sdcard;
        secure-sdcard = packages.badge1-secure-sdcard;
        bundle = packages.badge1-bundle;
        secure-bundle = packages.badge1-secure-bundle;
        sophgone-graft = fipProduct "sophgone-graft" "${packages.sophgone-exploit-signed-enc}/fip.bin";
      };
      bootloader =
        lib.mapAttrs (name: b: lib.mapAttrs (fip: fipProduct "${name}-${fip}") b.fips) boards
        // {
          # The pair for an unfused badge: SD:/fip.bin chainloads SD:/sophg.1.
          sophgone = {
            fip = fipProduct "sophgone-fip" fips.chainloadFip;
            sophg1 = fipProduct "sophgone-sophg1" fips.sophg1;
          };
        };
    };

}
