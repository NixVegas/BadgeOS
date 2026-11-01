# A squashfs that is a rooted Nix store: nix/store plus the database for exactly those
# paths, so the kernel boots it as root and the daemon uses it as the lower store of a
# local-overlay-store. A dm-verity hash tree follows the data in the same file (no
# superblock, fixed salt), with roothash, verity.env and verity-append (the dm-mod.create=
# fragment) beside it. /init-<core> links each core's stage-0, so the kernel line names
# no store path. vbmeta.itb, the slot's signed verity fragment, is built after the image
# by small derivations, so a signer fetches only the fragment text.
# `systems` may be mocks: only toplevel, hostPlatform.system and nix.package.version
# are read.
{
  lib,
  stdenv,
  callPackage,
  runCommand,
  closureInfo,
  squashfsTools,
  nix,
  sqlite,
  cryptsetup,
  ubootTools,
  nix-badge-fit-signing,
  sophgone,
}:
let
  inherit (nix-badge-fit-signing) signFit;

  makeStoreSquashfs =
    {
      systems,
      # { <core> = stage-0; } for exactly the cores of systems
      stage0s,
      secure ? false,
      fitKeyCert ? null,
    }:
    let
      toplevels = map (s: s.config.system.build.toplevel) systems;
      primary = lib.head toplevels;
      coreOf = s: if s.config.nixpkgs.hostPlatform.system == "aarch64-linux" then "arm" else "riscv";
      cores = lib.attrNames stage0s;
      closure = closureInfo {
        rootPaths = toplevels ++ lib.attrValues stage0s;
      };
      # The build host's nix writes the lower DB, so its version must match the nix each
      # badge's daemon reads it with.
      versionMismatches = lib.filter (s: s.config.nix.package.version != nix.version) systems;
      image =
        runCommand "sg2k-store-squashfs-image"
          {
            nativeBuildInputs = [
              squashfsTools
              nix
              sqlite
              cryptsetup
            ];
            closureInfo = closure;
            passthru.closureInfo = closure;
          }
          ''
            mkdir -p stage/nix/store stage/nix/var/nix/profiles stage/bin stage/usr stage/lib stage/etc stage/var stage/tmp stage/home stage/root stage/run stage/boot stage/srv stage/mnt stage/proc stage/sys stage/dev stage/.userdata stage/nix/.ro-store \
              stage/.lower-userdata stage/boot-card stage/nix/.lower-store/nix/store stage/nix/.lower-store/nix/var
            # 1) the store paths, as directories at their store path (reflink where the fs can)
            while read -r p; do cp -a --reflink=auto "$p" stage/nix/store/; done < "$closureInfo/store-paths"
            # 2) the database for exactly these paths (make-disk-image.nix's recipe); the
            #    build-host nix writes it, the schema is the one every 2.x reads.
            export NIX_STATE_DIR="$PWD/state"
            nix-store --load-db < "$closureInfo/registration"
            test -f state/db/db.sqlite
            cp -a state/db stage/nix/var/nix/db
            # 3) every directory Nix 2.34's LocalStore creates even read-only, and the
            #    reserved-space file: one missing on the squashfs fails every client.
            mkdir -p stage/nix/store/.links stage/nix/var/nix/temproots stage/nix/var/nix/gcroots/per-user stage/nix/var/nix/profiles/per-user
            chmod 1775 stage/nix/store
            head -c 8388608 /dev/zero > stage/nix/var/nix/db/reserved
            cp "$closureInfo/registration" stage/nix-path-registration
            ${lib.concatMapStrings (s: ''
              ln -s ${s.config.system.build.toplevel} stage/nix/var/nix/profiles/system-${coreOf s}-1-link
              ln -s system-${coreOf s}-1-link stage/nix/var/nix/profiles/system-${coreOf s}
            '') systems}
            ln -s ${primary} stage/nix/var/nix/profiles/system
            # 4) the constant per-core init= targets
            ${lib.concatStrings (
              lib.mapAttrsToList (core: stage0: ''
                ln -s ${stage0}/bin/nix-badge-stage0 stage/init-${core}
              '') stage0s
            )}
            mkdir -p "$out"
            SOURCE_DATE_EPOCH=0 mksquashfs stage "$out/store.squashfs" \
              -no-hardlinks -all-root -root-mode 0755 -noappend -no-xattrs \
              -comp zstd -Xcompression-level 19 -b 131072 -processors "$NIX_BUILD_CORES"
            wc -l < "$closureInfo/store-paths" > "$out/closure-size"
            # check: the DB lists exactly the closure, and the two things the kernel and the
            # daemon will look for exist where they look.
            n=$(sqlite3 state/db/db.sqlite 'select count(*) from ValidPaths')
            test "$n" = "$(cat "$out/closure-size")"
            # unsquashfs -ls lists every ancestor too: match the leaves, not a line count.
            db_profiles_ls=$(unsquashfs -ls "$out/store.squashfs" nix/var/nix/db/db.sqlite ${
              lib.concatMapStringsSep " " (core: "nix/var/nix/profiles/system-${core}") cores
            })
            echo "$db_profiles_ls" | grep -qx 'squashfs-root/nix/var/nix/db/db.sqlite'
            ${lib.concatMapStrings (core: ''
              echo "$db_profiles_ls" | grep -qx 'squashfs-root/nix/var/nix/profiles/system-${core}'
            '') cores}
            # mount points for a data card (the root is read-only): stage 0's and /boot-card
            for p in .lower-userdata boot-card nix/.lower-store/nix/store nix/.lower-store/nix/var; do
              unsquashfs -ls "$out/store.squashfs" "$p" | grep -qx "squashfs-root/$p"
            done
            # the lower-store state Nix's LocalStore ctor createDirs() even read-only (stage step 3)
            state_ls=$(unsquashfs -ls "$out/store.squashfs" nix/store/.links nix/var/nix/temproots nix/var/nix/gcroots/per-user nix/var/nix/profiles/per-user nix/var/nix/db/reserved)
            for p in nix/store/.links nix/var/nix/temproots nix/var/nix/gcroots/per-user nix/var/nix/profiles/per-user nix/var/nix/db/reserved; do
              echo "$state_ls" | grep -qx "squashfs-root/$p"
            done
            unsquashfs -ls "$out/store.squashfs" "nix/store/$(basename ${primary})" | grep -q "$(basename ${primary})"
            # the /init-<core> links (stage step 4) and the stage-0 each one names
            init_ls=$(unsquashfs -lls "$out/store.squashfs" ${
              lib.concatMapStringsSep " " (core: "init-${core}") cores
            })
            ${lib.concatStrings (
              lib.mapAttrsToList (core: stage0: ''
                echo "$init_ls" | grep -q ' squashfs-root/init-${core} -> ${stage0}/bin/nix-badge-stage0$'
              '') stage0s
            )}
            for t in ${toString (lib.attrValues stage0s)}; do
              unsquashfs -ls "$out/store.squashfs" "nix/store/$(basename $t)/bin/nix-badge-stage0" | grep -qx "squashfs-root/nix/store/$(basename $t)/bin/nix-badge-stage0"
            done

            # dm-verity, after the checks above. squashfs is 4K-padded, so with
            # --no-superblock the hash start is exactly data_blocks.
            data_bytes=$(stat -c %s "$out/store.squashfs")
            test $(( data_bytes % 4096 )) -eq 0 || { echo "squashfs not 4K-aligned" >&2; exit 1; }
            data_blocks=$(( data_bytes / 4096 ))
            salt=$(printf 'nixbadge-verity-1' | sha256sum | cut -c1-64)
            mv "$out/store.squashfs" "$out/store.img"
            veritysetup format --no-superblock --hash=sha256 --data-block-size=4096 --hash-block-size=4096 \
              --data-blocks=$data_blocks --hash-offset=$data_bytes --salt=$salt \
              --root-hash-file="$out/roothash" "$out/store.img" "$out/store.img" > verity.log
            roothash=$(cat "$out/roothash")
            veritysetup verify --no-superblock --hash=sha256 --data-block-size=4096 --hash-block-size=4096 \
              --data-blocks=$data_blocks --hash-offset=$data_bytes --salt=$salt "$out/store.img" "$out/store.img" "$roothash"

            # negative check: one flipped data byte (in a copy) must fail verification
            cp --reflink=auto "$out/store.img" ./corrupt.img
            chmod u+w ./corrupt.img
            printf '\377' | dd of=./corrupt.img bs=1 count=1 seek=0 conv=notrunc status=none
            if veritysetup verify --no-superblock --hash=sha256 --data-block-size=4096 --hash-block-size=4096 \
              --data-blocks=$data_blocks --hash-offset=$data_bytes --salt=$salt ./corrupt.img ./corrupt.img "$roothash" \
              > corrupt-verify.log 2>&1; then
              echo "veritysetup verify accepted a corrupted data block" >&2
              cat corrupt-verify.log >&2
              exit 1
            fi
            grep -q 'Verification of data area failed' corrupt-verify.log

            printf 'DATA_BLOCKS=%s\nHASH_START=%s\nROOTHASH=%s\nSALT=%s\n' "$data_blocks" "$data_blocks" "$roothash" "$salt" > "$out/verity.env"
            # One line, no newline; U-Boot expands ''${nixroot}. restart_on_corruption: a
            # corrupt block reboots into U-Boot's BOOT_x_LEFT fallback instead of EIO.
            printf 'dm-mod.create="nixroot,,0,ro,0 %s verity 1 PARTUUID=''${nixroot} PARTUUID=''${nixroot} 4096 4096 %s %s sha256 %s %s 1 restart_on_corruption"' \
              $(( data_blocks * 8 )) "$data_blocks" "$data_blocks" "$roothash" "$salt" > "$out/verity-append"
          '';

      # `setenv verityargs "<verity-append>"`: double quotes, so hush expands ${nixroot}
      # when it sources the script (single-quoted, it reaches the kernel unexpanded), and
      # no trailing newline (hush would return the empty last statement's status, 0).
      frag = runCommand "vbmeta-frag" { } ''
        mkdir $out
        printf 'setenv verityargs "%s"' "$(sed 's/"/\\"/g' ${image}/verity-append)" > $out/frag.txt
      '';

      # mkimage wants a /configurations node even for a script-only FIT. No `@` in node
      # names: the verifier refuses unit addresses.
      vbmeta = signFit {
        name = "vbmeta";
        inherit secure;
        cert = fitKeyCert;
        requireConfigurations = false;
        inputs = [ "${frag}/frag.txt" ];
        its = ''
          /dts-v1/;
          / {
            description = "nix-badge slot vbmeta";
            #address-cells = <1>;
            images {
              frag {
                description = "dm-verity kernel arguments of this slot's store image";
                data = /incbin/("frag.txt");
                type = "script";
                compression = "none";
                hash-1 { algo = "sha256"; };
                ${lib.optionalString secure ''
                  signature-1 {
                    algo = "sha256,rsa2048";
                    key-name-hint = "sg1-image-img";
                  };
                ''}
              };
            };
            configurations { };
          };
        '';
      };
    in
    assert lib.assertMsg (cores == lib.sort lib.lessThan (map coreOf systems)) ''
      make-store-squashfs: stage0s has ${toString cores}, but the systems are for
      ${toString (map coreOf systems)}.
    '';
    assert lib.assertMsg (versionMismatches == [ ]) ''
      make-store-squashfs: nix ${nix.version} writes the lower DB, but
      nix.package on ${
        lib.concatMapStringsSep ", " (
          s: "${s.config.nixpkgs.hostPlatform.system} (${s.config.nix.package.version})"
        ) versionMismatches
      } does not match it.
    '';
    # The image's files plus vbmeta.itb. store.img is a symlink: its consumers follow it.
    runCommand "sg2k-store-squashfs"
      {
        nativeBuildInputs = [ ubootTools ];
        passthru = {
          closureInfo = closure;
          inherit image vbmeta;
        };
      }
      ''
        mkdir $out
        ln -s ${image}/store.img $out/store.img
        cp ${image}/roothash ${image}/verity.env ${image}/verity-append ${image}/closure-size $out/
        cp ${vbmeta}/vbmeta.itb $out/vbmeta.itb
        # check: one script image named frag
        dumpimage -l $out/vbmeta.itb > vbmeta.list
        grep -qx ' Image 0 (frag)' vbmeta.list
        grep -q 'Type: *Script' vbmeta.list
      '';
in
lib.setFunctionArgs makeStoreSquashfs (lib.functionArgs makeStoreSquashfs)
// {
  # The /init-<core> links and the slot vbmeta of storeImage.
  passthru.tests.store-squashfs =
    { storeImage, stage0s }:
    callPackage ./test.nix {
      inherit storeImage stage0s;
      sandbox = sophgone.packages.${stdenv.buildPlatform.system}.uboot-sandbox;
    };
}
