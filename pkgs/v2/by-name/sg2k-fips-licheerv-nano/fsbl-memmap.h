/*
 * cvi_board_memmap.h for the LicheeRV Nano (SG2002) FSBL: 256 MB DDR at 0x80000000.
 *
 * sophgone's Duo S map (pkgs/fsbl/duos-arm-memmap.h) with the DRAM size and the C906L
 * start moved for 256 MB; with the 512 MB values the FSBL panics in bl2_opt.c.
 *
 *   0x80000000  DRAM base / monitor (BL31 or OpenSBI) load and run address
 *   0x80080000  monitor FDT
 *   0x81800000  FSBL decompression buffer (16 MB)
 *   0x8FE00000  C906L firmware start (DRAM top - 2 MB)
 *   0x8FFFFFFF  DRAM top
 */

#ifndef __CVI_BOARD_MEMMAP_H__
#define __CVI_BOARD_MEMMAP_H__

#define CVIMMAP_DRAM_BASE           0x80000000UL
#define CVIMMAP_DRAM_SIZE           0x10000000UL  /* 256 MB */

#define CVIMMAP_MONITOR_ADDR        0x80000000UL

#define CVIMMAP_OPENSBI_FDT_ADDR    0x80080000UL

/* Must be > DECOMP_ALLOC_SIZE (1 MB); 16 MB gives 15 MB buf. */
#define CVIMMAP_FSBL_UNZIP_ADDR     0x81800000UL
#define CVIMMAP_FSBL_UNZIP_SIZE     0x01000000UL  /* 16 MB */

#define CVIMMAP_FSBL_C906L_START_ADDR  0x8FE00000UL

#endif /* __CVI_BOARD_MEMMAP_H__ */
