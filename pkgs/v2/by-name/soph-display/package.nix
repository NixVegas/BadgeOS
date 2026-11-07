{
  lib,
  stdenv,
  fetchgit,
  kernel,
  soph-ion-uapi,
}:

# The Sophgo vendor display stack (Linux 5.10), built out of tree for the mainline kernel.
let
  src = fetchgit {
    url = "https://github.com/sophgo/osdrv.git";
    rev = "aa542c41df94f7bc656cb740f6622a5dca7dc403";
    hash = "sha256-wANIMD7INpp3VVI2jE3l9AUFsN7d4KafmfM6iyxiNcc=";
    sparseCheckout = [ "interdrv" ];
  };
in
stdenv.mkDerivation {
  pname = "soph-display";
  version = "5.10-vendor-on-${kernel.version}";
  inherit src;

  nativeBuildInputs = kernel.moduleBuildDependencies;

  # Behaviour fixes; the postPatch seds are mechanical 5.10 -> 7.x API rewrites.
  patches = [
    ./patches/cvi_vc_drv-vdec-join-event-handler-before-free.patch
    ./patches/mipi-tx-export-kernel-bringup.patch
    ./patches/scaler-disp-frame-start-poll.patch
    ./patches/scaler-disp-out-csc-matrix.patch
    ./patches/mipi-tx-board-display-fixes.patch
    ./patches/scaler-disp-set-layer.patch
    ./patches/vcodec-reset-on-probe.patch
    ./patches/scaler-dsi-set-eot.patch
  ];

  postPatch = ''
    # A grep below that matches nothing means the kernel already spells it the new way.
    set +o pipefail

    # -Werror is hopeless across 5.10 -> 7.x.
    find interdrv -name Makefile -exec \
      sed -i 's/-Werror/-Wno-error/g' {} +

    # Output CSC NONE zeroes OUT_CSC0 only, so the rest of the last-loaded matrix
    # still applies. Write the identity matrix instead.
    substituteInPlace interdrv/vpss/chip/cv181x/scaler.c \
      --replace-fail \
      '_reg_write(reg_base + REG_SCL_DISP_OUT_CSC0, 0);' \
      '{ struct sclr_csc_matrix *idn = &csc_mtrx[SCL_CSC_NONE]; _reg_write(reg_base + REG_SCL_DISP_OUT_CSC0, BIT(31) | (idn->coef[0][1] << 16) | (idn->coef[0][0])); _reg_write(reg_base + REG_SCL_DISP_OUT_CSC1, (idn->coef[1][0] << 16) | (idn->coef[0][2])); _reg_write(reg_base + REG_SCL_DISP_OUT_CSC2, (idn->coef[1][2] << 16) | (idn->coef[1][1])); _reg_write(reg_base + REG_SCL_DISP_OUT_CSC3, (idn->coef[2][1] << 16) | (idn->coef[2][0])); _reg_write(reg_base + REG_SCL_DISP_OUT_CSC4, (idn->coef[2][2])); _reg_write(reg_base + REG_SCL_DISP_OUT_CSC_SUB, (idn->sub[2] << 16) | (idn->sub[1] << 8) | idn->sub[0]); _reg_write(reg_base + REG_SCL_DISP_OUT_CSC_ADD, (idn->add[2] << 16) | (idn->add[1] << 8) | idn->add[0]); }'

    # ION left mainline in 5.11: a shim on the DMA API stands in for it.
    cp -r ${./compat} compat
    chmod -R u+w compat
    install -Dm444 ${soph-ion-uapi}/include/soph_ion.h compat/uapi/soph_ion.h

    # Our own modules (DISP feeder, KMS front end) go in before the loop below,
    # so they get the same compat flags as the vendor ones.
    cp -r ${./dispsrc} interdrv/dispsrc
    chmod -R u+w interdrv/dispsrc

    cp -r ${./sophdrm} interdrv/sophdrm
    chmod -R u+w interdrv/sophdrm
    for mk in interdrv/*/Makefile; do
      # Append: the Makefiles share no ccflags line to anchor on.
      echo "ccflags-y += -I$PWD/compat" >> "$mk"
      echo "KBUILD_EXTRA_SYMBOLS += $PWD/compat/Module.symvers" >> "$mk"
      # 7.2 dropped strncpy; strscpy is not a drop-in (no NUL padding).
      echo "ccflags-y += -include $PWD/compat/strncpy-compat.h" >> "$mk"
      echo "ccflags-y += -include $PWD/compat/gpio-compat.h" >> "$mk"
    done

    # cvi_vc_drv filp_open()s its microcode by absolute path, not request_firmware().
    substituteInPlace interdrv/cvi_vc_drv/vcodec/config.h \
      --replace-fail '"/usr/share/fw_vcodec/coda980.bin"' \
                     '"/run/current-system/firmware/fw_vcodec/coda980.bin"' \
      --replace-fail '"/usr/share/fw_vcodec/monet.bin"' \
                     '"/run/current-system/firmware/fw_vcodec/monet.bin"'

    # Compile the vcodec diagnostics in; vcodec_mask still gates them (default: errors only).
    echo "ccflags-y += -DVCODEC_DBG_MSG_ENABLE" >> interdrv/vcodec/Makefile

    # The shim only stubs the fd allocator, and in-kernel sys_ion_alloc() discards its
    # fd anyway: route it (and its free) to _nofd.
    sed -i 's|return _sys_ion_alloc(&dma_fd, p_paddr, pp_vaddr, buf_len, is_cached, buf_name);|return _sys_ion_alloc_nofd(p_paddr, pp_vaddr, buf_len, is_cached, buf_name);|' \
      interdrv/sys/common/sys.c

    sed -i 's|^\treturn _sys_ion_free(u64PhyAddr);|\treturn _sys_ion_free_nofd(u64PhyAddr);|' \
      interdrv/sys/common/sys.c
    # Two must match: sys_ion_free_nofd() already had one.
    n=$(grep -c 'return _sys_ion_free_nofd(u64PhyAddr);' interdrv/sys/common/sys.c)
    [ "$n" = 2 ] || { echo "ion free patch did not apply (found $n, want 2)"; exit 1; }

    # 5.10 -> 7.x API churn.
    # miscdevice.h and string.h no longer arrive transitively.
    sed -i '1i #include <linux/miscdevice.h>\n#include <linux/string.h>' \
      interdrv/sys/common/sys.c

    # base.c includes the OP-TEE private header but never uses it.
    sed -i '/#include "tee_cv_private.h"/d' interdrv/base/base.c

    # of_gpio.h was removed.
    grep -rl '#include <linux/of_gpio.h>' interdrv | xargs -r sed -i \
      's|#include <linux/of_gpio.h>|#include <linux/gpio/consumer.h>|'

    # from_timer() was renamed timer_container_of() in 6.16.
    grep -rl '\bfrom_timer(' interdrv | xargs -r sed -i \
      's|\bfrom_timer(|timer_container_of(|g'

    # DEFINE_SEMAPHORE() grew a count argument in 6.4.
    grep -rlE 'DEFINE_SEMAPHORE\([A-Za-z_][A-Za-z0-9_]*\)' interdrv | xargs -r sed -i -E \
      's|DEFINE_SEMAPHORE\(([A-Za-z_][A-Za-z0-9_]*)\)|DEFINE_SEMAPHORE(\1, 1)|g'

    # vmalloc.h no longer arrives transitively; add it wherever it is used.
    for f in $(grep -rlE '\b(vmalloc|vzalloc|vfree)\(' interdrv --include='*.c'); do
      grep -q '<linux/vmalloc.h>' "$f" || sed -i '1i #include <linux/vmalloc.h>' "$f"
    done

    # Same for platform_device.h.
    for f in $(grep -rlE '\bplatform_(device|driver|get_resource|get_irq|set_drvdata|get_drvdata|driver_register|driver_unregister)' interdrv --include='*.c'); do
      grep -q '<linux/platform_device.h>' "$f" || sed -i '1i #include <linux/platform_device.h>' "$f"
    done

    # del_timer_sync() was renamed timer_delete_sync() in 6.15.
    grep -rl '\bdel_timer_sync(' interdrv | xargs -r sed -i \
      's|\bdel_timer_sync(|timer_delete_sync(|g'
    grep -rl '\bdel_timer(' interdrv | xargs -r sed -i \
      's|\bdel_timer(|timer_delete(|g'

    # class_create() lost its owner argument in 6.4.
    grep -rl 'class_create(' interdrv | xargs -r sed -i \
      's|class_create(THIS_MODULE, *|class_create(|g'

    # security_task_getsecid() was split in 5.12; the secid is only vendor bookkeeping.
    sed -i 's|security_task_getsecid(current, \&ps->secid);|ps->secid = 0; /* was security_task_getsecid(); removed in 5.12 */|' \
      interdrv/base/base.c

    # platform_driver::remove returns void since 6.11 (names can contain digits).
    for f in $(grep -rl "_remove(struct platform_device \*pdev)" interdrv --include="*.c"); do
      fn=$(sed -n 's|^static int \([a-z0-9_]*_remove\)(struct platform_device \*pdev)$|\1|p' "$f")
      [ -z "$fn" ] && continue
      sed -i "s|^static int $fn(struct platform_device \*pdev)|static void $fn(struct platform_device *pdev)|" "$f"
      sed -i "/^static void $fn(struct platform_device/,/^}/ s|return -\?[A-Za-z0-9_]*;|return;|" "$f"
    done

    # arch_sync_dma_for_device() (riscv) and __dma_map_area (arm64) are not exported.
    grep -rlE 'arch_sync_dma_for_device|__dma_map_area' interdrv --include='*.c' | xargs -r sed -i -E \
      -e 's|arch_sync_dma_for_device\(([^,]+), *([^,]+), *DMA_FROM_DEVICE\);|soph_cache_invalidate_phys(\1, \2);|g' \
      -e 's|arch_sync_dma_for_device\(([^,]+), *([^,]+), *DMA_TO_DEVICE\);|soph_cache_flush_phys(\1, \2);|g' \
      -e 's|__dma_map_area\(phys_to_virt\(([^)]+)\), *([^,]+), *DMA_FROM_DEVICE\);|soph_cache_invalidate_phys(\1, \2);|g' \
      -e 's|__dma_map_area\(phys_to_virt\(([^)]+)\), *([^,]+), *DMA_TO_DEVICE\);|soph_cache_flush_phys(\1, \2);|g'

    # sched_setscheduler() is not exported; sched_set_fifo() takes no policy or priority.
    grep -rl 'sched_setscheduler' interdrv --include='*.c' | xargs -r sed -i -E \
      -e 's@ret = sched_setscheduler\(([^,]+), *SCHED_(FIFO|RR), *\&[A-Za-z_][A-Za-z0-9_]*\);@sched_set_fifo(\1); ret = 0;@' \
      -e 's@(^[[:space:]]*)sched_setscheduler\(([^,]+), *SCHED_(FIFO|RR), *\&[A-Za-z_][A-Za-z0-9_]*\);@\1sched_set_fifo(\2);@'

    # stdbool.h is not available to kernel builds (-nostdinc).
    grep -rl "include <stdbool.h>" interdrv | xargs -r sed -i "s|#include <stdbool.h>|#include <linux/types.h>|"

    # MAX_USER_RT_PRIO is gone; MAX_RT_PRIO is the surviving spelling.
    grep -rl MAX_USER_RT_PRIO interdrv | xargs -r sed -i "s|MAX_USER_RT_PRIO|MAX_RT_PRIO|g"

    # class_attribute show/store took const pointers from 6.4 onward.
    sed -i -e 's|(struct class \*class,|(const struct class *class,|g' -e 's|struct class_attribute \*attr|const struct class_attribute *attr|g' interdrv/base/base.c

    # dma-buf symbols moved into the DMA_BUF namespace; importing it is harmless where unused.
    for f in $(grep -rl 'MODULE_LICENSE(' interdrv --include='*.c'); do
      grep -q 'MODULE_IMPORT_NS' "$f" || \
        printf '\nMODULE_IMPORT_NS("DMA_BUF");\n' >> "$f"
    done

    # PDE_DATA() was renamed pde_data() in 5.17.
    grep -rl 'PDE_DATA' interdrv | xargs -r sed -i 's|\bPDE_DATA(|pde_data(|g'

    # UTS_VERSION is no longer exposed to modules; it is only a proc banner.
    grep -rl 'UTS_VERSION' interdrv | xargs -r sed -i \
      's|UTS_VERSION|"soph-display (vendor 5.10 forward-port)"|g'

    # cvi_vc_drv's soft-float library defines a do_div() that collides with the kernel
    # macro; rename it only in the file that defines it.
    for f in $(grep -rlE '^static [A-Za-z_][A-Za-z0-9_]* do_div *\(' interdrv --include='*.c' --include='*.h'); do
      sed -i 's|\bdo_div\b|cvi_sf_do_div|g' "$f"
    done

    # set_fs()/get_fs() are gone and the vendor's save/restore pairs are vestigial.
    # A real KERNEL_DS/USER_DS override must keep failing the build.
    if ! grep -rq 'KERNEL_DS\|USER_DS' interdrv --include='*.c' --include='*.h'; then
      grep -rlE 'mm_segment_t|[gs]et_fs *\(' interdrv --include='*.c' --include='*.h' | xargs -r sed -i -E \
        -e '/^[[:space:]]*mm_segment_t[[:space:]]+[A-Za-z_][A-Za-z0-9_]*;[[:space:]]*$/d' \
        -e '/^[[:space:]]*[A-Za-z_][A-Za-z0-9_>.-]*[[:space:]]*=[[:space:]]*get_fs\(\);[[:space:]]*$/d' \
        -e '/^[[:space:]]*set_fs\([^)]*\);[[:space:]]*$/d'
    fi

    # cif.c casts away a `link` arg it does not have, in an #if arm only mainline builds.
    grep -rl '(void)link;' interdrv | xargs -r sed -i '/^[[:space:]]*(void)link;$/d'

    # i2c_idx is a vendor-kernel extension; after i2c_get_adapter(i) it equals ->nr.
    grep -rl '\->i2c_idx' interdrv | xargs -r sed -i 's|->i2c_idx|->nr|g'

    # I2C_M_WRSTOP is the vendor spelling of I2C_M_STOP.
    grep -rl '\bI2C_M_WRSTOP\b' interdrv | xargs -r sed -i \
      's|\bI2C_M_WRSTOP\b|I2C_M_STOP|g'

    set -o pipefail
  '';

  buildPhase = ''
    runHook preBuild
    # The vendor's top Makefile exports these; we drive the sub-makes directly.
    export CVIARCH=CV181X CHIP_ARCH=CV181X
    export CVIARCH_L=cv181x CHIP_ARCH_L=cv181x
    export KERNEL_DIR=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build
    export ARCH=${stdenv.hostPlatform.linuxArch}
    export CROSS_COMPILE=${stdenv.cc.targetPrefix}

    echo "=== building compat (ION shim) ==="
    make -C compat ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE \
      KERNEL_DIR=$KERNEL_DIR PWD=$PWD/compat \
      2>&1 | tee "$TMPDIR/build-compat.log"
    if [ "''${PIPESTATUS[0]}" -ne 0 ]; then
      echo "ERROR: soph-display compat (the ION shim) failed to build" >&2
      exit 1
    fi

    # Each module reads the symbols of earlier ones from ../Module.symvers, which the
    # vendor's top Makefile would maintain. Order matters: vcodec before jpeg and cvi_vc_drv.
    : > interdrv/Module.symvers

    for m in sys base vpss vo dispsrc sophdrm rgn dwa vcodec jpeg ive tpu cvi_vc_drv vi cif snsr_i2c; do
      [ -d "interdrv/$m" ] || continue
      echo "=== building interdrv/$m ==="
      make -C interdrv/$m \
        ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE \
        KERNEL_DIR=$KERNEL_DIR PWD=$PWD/interdrv/$m \
        2>&1 | tee "$TMPDIR/build-$m.log"
      if [ "''${PIPESTATUS[0]}" -ne 0 ]; then
        echo "ERROR: soph-display module '$m' failed to build" >&2
        exit 1
      fi
      [ -f "interdrv/$m/Module.symvers" ] && \
        cat "interdrv/$m/Module.symvers" >> interdrv/Module.symvers
    done

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/modules/${kernel.modDirVersion}/extra $out/share
    find interdrv compat -name '*.ko' -exec install -Dm444 -t \
      $out/lib/modules/${kernel.modDirVersion}/extra {} \;
    # Scrub store paths from the logs, or the whole toolchain becomes a runtime reference.
    cp "$TMPDIR"/build-*.log $out/share/ 2>/dev/null || true
    sed -i "s|/nix/store/[a-z0-9]\\{32\\}-|/nix/store/<hash>-|g" $out/share/*.log || true
    runHook postInstall
  '';

  # A module can build clean yet produce no .ko.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    for ko in cv181x_sys cv181x_base cv181x_vpss cv181x_vo cv181x_mipi_tx soph_dispsrc soph_drm; do
      if [ ! -e "$out/lib/modules/${kernel.modDirVersion}/extra/$ko.ko" ]; then
        echo "ERROR: essential display module $ko.ko missing from output" >&2
        exit 1
      fi
    done
    runHook postInstallCheck
  '';

  meta = with lib; {
    description = "Sophgo CV181x/SG2000 vendor display drivers (sys/base/vpss/vo) on a mainline kernel";
    platforms = platforms.linux;
  };
}
