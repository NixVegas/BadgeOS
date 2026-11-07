# The LicheeRV Nano's boot chains (SG2002, 256 MiB): sophgone's FSBL, monitors and U-Boot
# with this board's memory map, control DTS, board init and button and LED pins, packed
# into a plain fip for each core and the polyglot that boots whichever core the strap
# selects. Each fip is the fip file itself, with its pieces in passthru.
{
  lib,
  callPackage,
  runCommand,
  python3,
  sophgone,
  # Release PWR_SEQ1/2 (PWR_GPIO3/4) from the RTC power sequencer, for a touchscreen's
  # IRQ and reset.
  touchPads ? false,
}:
let
  fsblFor =
    {
      core,
      slot ? "primary",
    }:
    (callPackage sophgone.lib.fsbl { inherit core slot; }).overrideAttrs (old: {
      pname = "sg2002-licheerv-nano-fsbl-${core}" + lib.optionalString (slot != "primary") "-${slot}";
      postPatch = old.postPatch + ''
        cp -f ${./fsbl-memmap.h} build/cvi_board_memmap.h
        grep -q 'CVIMMAP_DRAM_SIZE *0x10000000UL' build/cvi_board_memmap.h
      '';
      # The Nano has no 32 kHz crystal. Switched to one, the RTC block stops, and every reset
      # request it handles (reboot, the watchdog, the reset button) hangs until a power cycle.
      buildPhase =
        assert lib.hasInfix "SWITCH_32K_XTAL=y" old.buildPhase;
        lib.replaceStrings [ "SWITCH_32K_XTAL=y" ] [ "SWITCH_32K_XTAL=n" ] old.buildPhase;
      installPhase = old.installPhase + ''
        if grep -aq 'Switch RTC mode to xtal32k' $out/bl2.bin; then
          echo "bl2.bin switches the RTC to a 32 kHz crystal the Nano doesn't have" >&2
          exit 1
        fi
      '';
    });

  ubootFor =
    core:
    (callPackage sophgone.lib.${if core == "arm" then "ubootArm" else "ubootRiscv"} { }).overrideAttrs
      (old: {
        pname = "uboot-licheerv-nano-${core}";
        postPatch = old.postPatch + ''
          cp -f ${./cvi_board_init.c} board/cvitek/cvi_board_init.c${lib.optionalString touchPads ''

            cp -f ${./cvi_board_init.c} board/cvitek/licheerv-nano-board-init.c
            cp -f ${./cvi_board_init-touch-pads.c} board/cvitek/cvi_board_init.c''}
          cp -f ${./uboot-memmap.h} include/cvi_board_memmap.h
          cp -f ${controlDts.${core}} arch/${core}/dts/cv181x_cv181xasic.dts
          patch -p1 --fuzz=0 < ${./btnsel.patch}
          patch -p1 --fuzz=0 < ${./statled.patch}

          # BOOT is the user key on XGPIOA 30, there is no USER key, STAT is XGPIOA 14.
          grep -A2 '^static int user_btn_held(void)$' cmd/efuse.c | grep -q '^[[:space:]]*return 0;$'
          grep -q '^#define XGPIOA_BASE[[:space:]]*0x03020000UL$' cmd/efuse.c
          grep -q '^#define BOOT_BTN_BIT[[:space:]]*30$' cmd/efuse.c
          grep -A20 '^static int boot_btn_held(void)$' cmd/efuse.c | grep -q XGPIOA_EXT
          grep -q 'STATLED_PINMUX_BASE + 0x38)' board/cvitek/cv181x/board.c
          grep -q '^#define STATLED_BIT[[:space:]]*14$' board/cvitek/cv181x/board.c
        '';
      });

  controlDts = {
    arm = ./uboot-control-arm.dts;
    riscv = ./uboot-control-riscv.dts;
  };

  fsbl = {
    arm = fsblFor { core = "arm"; };
    riscv = fsblFor { core = "riscv"; };
  };
  uboot = lib.genAttrs [ "arm" "riscv" ] ubootFor;

  # BL31 is a blob with no source: check-bl31.py reads from it that it fits under
  # U-Boot's text base (0x80200000) and serves all 256 MiB.
  bl31Blob = callPackage sophgone.lib.bl31Blob { };
  bl31 = runCommand "sg2002-licheerv-nano-bl31.bin" { nativeBuildInputs = [ python3 ]; } ''
    python3 ${./check-bl31.py} ${bl31Blob} 0x80000000 0x10000000 0x80200000
    cp ${bl31Blob} $out
  '';
  opensbi = callPackage sophgone.lib.opensbi { };

  fipFor =
    core: monitor:
    runCommand "sg2002-licheerv-nano-fip-${core}.bin"
      {
        nativeBuildInputs = [ python3 ];
        passthru = {
          inherit monitor;
          fsbl = fsbl.${core};
          uboot = uboot.${core};
        };
      }
      ''
        # sophgone's genfip arguments (pkgs/fip/package.nix), with the C906L at the top of
        # 256 MB.
        python3 ${fsbl.${core}.src}/plat/cv181x/fiptool.py -v genfip \
          "$out" \
          --MONITOR_RUNADDR=0x80000000 \
          --BLCP_2ND_RUNADDR=0x8FE00000 \
          --CHIP_CONF=${fsbl.${core}}/chip_conf.bin \
          --NOR_INFO=FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF \
          --NAND_INFO=00000000 \
          --BL2=${fsbl.${core}}/bl2.bin \
          --BLCP_IMG_RUNADDR=0x05200200 \
          --BLCP_PARAM_LOADADDR=0 \
          --BLCP=${fsbl.${core}.src}/test/empty.bin \
          --BLCP_2ND=${fsbl.${core}.src}/test/empty.bin \
          --MONITOR=${monitor} \
          --LOADER_2ND=${uboot.${core}}/u-boot-raw.bin \
          --compress=lzma

        size=$(stat -c %s "$out")
        echo "fip size $size B, ceiling 1048576 B"
        if [ "$size" -gt 1048576 ]; then
          echo "fip is $((size - 1048576)) B over the 1048576 B ceiling" >&2
          exit 1
        fi
      '';

  # sophgone's polyglot builders take each piece through callPackage, so these
  # callPackages hand them the Nano's pieces: the BL2 merges the Nano's two FSBLs, and
  # the fip packs it with both monitors and both U-Boots.
  bl2 = callPackage sophgone.lib.mergeBl2 {
    callPackage =
      _:
      {
        core,
        slot ? "primary",
        secureBoot,
      }:
      assert !secureBoot;
      fsblFor { inherit core slot; };
  };
  polyglotPieces = {
    merge-bl2 = bl2;
    fsbl = fsbl.arm;
    bl31-blob = bl31;
    inherit opensbi;
    uboot-arm = uboot.arm;
    uboot-riscv = uboot.riscv;
  };
  fipPolyglot =
    (callPackage sophgone.lib.fipPolyglot {
      callPackage =
        path: _:
        let
          piece = baseNameOf (dirOf path);
        in
        polyglotPieces.${piece} or (throw "sg2k-fips-licheerv-nano: no Nano ${piece} for the polyglot");
    }).overrideAttrs
      {
        name = "sg2002-licheerv-nano-fip-polyglot.bin";
      };
in
{
  fipArm = fipFor "arm" bl31;
  fipRiscv = fipFor "riscv" opensbi;
  inherit fipPolyglot;
}
