/*
 * cvi_board_memmap.h for the LicheeRV Nano (SG2002) U-Boot, both cores: 256 MB DDR at
 * 0x80000000.
 *
 * sophgone's Duo S maps (pkgs/uboot-arm and pkgs/uboot-riscv) for 256 MB. The
 * kernel window ends at the C906L window: the A53 U-Boot's dram_init takes its RAM, and
 * the /memory it gives Linux, from it, while the C906 U-Boot takes them from the control
 * DTB. Only code these builds leave out or never call reads the ION and boot-logo
 * values, so they get no carve-out: they sit on the C906L window with size 0.
 */

#ifndef __CVI_BOARD_MEMMAP_H__
#define __CVI_BOARD_MEMMAP_H__

#define CVIMMAP_DRAM_BASE              0x80000000UL
#define CVIMMAP_DRAM_SIZE              0x10000000UL  /* 256 MB */

#define CVIMMAP_OPENSBI_FDT_ADDR       0x80080000UL
#define CVIMMAP_OPENSBI_SIZE           0x80000UL

/* Everything below the C906L window. */
#define CVIMMAP_KERNEL_MEMORY_ADDR     0x80000000UL
#define CVIMMAP_KERNEL_MEMORY_SIZE     0x0FE00000UL

#define CVIMMAP_ION_ADDR               0x8FE00000UL
#define CVIMMAP_ION_SIZE               0x0UL

#define CVIMMAP_BOOTLOGO_ADDR          0x8FE00000UL
#define CVIMMAP_BOOTLOGO_SIZE          0x0UL

#define CVIMMAP_UIMAG_ADDR             0x81000000UL

/* UIMAG_ADDR + 16 MB scratch window */
#define CVIMMAP_CONFIG_SYS_INIT_SP_ADDR 0x82800000UL

#define CVIMMAP_FSBL_UNZIP_ADDR        0x81800000UL
#define CVIMMAP_FSBL_UNZIP_SIZE        0x01000000UL  /* 16 MB */

#define CVIMMAP_FSBL_C906L_START_ADDR  0x8FE00000UL

#endif /* __CVI_BOARD_MEMMAP_H__ */
