# makeBootImage { sys, core, secure, fitKeyCert, raucExternal ? true, dataCard ? false,
# signArgs ? { } }: the generation image, one FIT with every boot profile of a toplevel
# (default, plus the desktop and video specialisations), which U-Boot's nixbadge_fit
# loads from /<core>/slot-<X>/boot.itb. raucExternal = false (no eMMC: the SD slots are
# RAUC's own) drops ${rauc_ext} from the command line.
# dataCard = true (hardware.sg2k.externalStorage) puts nixbadge-datacard = "1" at the
# FIT's root: U-Boot looks for a data card's FIT for the slot only when it is there.
# Only each profile's kernel, DTB and kernelParams are read from sys, so tests pass a mock.
# -> $out/boot.itb, $out/.secure, $out/profiles; passthru.scripts and passthru.kernels
# are the derivations the command-line and kernel-size checks fail.
#
# Per profile <p>: conf-<p> = { kernel, fdt-<p> } and script-<p>, which U-Boot sources
# with verityargs, rauc_slot, rauc_ext, bootmedium, loadaddr and nixbadge_args set (hush
# expands them, so they are written literally). The script ends `bootm ...; false`, so
# `source` fails if bootm returns, with no trailing newline: U-Boot 2021.10's hush would
# return the status of the empty last line, 0.
{
  lib,
  runCommand,
  callPackage,
  stdenv,
  nix-badge-fit-signing,
  sophgone,
}:
let
  inherit (nix-badge-fit-signing) signFit;

  makeBootImage =
    {
      sys,
      core,
      secure,
      fitKeyCert,
      raucExternal ? true,
      dataCard ? false,
      signArgs ? { },
    }:
    let
      cfg = sys.config;

      arch =
        {
          arm = "arm64";
          riscv = "riscv";
        }
        .${core} or (throw "makeBootImage: core must be arm or riscv, not ${core}");

      profiles = [
        "default"
      ]
      ++ lib.attrNames (lib.filterAttrs (n: _: n == "desktop" || n == "video") cfg.specialisation);
      cfgOf = p: if p == "default" then cfg else cfg.specialisation.${p}.configuration;

      kernelOf =
        p:
        let
          c = cfgOf p;
        in
        "${c.boot.kernelPackages.kernel}/${c.system.boot.loader.kernelFile}";
      dtbOf =
        p:
        let
          c = cfgOf p;
        in
        "${c.hardware.deviceTree.package}/${c.hardware.deviceTree.name}";

      # Kernels deduplicated by store path: the image is named after the first profile
      # that boots it (default first, so the base kernel is plain `kernel`).
      kernelOwner = p: lib.findFirst (q: kernelOf q == kernelOf p) p profiles;
      kernelName = p: if kernelOwner p == "default" then "kernel" else "kernel-${kernelOwner p}";
      kernelProfiles = lib.filter (p: kernelOwner p == p) profiles;

      # /init-<core> is stage-0's link in the squashfs root: a signed script never names a
      # store path.
      paramsOf = p: (cfgOf p).boot.kernelParams;
      lineOf =
        p:
        lib.concatStringsSep " " (
          [
            "init=/init-${core}"
            "nixbadge.profile=${p}"
          ]
          ++ paramsOf p
          ++ [
            "\${verityargs}"
            "rauc.slot=\${rauc_slot}"
          ]
          ++ lib.optional raucExternal "\${rauc_ext}"
          ++ [
            "nixbadge.bootmedium=\${bootmedium}"
            "\${nixbadge_args}"
          ]
        );
      # Inside hush double quotes only \ and " need escaping; $ stays live on purpose.
      hushQuote = s: ''"${lib.replaceStrings [ "\\" "\"" ] [ "\\\\" "\\\"" ] s}"'';
      scriptOf = p: "setenv bootargs ${hushQuote (lineOf p)}\nbootm \${loadaddr}#conf-${p}; false";

      # riscv's COMMAND_LINE_SIZE is 1024 and the kernel truncates silently, so the build
      # fails instead: the line without its ${...} references, plus 400 bytes for the
      # slot's verity fragment and 64 for the other runtime values, within 1000.
      fixedLength =
        p:
        lib.stringLength (
          lib.concatStrings (lib.filter lib.isString (builtins.split "\\$\\{[A-Za-z0-9_]+}" (lineOf p)))
        );
      budgetCheck =
        p:
        let
          total = fixedLength p + 400 + 64;
        in
        lib.optionalString (core == "riscv" && total > 1000) ''
          echo "boot-image: riscv command line would exceed 1000 bytes (profile ${p}: ${toString (fixedLength p)} fixed + 400 verity reserve + 64 runtime = ${toString total})" >&2
          exit 1
        '';

      scriptAttr = p: "script_${p}";
      # The scripts as files (mkimage /incbin/s them), written byte-exact through
      # passAsFile: no trailing newline is added.
      scripts =
        runCommand "boot-image-scripts-${core}"
          (
            {
              passAsFile = map scriptAttr profiles;
            }
            // lib.listToAttrs (map (p: lib.nameValuePair (scriptAttr p) (scriptOf p)) profiles)
          )
          ''
            ${lib.concatMapStrings budgetCheck profiles}
            mkdir $out
            ${lib.concatMapStrings (p: ''cp "''$${scriptAttr p}Path" $out/script-${p}'' + "\n") profiles}
          '';

      # The most bootm decompresses, and the room from the kernel's load address to
      # fdt_addr_r, where the slot's vbmeta loads.
      bootmLen = 67108864; # CONFIG_SYS_BOOTM_LEN = 64 << 20
      kernelRoom = 117440512; # 0x7000000 = 0x88000000 - 0x81000000
      # One derivation per distinct kernel: the size check, then gzip -9n (reproducible).
      # bootm gunzips it; compressed, two slots per core fit the 512 MiB boot FAT.
      kernelGz =
        p:
        runCommand "boot-image-${core}-${kernelName p}.gz" { } ''
          size=$(stat -L -c %s ${kernelOf p})
          if [ "$size" -gt ${toString bootmLen} ] || [ "$size" -ge ${toString kernelRoom} ]; then
            echo "boot-image: the ${core} kernel ${kernelOf p} is $size bytes uncompressed; it must be <= ${toString bootmLen} (64 MiB, CONFIG_SYS_BOOTM_LEN) and < 0x7000000 (from 0x81000000 to fdt_addr_r)" >&2
            exit 1
          fi
          mkdir $out
          gzip -9n < ${kernelOf p} > $out/Image.gz
        '';
      kernels = lib.listToAttrs (map (p: lib.nameValuePair (kernelName p) (kernelGz p)) kernelProfiles);

      imgSig = lib.optionalString secure ''
        signature-1 { algo = "sha256,rsa2048"; key-name-hint = "sg1-image-img"; };
      '';
      image = name: file: compression: attrs: ''
        ${name} {
          data = /incbin/("${file}");
          ${attrs}
          compression = "${compression}";
          hash-1 { algo = "sha256"; };
          ${imgSig}
        };
      '';

      its = ''
        /dts-v1/;
        / {
          description = "nix-badge generation image (${core})";${lib.optionalString dataCard " nixbadge-datacard = \"1\";"}
          #address-cells = <1>;
          images {
            ${lib.concatMapStrings (
              p:
              image (kernelName p) "${kernels.${kernelName p}}/Image.gz" "gzip" ''
                type = "kernel"; arch = "${arch}"; os = "linux";
                load = <0x81000000>; entry = <0x81000000>;
              ''
            ) kernelProfiles}
            ${lib.concatMapStrings (
              p: image "fdt-${p}" (dtbOf p) "none" ''type = "flat_dt"; arch = "${arch}";''
            ) profiles}
            ${lib.concatMapStrings (
              p: image "script-${p}" "${scripts}/script-${p}" "none" ''type = "script";''
            ) profiles}
          };
          configurations {
            default = "conf-default";
            ${lib.concatMapStrings (p: ''
              conf-${p} {
                kernel = "${kernelName p}";
                fdt = "fdt-${p}";
                ${lib.optionalString secure ''
                  signature-1 {
                    algo = "sha256,rsa2048";
                    key-name-hint = "sg1-image";
                    sign-images = "kernel", "fdt";
                  };
                ''}
              };
            '') profiles}
          };
        };
      '';
    in
    (signFit (
      {
        name = "boot";
        inherit its secure;
        cert = fitKeyCert;
      }
      // signArgs
    )).overrideAttrs
      (old: {
        buildCommand = old.buildCommand + ''
          printf '%s\n' ${lib.escapeShellArgs profiles} > $out/profiles
        '';
        passthru = (old.passthru or { }) // {
          inherit scripts profiles kernels;
        };
      });
in
lib.setFunctionArgs makeBootImage (lib.functionArgs makeBootImage)
// {
  passthru.tests = {
    # system: a badge1-arm nixosConfiguration.
    boot-image =
      { system }:
      callPackage ./test.nix {
        realSystem = system;
        sandbox = sophgone.packages.${stdenv.buildPlatform.system}.uboot-sandbox;
      };
  };
}
