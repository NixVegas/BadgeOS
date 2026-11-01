// SPDX-License-Identifier: GPL-2.0
/*
 * lt8912b-bringup - a hand-loadable bring-up harness for HDMI out on the
 * Milk-V Duo S badge (Sophgo SG2000), mainline kernel.
 *
 * The badge routes the SG2000 MIPI-DSI lanes straight to a Lontium LT8912B
 * DSI->HDMI bridge. Mainline 7.2.x has DRM, DRM_MIPI_DSI and the in-tree
 * lontium-lt8912b bridge, but not the SG2000 side: the CVITEK DSI MAC, the
 * D-PHY, or the VO/scaler that feeds them. This module brings that SoC glue up
 * by hand against the running mainline kernel, running the exact vendor
 * (sophgo/osdrv) register sequence, D-PHY PLL+lanes, DSI MAC framing, VO/
 * scaler timing + test-pattern generator, to emit a 1280x720@60 DSI video
 * stream. The LT8912B itself is configured over I2C from userspace (the
 * recipe.sh lt_landscape sequence); this module drives only the SoC.
 *
 * It is a platform driver bound to the DT node `badge,sg2000-hdmi-bringup`.
 *
 * The ungate: the whole VIP/display region (scaler, DSI
 * MAC, D-PHY, VIP_SYS) boots with an FSBL-enabled clock that the mainline
 * clk framework kills at clk_disable_unused (late_initcall), after which any
 * MMIO access to the region deadlocks the AXI interconnect below the JTAG AP
 * (power-cycle only). Boot with `clk_ignore_unused` on the ARM cmdline and the
 * region stays alive. This module additionally holds the 15 functional VIP
 * clocks via its DT `clocks` (probe: clk_bulk_prepare_enable).
 *
 * Block map (sophgo/osdrv scaler_reg.h): scaler top 0x0A080000 (VO/DISP @
 * +0x8000, DSI MAC @ +0xA000); VIP_SYS 0x0A0C8000; D-PHY 0x0A0D1000.
 *
 * Bring-up flow (once loaded, VIP region live):
 *   echo 1 > /sys/kernel/debug/lt8912b_bringup/bringup   # SG2000 DSI colorbar
 *   <run recipe lt_landscape over i2c-2 to configure the LT8912B>
 *   check the HDMI capture for the 720p colorbar.
 * `pattern`, `io`, `vipinit`, `clocks`, `lt8912b` remain for live poking.
 */

#define pr_fmt(fmt) "lt8912b-bringup: " fmt

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/platform_device.h>
#include <linux/of.h>
#include <linux/clk.h>
#include <linux/io.h>
#include <linux/i2c.h>
#include <linux/debugfs.h>
#include <linux/delay.h>
#include <linux/fs.h>
#include <linux/kstrtox.h>
#include <linux/seq_file.h>
#include <linux/log2.h>
#include <linux/dma-mapping.h>
#include <linux/workqueue.h>
#include <linux/string.h>
#include <linux/miscdevice.h>

/* register map.
 * All scaler offsets are from the scaler-top base (0x0A080000): DISP block at
 * +0x8000, DSI MAC at +0xA000. (sophgo/osdrv scaler_reg.h) */
#define SCL_TOP_CFG0		0x0000u
#define SCL_TOP_CFG1		0x0004u
#define SCL_TOP_SHD		0x0010u
#define SCL_TOP_PG		0x004Cu
#define SCL_TOP_VO_MUX		0x0070u

#define SCL_DISP_BASE		0x8000u
#define SCL_DISP_CFG		(SCL_DISP_BASE + 0x00)
#define SCL_DISP_TOTAL		(SCL_DISP_BASE + 0x04)
#define SCL_DISP_VSYNC		(SCL_DISP_BASE + 0x08)
#define SCL_DISP_VFDE		(SCL_DISP_BASE + 0x0C)
#define SCL_DISP_VMDE		(SCL_DISP_BASE + 0x10)
#define SCL_DISP_HSYNC		(SCL_DISP_BASE + 0x14)
#define SCL_DISP_HFDE		(SCL_DISP_BASE + 0x18)
#define SCL_DISP_HMDE		(SCL_DISP_BASE + 0x1C)
#define SCL_DISP_FIFO_THR	(SCL_DISP_BASE + 0x30)
#define SCL_DISP_ADDR0_L	(SCL_DISP_BASE + 0x34)
#define SCL_DISP_ADDR0_H	(SCL_DISP_BASE + 0x38)
#define SCL_DISP_ADDR1_L	(SCL_DISP_BASE + 0x3C)
#define SCL_DISP_ADDR1_H	(SCL_DISP_BASE + 0x40)
#define SCL_DISP_ADDR2_L	(SCL_DISP_BASE + 0x44)
#define SCL_DISP_ADDR2_H	(SCL_DISP_BASE + 0x48)
#define SCL_DISP_PITCH_Y	(SCL_DISP_BASE + 0x4C)
#define SCL_DISP_PITCH_C	(SCL_DISP_BASE + 0x50)
#define SCL_DISP_OFFSET		(SCL_DISP_BASE + 0x54)
#define SCL_DISP_SIZE		(SCL_DISP_BASE + 0x58)
#define SCL_DISP_OUT_CSC0	(SCL_DISP_BASE + 0x5C)
#define SCL_DISP_IN_CSC0	(SCL_DISP_BASE + 0x78)
#define SCL_DISP_PAT_CFG	(SCL_DISP_BASE + 0x94)
#define SCL_DISP_CACHE		(SCL_DISP_BASE + 0xC0)
#define SCL_DISP_PAT_COLOR0	(SCL_DISP_BASE + 0x98)
#define SCL_DISP_PAT_COLOR1	(SCL_DISP_BASE + 0x9C)
#define SCL_DISP_PAT_COLOR2	(SCL_DISP_BASE + 0xA0)
#define SCL_DISP_PAT_COLOR3	(SCL_DISP_BASE + 0xA4)
#define SCL_DISP_PAT_COLOR4	(SCL_DISP_BASE + 0xA8)

#define SCL_DSI_BASE		0xA000u
#define SCL_DSI_MAC_EN		(SCL_DSI_BASE + 0x00)
#define SCL_DSI_HS_0		(SCL_DSI_BASE + 0x04)
#define SCL_DSI_HS_1		(SCL_DSI_BASE + 0x08)

/* D-PHY (0x0A0D1000), offsets from that base (scaler_reg.h REG_DSI_PHY_*) */
#define PHY_EN			0x00u
#define PHY_ESC_INIT		0x0Cu
#define PHY_ESC_WAKE		0x10u
#define PHY_HS_CFG1		0x14u	/* hs-settle: trail<<24|zero<<16|prepare<<8 */
#define PHY_DATA_OV		0x44u	/* LP-11 override on all pads */
#define PHY_LPTX_OV		0x4Cu
#define PHY_PD_TXDRV		0x50u
#define PHY_PD_EN_TX		0x54u
#define PHY_EN_SUBLVDS		0x5Cu
#define PHY_EN_TXBIAS_OP	0x60u
#define PHY_PD			0x64u
#define PHY_TXPLL		0x6Cu
#define PHY_REG_74		0x74u
#define PHY_VSEL		0x88u
#define PHY_REG_8C		0x8Cu
#define PHY_REG_SET		0x90u
#define PHY_LANE_SEL		0x9Cu
#define PHY_LANE_PN_SWAP	0xA0u
#define PHY_LVDS_EN		0xB4u
#define PHY_EXT_GPIO		0xC0u
#define PHY_GPO			0xC4u
#define PHY_GPI			0xC8u

/* VIP_SYS controller (0x0A0C8000): APB clock gates + per-block resets +
 * the AXI realtime-fabric priority patch. (reg_vip_sys.h / vip_common.h) */
#define VIP_RESETS		0x00u		/* active-high: 1 = in reset */
#define VIP_CLK_CTRL0		0x18u		/* dphy_dsi_set_pll bt_div bit4 */
#define VIP_APB_CLK_EN		0x14u
#define VIP_AXI_FAB_PRI		0x70u
/* display-path resets: img_d(2) img_v(3) sc_top(4) sc_d(5) sc_v1(6) sc_v2(7)
 * sc_v3(8) disp(9) dsi_mac(11) sc_top_apb(18) dsi_mac_apb(20) dsi_phy_apb(23)
 * dsi_phy(26) */
#define VIPRST_DISP	(BIT(2) | BIT(3) | BIT(4) | BIT(5) | BIT(6) | BIT(7) | \
			 BIT(8) | BIT(9) | BIT(11) | BIT(18) | BIT(20) | \
			 BIT(23) | BIT(26))
/* display APB clocks: sc_top(0) vip_sys(4) dsi_phy(6) */
#define VIPAPB_DISP	(BIT(0) | BIT(4) | BIT(6))

/* lane roles (dsi_phy.h enum lane_id) */
#define LANE_CLK	0
#define LANE_D0		1
#define LANE_D1		2
#define LANE_D2		3
#define LANE_D3		4
#define LANE_NONE	5	/* DSI_LANE_MAX = disabled */

/* sclr_dsi_mode */
#define DSI_MODE_IDLE	0
#define DSI_MODE_HS	4

/* sclr_disp_pat_type / _color (scaler.h) */
#define PAT_TYPE_FULL	0
#define PAT_TYPE_H_GRAD	1
#define PAT_TYPE_V_GRAD	2
#define PAT_TYPE_OFF	5
#define PAT_COLOR_WHITE	0
#define PAT_COLOR_BAR	7

/* 1280x720@60 landscape, RGB888, 4 data lanes (matches recipe lt_landscape
 *     + LT9611_1280x720_60HZ): htotal 1650, vtotal 750, pixclk 74.25 MHz. */
#define VID_HSA		40
#define VID_HBP		220
#define VID_HACT	1280
#define VID_HFP		110
#define VID_VSA		5
#define VID_VBP		20
#define VID_VACT	720
#define VID_VFP		5
#define VID_PIXCLK_KHZ	74250
#define VID_LANES	4
#define VID_BITS	24
/* physical-lane -> role, default recipe laneid=1,2,0,3,4 (clk on phys lane 2) */
/* PHY-lane -> role. 4-lane uses all; 2-lane drives only D0/D1 + CLK and marks
 * PHY lanes 3/4 role 7 (>DSI_LANE_MAX) so dphy_init powers their drivers down. */
#define LANE_OFF	7
static const u8 lane_map4[5] = { LANE_D0, LANE_D1, LANE_CLK, LANE_D2, LANE_D3 };
static const u8 lane_map2[5] = { LANE_D0, LANE_D1, LANE_CLK, LANE_OFF, LANE_OFF };
static int nlanes = 4;			/* active data-lane count (from `lanes`) */

#define UPPER(x, y)	(((x) + ((1 << (y)) - 1)) >> (y))
#ifndef MAXV
#define MAXV(a, b)	(((a) > (b)) ? (a) : (b))
#define MINV(a, b)	(((a) < (b)) ? (a) : (b))
#endif

static const u8 lt8912b_addrs[] = { 0x48, 0x49, 0x4a };

static int i2c_bus = 2;
module_param(i2c_bus, int, 0444);
MODULE_PARM_DESC(i2c_bus, "i2c bus the LT8912B hangs on (default 2 = 4020000.i2c)");

/* DISP_CFG bits 5:6 (VS_POL | HS_POL). 0 = what the working vendor-stack config
 * measured at (see disp_set_timing); 0x60 = the old always-set behaviour. */
static uint sync_pol;
module_param(sync_pol, uint, 0644);
MODULE_PARM_DESC(sync_pol, "DISP_CFG bits 5:6 VS_POL|HS_POL. 0 (default) = positive sync, the value that produced real pixels; 0x60 = both set, which makes the LT8912B sample blanking as active video and emit a uniform black at a valid lock.");

static bool disppll_fix_div = true;
module_param(disppll_fix_div, bool, 0644);
MODULE_PARM_DESC(disppll_fix_div, "pin the DISPPLL synthesizer divider (CLKGEN 0x03002860 bit6 fix_div + bit0 sw_up) so spread-spectrum stops wandering under the bridge's PCR; measured per-frame brightness spread 99.7 -> 10.4");

/* Diagnostic parameters (clock hunt). */
static uint clkgen_or = 0x3e;
module_param(clkgen_or, uint, 0644);
MODULE_PARM_DESC(clkgen_or, "bits OR-ed into CLKGEN 0x03002840 after the vendor (x & 0xf5) mask. Vendor writes 0x0a; 0x3e was my guess from the jpeg/cif drivers.");

static bool planar = true;
module_param(planar, bool, 0644);
MODULE_PARM_DESC(planar, "true: RGB_PLANAR (fmt=2, 3 planes, vendor disp default); false: RGB_PACKED (fmt=4)");

static bool use_fb = true;
module_param(use_fb, bool, 0644);
MODULE_PARM_DESC(use_fb, "true: DMA the colorbar framebuffer; false: internal pattern-gen (Debian-golden path, no scanout)");

static int pixclk_khz = VID_PIXCLK_KHZ;
module_param(pixclk_khz, int, 0644);
MODULE_PARM_DESC(pixclk_khz, "D-PHY PLL pixel-clock target in kHz (timing stays 720p); vary it to test whether the LT8912B DDS tracks the PLL");

static bool lp11 = true;
module_param(lp11, bool, 0644);
MODULE_PARM_DESC(lp11, "true: Nick's DATA_OV LP-11 handoff before HS; false: vendor-exact bare set_mode(HS)");

static uint hs0_or;
module_param(hs0_or, uint, 0644);
MODULE_PARM_DESC(hs0_or, "extra bits to OR into DSI HS_0 after the vendor 0xc3000000 write (bench dialect testing)");

static uint hs0_clr;
module_param(hs0_clr, uint, 0644);
MODULE_PARM_DESC(hs0_clr, "bits to CLEAR in DSI HS_0 after the vendor write (e.g. 0x04000000 = drop EoTp)");

static uint pn_swap;
module_param(pn_swap, uint, 0644);
MODULE_PARM_DESC(pn_swap, "per-PHY-lane DSI PN-swap bitmask, applied at dphy_set_lane time (bit i swaps PHY lane i's P/N). Diagnoses a board differential-pair reversal on a data lane -- classic 'bridge locks sync but pixels are black'. Default 0.");

static int lanes = 4;
module_param(lanes, int, 0644);
MODULE_PARM_DESC(lanes, "DSI data-lane count: 4 (D0-D3) or 2 (D0,D1 only -- routes around a suspect D2/D3 lane). MAC supports 1/2/4.");

static bool disp_src_off;	/* opt-in: empirically the disp does NOT source from disp-src */
module_param(disp_src_off, bool, 0644);
MODULE_PARM_DESC(disp_src_off, "true: after PLL setup, gate clk_disp_src (DISPPLL 148.5) so the disp tgen dot clock falls back to the D-PHY TXPLL tap (VIP_CLK_CTRL0 bit4) -- phase-locks pixel clock to the DSI byte clock (both share the TXPLL VCO), killing the FIFO drift.");

struct bringup {
	struct device *dev;
	void __iomem *scaler;		/* 0x0A080000 */
	void __iomem *phy;		/* 0x0A0D1000 */
	void __iomem *vipsys;		/* 0x0A0C8000 */
	struct clk_bulk_data *clks;
	int nclks;
	bool disp_src_gated;		/* clk_disp_src (DISPPLL) gated -> tgen on TXPLL tap */
	struct i2c_adapter *adap;
	struct dentry *dbg;
	void *fb_cpu;			/* colorbar framebuffer (dma_alloc_coherent) */
	dma_addr_t fb_dma;		/* its physical/bus addr (disp DMA source)   */
	size_t fb_size;
};

/* RGB_PACKED (sclr_format=4, "R lsb"): 3 bytes/pixel [R,G,B] */
#define VID_BPP		3
#define VID_PITCH	(VID_HACT * VID_BPP)
#define VID_FB_SIZE	(VID_PITCH * VID_VACT)
#define SCL_FMT_RGB_PACKED	4
#define SCL_FMT_RGB_PLANAR	2
/* RGB_PLANAR: 3 separate 8bpp planes (R,G,B), pitch = width each.
 * Vendor scaler.c:4488 sets the DISP default to SCL_FMT_RGB_PLANAR, packed RGB
 * may simply not be a supported disp scanout format on this silicon. */
#define VID_PLANE	(VID_HACT * VID_VACT)

static struct bringup *g;	/* single instance, for the debugfs callbacks */

/* Intended DISP_CFG, accumulated across disp_set_timing (pol), disp_set_scanout
 * (fmt) and disp_tgen_enable (tgen). We always write the whole word absolutely:
 * a masked RMW (scl_m) reads the *active* bank, so two RMWs to DISP_CFG (or to
 * PITCH_Y) in a row clobber each other's shadow write and the fmt/pitch never
 * land. Tracking the full value + scl_w side-steps that entirely. */
static u32 g_disp_cfg;

/* register access helpers (mirror vendor _reg_read/_write/_write_mask) */
static inline u32 scl_r(u32 o)			{ return readl(g->scaler + o); }
static inline void scl_w(u32 o, u32 v)		{ writel(v, g->scaler + o); }
static inline void scl_m(u32 o, u32 m, u32 v)	{ scl_w(o, (scl_r(o) & ~m) | (v & m)); }
static inline u32 phy_r(u32 o)			{ return readl(g->phy + o); }
static inline void phy_w(u32 o, u32 v)		{ writel(v, g->phy + o); }
static inline void phy_m(u32 o, u32 m, u32 v)	{ phy_w(o, (phy_r(o) & ~m) | (v & m)); }
static inline u32 vip_r(u32 o)			{ return readl(g->vipsys + o); }
static inline void vip_w(u32 o, u32 v)		{ writel(v, g->vipsys + o); }
static inline void vip_m(u32 o, u32 m, u32 v)	{ vip_w(o, (vip_r(o) & ~m) | (v & m)); }

/* ported vendor sequence */

/* VIP_SYS cold-init (base node's job on the vendor stack) */
static void vip_cold_init(void)
{
	u32 apb = vip_r(VIP_APB_CLK_EN);
	u32 rst = vip_r(VIP_RESETS);

	pr_info("VIP_SYS APB_CLK_EN=%#010x RESETS=%#010x (before)\n", apb, rst);
	vip_w(VIP_APB_CLK_EN, apb | VIPAPB_DISP);
	/* vip_toggle_reset(display blocks): assert then release */
	vip_w(VIP_RESETS, rst | VIPRST_DISP);
	udelay(20);
	vip_w(VIP_RESETS, rst & ~VIPRST_DISP);
	/* axi realtime-fabric priority (vip_axi_realtime_fab_priority) */
	vip_w(VIP_AXI_FAB_PRI, 0x1032AA0F);
	pr_info("VIP_SYS APB_CLK_EN=%#010x RESETS=%#010x FAB_PRI=%#010x (after)\n",
		vip_r(VIP_APB_CLK_EN), vip_r(VIP_RESETS), vip_r(VIP_AXI_FAB_PRI));
}

/* scaler top: raw-register mode + force-clk (from sclr_ctrl_init) */
static void scl_top_init(void)
{
	/* sclr_top_set_cfg(g_top_cfg): force_clk_enable, ip_trig_src; disp/sc
	 * disabled; sc_debug_en + qos_en. */
	scl_w(SCL_TOP_CFG0, (1u << 31) | (1u << 3));
	/* bit9 = disp_enable (sclr_top_set_cfg): the top-level VO/disp master enable.
	 * The vendor's live TOP_CFG1 reads 0x00FF1200, we were writing 0x00FF1000 and
	 * never setting bit9, so the disp was gated off at the top regardless of the
	 * disp block's own config. bit12 = sc_debug_en, [23:16] = qos_en. */
	scl_w(SCL_TOP_CFG1, (1u << 9) | (1u << 12) | (0xffu << 16));
	/* pull high threshold of urgent to avoid garbage */
	scl_w(SCL_DISP_FIFO_THR, 0x10201020);
	/* reg_shrd_sel (TOP_SHD bit9) = 1: raw register mode. The vendor
	 * sclr_ctrl_init() sets this here, disp/scaler writes then land directly
	 * in the active registers instead of a shadow bank that only promotes on
	 * frame-sync. Without it the disp config reads back correct (shadow ==
	 * working bank) yet the pixel datapath never starts: the disp output
	 * checksum data_out stays 0 and axi_read_from_dram stays 0 (no DRAM fetch,
	 * zero output) while the DSI MAC free-runs sync so the bridge still locks
	 * -> a locked-but-black screen. All our disp writes are absolute (scl_w),
	 * so raw mode is safe (the old "raw broke masked writes" note predated the
	 * absolute-write conversion). Set bit9 first, then force_up (masked, keeps
	 * bit9), matching the vendor order. */
	scl_w(SCL_TOP_SHD, 1u << 9);
	scl_m(SCL_TOP_CFG0, BIT(0), BIT(0));			/* reg_done */
	scl_m(SCL_TOP_SHD, 0x00ff, 0x00ff);			/* reg_force_up (keeps bit9) */
	scl_m(SCL_TOP_PG, 0x0f0000, 0x80000);			/* pg_late_clr */
}

/* sclr_top_reg_done + sclr_top_reg_force_up: commit shadow regs -> active. */
static void scl_promote(void)
{
	scl_m(SCL_TOP_CFG0, BIT(0), BIT(0));			/* reg_done */
	scl_m(SCL_TOP_SHD, 0x00ff, 0x00ff);			/* reg_force_up */
}

/* Commit the tracked disp CONFIG bits (fmt/pol/disp_from_sc/sync_ext = mask
 * 0xf071) then promote both double-buffers. The DISP block has its own
 * shadow/active pair (DISP_CFG bit16 SW_UP), separate from the top/SC pair
 * (scl_promote). Masked (scl_m) not whole-word: the vendor only ever RMWs
 * DISP_CFG, so this preserves the FSBL-set control bits (FORCE_CLK bit31,
 * SHRD_SEL bit18, and bits 8-11/19-30) that a whole-word write would zero.
 * tgen (bit7) is not here, it's a live bit set after the promote. */
static void disp_cfg_commit(void)
{
	scl_m(SCL_DISP_CFG, 0x0000f071u, g_disp_cfg);	/* cfg bits -> disp SHADOW, keep FSBL bits */
	scl_m(SCL_DISP_CFG, BIT(16), BIT(16));		/* DISP SW_UP: promote disp shadow -> ACTIVE */
	scl_promote();					/* TOP/SC domain reg_done + force_up */
}

/* D-PHY (dsi_phy.c) */
static void dphy_disable_lanes(void)
{
	phy_m(PHY_EN, 0x3f, 0);
	phy_m(PHY_LANE_SEL, 0xfffff, 0);
}

static void dphy_set_lane(u8 lane_num, u8 role, bool pn_swap, bool clk_phase_shift)
{
	phy_m(PHY_LANE_SEL, 0x7 << (4 * lane_num), role << (4 * lane_num));
	phy_m(PHY_LANE_PN_SWAP, BIT(lane_num), pn_swap << lane_num);
	if (role == LANE_CLK)
		phy_m(PHY_LANE_SEL, 0x1f << 24,
		      clk_phase_shift ? ((1u << 24) << lane_num) : 0);
}

static void dphy_lane_en(bool clk_en, const bool *data_en, bool preamble_en)
{
	u8 val = clk_en, i;

	for (i = 0; i < 4; ++i)
		val |= (data_en[i] << (i + 1));
	if (preamble_en)
		val |= 0x20;
	phy_m(PHY_EN, 0x3f, val);
}

/* _cal_pll_reg + dphy_dsi_set_pll, ported verbatim (PLL math). */
static void cal_pll_reg(u32 clkkHz, u32 VCORx10000, u32 *reg_txpll, u32 *reg_set, u32 factor)
{
	u8 gain = 1 << ilog2(MAXV(1, 25000000UL / VCORx10000));
	u32 VCOCx1000 = VCORx10000 * gain / 10;
	u8 reg_disp_div_sel = VCOCx1000 / clkkHz;
	u8 dig_dig = ilog2(gain);
	u8 reg_divout_sel = MINV(3, dig_dig);
	u8 reg_div_sel = dig_dig - reg_divout_sel;
	u32 loop_gainx1000 = VCOCx1000 / 133;
	bool bt_div = reg_disp_div_sel > 0x7f;
	u32 loop_c = 8 * ((loop_gainx1000 / 8) / 1000);
	u8 div_loop = loop_c > 32 ? 3 : loop_c / 8;
	u8 loop_gain1 = div_loop * 8;
	u64 modifies = (u64)(factor * loop_gain1) << 26;

	do_div(modifies, VCOCx1000);
	*reg_set = (u32)modifies;

	if (bt_div) {
		vip_m(VIP_CLK_CTRL0, 0x10, 0);
		reg_disp_div_sel >>= 1;
	} else {
		vip_m(VIP_CLK_CTRL0, 0x10, 0x10);
	}

	phy_m(PHY_TXPLL, 0x300000, div_loop << 20);
	*reg_txpll = (reg_div_sel << 10) | (reg_divout_sel << 8) | reg_disp_div_sel;

	pr_info("pll: clk=%ukHz VCOR=%u gain=%u disp_div=%u divout=%u div=%u set=%#x bt_div=%d\n",
		clkkHz, VCORx10000, gain, reg_disp_div_sel, reg_divout_sel,
		reg_div_sel, *reg_set, bt_div);
}

static void dphy_set_pll(u32 clkkHz, u8 lane, u8 bits)
{
	u32 VCORx10000 = clkkHz * bits * 10 / lane;
	u32 reg_txpll, reg_set;

	cal_pll_reg(clkkHz, VCORx10000, &reg_txpll, &reg_set, 900000);
	phy_m(PHY_TXPLL, 0x7ff, reg_txpll);
	phy_w(PHY_REG_SET, reg_set);
	/* update */
	phy_m(PHY_REG_8C, BIT(0), 0);
	phy_m(PHY_REG_8C, BIT(0), 1);
	pr_info("pll: TXPLL=%#010x REG_SET=%#010x\n", phy_r(PHY_TXPLL), phy_r(PHY_REG_SET));
}

/* dphy_init(SCLR_VO_INTF_MIPI): LP/HS power config from the lane roles. */
static void dphy_init_mipi(void)
{
	int lptrx = 0, lptx_rx = 0, hstx = 0, i;
	u32 lane_sel = phy_r(PHY_LANE_SEL);

	for (i = 0; i < 5; ++i) {
		if (((lane_sel >> (i * 4)) & 0x0F) > 4) {	/* unused lane */
			lptrx |= ((1 << i) | (1 << (8 + i)));
			lptx_rx |= ((1 << i) | (1 << (16 + i)));
			hstx |= ((1 << i) | (1 << (8 + i)) | (1 << (16 + i)) | (1 << (24 + i)));
		}
	}
	phy_w(PHY_PD, lptrx);			/* MIPI: lptrx (not 0x1f1f) */
	phy_w(PHY_LPTX_OV, lptx_rx);
	phy_w(PHY_PD_EN_TX, lptrx);
	phy_w(PHY_PD_TXDRV, hstx);
	phy_w(PHY_GPO, lptrx);
	phy_w(PHY_GPI, lptrx);
	phy_w(PHY_ESC_INIT, 0x100);
	phy_w(PHY_ESC_WAKE, 0x100);
	phy_w(PHY_EXT_GPIO, 0x0);		/* MIPI (not BT/I80) */
	phy_w(PHY_LVDS_EN, 0);
	phy_m(PHY_EN_TXBIAS_OP, 0x10000, 0);
	phy_m(PHY_EN_SUBLVDS, 0x1F000000, 0);
	phy_m(PHY_VSEL, 0xFFFFF, 0);
	phy_m(PHY_REG_74, 0x3ff, 0);		/* dphy_dsi_analog_setting(false) */
}

/* sclr_disp_set_intf(SCLR_VO_INTF_MIPI) */
static void disp_set_intf_mipi(void)
{
	void __iomem *pll_reg = ioremap(0x03002840, 4);

	if (pll_reg) {
		u32 pll = ioread32(pll_reg) & 0xf5;

		iowrite32(pll | clkgen_or, pll_reg);
		iounmap(pll_reg);
	}
	/* Pin the DISPPLL synthesizer divider before the D-PHY comes up:
	 * reg_disppll_ssc_syn_fix_div (bit6) then sw_up (bit0, W1T). Left
	 * unpinned the spread-spectrum synthesizer wanders and the LT8912B's
	 * pixel-clock recovery chases it, measured per-frame brightness
	 * spread 99.7 -> 10.4 on the vendor stack. disppll_ssc_syn_set
	 * (0x03002864) reads 0x245D1746 = 9.090907 in 6.26 fixed point,
	 * i.e. 675 MHz / 9.0909091 = 74.25 MHz exactly, so only the
	 * modulation needs stopping, not the divide value. */
	if (disppll_fix_div) {
		void __iomem *syn = ioremap(0x03002860, 4);

		if (syn) {
			iowrite32(BIT(6), syn);
			iowrite32(BIT(6) | BIT(0), syn);
			iounmap(syn);
		}
	}
	dphy_init_mipi();
	scl_m(SCL_TOP_VO_MUX, 0xF, 0);			/* sclr_disp_mux_sel(DISABLE) */
}

/* sclr_dsi_config(lane_num=4, fmt=RGB888, width=1280) */
static void dsi_config(void)
{
	u8 bit_depth[] = { 24, 18, 16, 30 };
	u8 fmt = 0;		/* SCLR_DSI_FMT_RGB888 */
	u16 width = VID_HACT;
	u32 val;

	/* vendor-exact sclr_dsi_config: write only fmt(31:30) + lane(25:24) under
	 * mask 0xc3000000, preserving bits 29:26 at their reset default. Those bits
	 * are the DSI video-mode/blanking controls (continuous-clock, EoTp, and the
	 * HSA/HBP/HFP sync-enable bits) that the vendor never rewrites, an earlier
	 * rev widened the mask to 0xff000000 to clear "EoTp", which also wiped the
	 * blanking-enable bits and left the bridge unable to see H/V. `hs0_or` lets
	 * us bench-test forcing specific bits without a rebuild. */
	u32 pre = scl_r(SCL_DSI_HS_0);

	val = (fmt << 30) | ((nlanes >> 1) << 24);
	scl_m(SCL_DSI_HS_0, 0xc3000000, val);
	if (hs0_or)
		scl_m(SCL_DSI_HS_0, hs0_or, hs0_or);
	if (hs0_clr)
		scl_m(SCL_DSI_HS_0, hs0_clr, 0);
	val = (width / 10) << 16 | UPPER(width * bit_depth[fmt], 3);
	scl_w(SCL_DSI_HS_1, val);
	pr_info("dsi_config: HS_0 reset=%#010x -> %#010x HS_1=%#010x (hs0_or=%#x clr=%#x)\n",
		pre, scl_r(SCL_DSI_HS_0), scl_r(SCL_DSI_HS_1), hs0_or, hs0_clr);
}

/* _fill_disp_timing + sclr_disp_set_timing */
static void disp_set_timing(void)
{
	u16 vtotal = VID_VSA + VID_VBP + VID_VACT + VID_VFP - 1;
	u16 htotal = VID_HSA + VID_HBP + VID_HACT + VID_HFP - 1;
	u16 vsync_start = 1, vsync_end = vsync_start + VID_VSA - 1;
	u16 vde_start = vsync_start + VID_VSA + VID_VBP;
	u16 vde_end = vde_start + VID_VACT - 1;
	u16 hsync_start = 1, hsync_end = hsync_start + VID_HSA - 1;
	u16 hde_start = hsync_start + VID_HSA + VID_HBP;
	u16 hde_end = hde_start + VID_HACT - 1;

	scl_w(SCL_DISP_TOTAL, (htotal << 16) | vtotal);
	scl_w(SCL_DISP_VSYNC, (vsync_end << 16) | vsync_start);
	scl_w(SCL_DISP_VFDE,  (vde_end << 16) | vde_start);
	scl_w(SCL_DISP_VMDE,  (vde_end << 16) | vde_start);
	scl_w(SCL_DISP_HSYNC, (hsync_end << 16) | hsync_start);
	scl_w(SCL_DISP_HFDE,  (hde_end << 16) | hde_start);
	scl_w(SCL_DISP_HMDE,  (hde_end << 16) | hde_start);
	/* DISP_CFG bits 5:6 = VS_POL|HS_POL. Measured on the vendor stack: setting
	 * them makes the LT8912B sample the blanking interval as active video, so
	 * the sink locks a valid 720p60 and shows a perfectly uniform black. 720p60
	 * is positive-sync and the bridge is programmed positive (0x48:0xab=0x03).
	 * Clearing both is what produced the first real pixels. Param so the other
	 * polarity is reachable without a rebuild. */
	g_disp_cfg = (g_disp_cfg & ~0x0060u) | (sync_pol & 0x60u);
	disp_cfg_commit();
	pr_info("timing: htotal=%u vtotal=%u hde=%u..%u vde=%u..%u\n",
		htotal, vtotal, hde_start, hde_end, vde_start, vde_end);
}

/* sclr_disp_tgen_enable */
static void disp_tgen_enable(bool en)
{
	/* tgen is a live control bit (DISP_CFG bit7): the masked write takes effect
	 * immediately and the vendor never promotes after it, a SW_UP here would
	 * re-load the shadow bank underneath a just-started timing generator. */
	scl_m(SCL_DISP_CFG, 0x80u, en ? 0x80u : 0u);
}

/* sclr_disp_set_pattern(type, color, NULL) for the full/gradient families */
static void disp_set_pattern(u8 type, u8 color)
{
	if (type > PAT_TYPE_V_GRAD) {			/* OFF */
		scl_w(SCL_DISP_PAT_CFG, 0);
		scl_promote();
		return;
	}
	/* Absolute writes (the shadowed PAT_CFG never promoted via scl_m RMW, so the
	 * color/type never landed, same bug scanout had). */
	/* The pattern path never ran disp_set_scanout, so OFFSET/SIZE stayed 0, a
	 * 0x0 display window, i.e. nothing to rasterise no matter how the pattern
	 * generator is configured. Set the window here too. */
	scl_w(SCL_DISP_OFFSET, 0);
	scl_w(SCL_DISP_SIZE, ((VID_VACT - 1) << 16) | (VID_HACT - 1));	/* HEIGHT high, width low; vendor sclr_disp_set_mem order */
	scl_w(SCL_DISP_PAT_COLOR0, 0x03ff03ff);
	scl_m(SCL_DISP_PAT_COLOR1, 0x000003ff, 0x3ff);
	/* PAT_CFG field map (reg_disp.h): bit0 GRA_INV, bit1 PAT_EN, bit2 AUTO_EN,
	 * bit3 DITH_EN, bit4 SNOW_EN, [23:16] PAT_PRD, [28:24] PAT_IDX. The enable
	 * is bit1, an earlier rev set bit3 (that is the dither enable), so the
	 * pattern generator was never actually running and the disp emitted a
	 * blank active area at a perfectly valid 720p60 sync. Vendor
	 * sclr_disp_set_pattern writes exactly (type << 27) | (color << 24) | 0x2
	 * under mask 0x1f000016. */
	scl_m(SCL_DISP_PAT_CFG, 0x1f000016,
	      ((u32)type << 27) | ((u32)color << 24) | 0x0002);
	disp_cfg_commit();			/* tgen (bit7) is enabled separately + live in do_bringup */
	pr_info("pattern: type=%u color=%u PAT_CFG=%#010x DISP_CFG=%#010x\n",
		type, color, scl_r(SCL_DISP_PAT_CFG), scl_r(SCL_DISP_CFG));
}

/* dphy_set_hs_settle(prepare, zero, trail) -> HS_CFG1 (LT9611 uses {6,32,5}) */
static void dphy_set_hs_settle(u8 prepare, u8 zero, u8 trail)
{
	phy_m(PHY_HS_CFG1, 0xffffff00, (trail << 24) | (zero << 16) | (prepare << 8));
}

/* Full disp DMA scanout of the framebuffer (sclr_disp_set_cfg + set_mem +
 * set_addr, disp_from_sc=0). The disp block is shadow-registered: writes land
 * in a shadow bank and only reach the active registers on a frame-sync or a
 * force_up, and only while DISP_CFG bit17 (shadow-mask) is clear. The vendor
 * freezes bit17, writes the whole group, then unfreezes + force_ups so it
 * promotes atomically, that is what we replicate here. Running the scaler in
 * TOP_SHD-bit9 "raw mode" and writing these raw silently drops the masked
 * fmt/PITCH writes; the vendor never sets bit9, so the shadow path below is the
 * correct one.
 * `fb` = physical/bus addr of the RGB_PACKED framebuffer. */
static void disp_set_scanout(dma_addr_t fb)
{
	/* All scanout regs written absolutely (scl_w) so a later RMW can't read a
	 * stale active bank and clobber them. PITCH_Y = burst[31:28] | pitch[23:0]
	 * in one write (two scl_m's clobbered each other before). */
	scl_w(SCL_DISP_OFFSET, 0);				/* start_x/y = 0     */
	scl_w(SCL_DISP_SIZE, ((VID_VACT - 1) << 16) | (VID_HACT - 1));	/* HEIGHT high, width low; vendor sclr_disp_set_mem order */
	/* burst[31:28]=7 (128B, vendor SCL_DEFAULT_BURST) | OS_MAX[27:24]=0xf (AXI
	 * outstanding reads; my old absolute write forced this to 0, and 0 outstanding
	 * = the disp DMA never issues its burst) | pitch[23:0]. */
	if (planar) {
		dma_addr_t p1 = fb + VID_PLANE, p2 = fb + 2 * VID_PLANE;

		scl_w(SCL_DISP_PITCH_Y, (0x7u << 28) | (0x7u << 24) | VID_HACT);
		scl_w(SCL_DISP_PITCH_C, (0x7u << 28) | (0x7u << 24) | VID_HACT);
		scl_w(SCL_DISP_ADDR0_L, lower_32_bits(fb));
		scl_w(SCL_DISP_ADDR0_H, upper_32_bits(fb));
		scl_w(SCL_DISP_ADDR1_L, lower_32_bits(p1));
		scl_w(SCL_DISP_ADDR1_H, upper_32_bits(p1));
		scl_w(SCL_DISP_ADDR2_L, lower_32_bits(p2));
		scl_w(SCL_DISP_ADDR2_H, upper_32_bits(p2));
	} else {
		scl_w(SCL_DISP_PITCH_Y, (0x7u << 28) | (0x7u << 24) | (VID_PITCH & 0x00ffffff));
		scl_w(SCL_DISP_PITCH_C, 0);			/* packed: no chroma */
		scl_w(SCL_DISP_ADDR0_L, lower_32_bits(fb));
		scl_w(SCL_DISP_ADDR0_H, upper_32_bits(fb));
		scl_w(SCL_DISP_ADDR1_L, 0);
		scl_w(SCL_DISP_ADDR1_H, 0);
		scl_w(SCL_DISP_ADDR2_L, 0);
		scl_w(SCL_DISP_ADDR2_H, 0);
	}
	scl_w(SCL_DISP_IN_CSC0, 0);				/* in_csc  = NONE    */
	scl_w(SCL_DISP_OUT_CSC0, 0);				/* out_csc = NONE (RGB passthrough) */
	/* Vendor does a masked write (_reg_write_mask(.., BIT(0), cache_mode)) which
	 * preserves bits 1-2; my absolute write clobbered them (live 0x7 -> 0x1). */
	scl_m(SCL_DISP_CACHE, BIT(0), BIT(0));			/* cache_mode = 1, keep bits 1-2 */
	scl_w(SCL_DISP_PAT_COLOR4, 6u << 16);			/* out_bit: vendor live value is 6<<16, not 2<<16 */
	/* fmt into the tracked cfg; disp_from_sc(0), sync_ext(0). tgen(7) added by
	 * disp_tgen_enable, pol(5:6) by disp_set_timing, all in g_disp_cfg. */
	g_disp_cfg = (g_disp_cfg & ~0x0000f011u) |
		((planar ? SCL_FMT_RGB_PLANAR : SCL_FMT_RGB_PACKED) << 12);
	disp_cfg_commit();
	pr_info("scanout: fb=%pad DISP_CFG=%#010x PITCH=%#010x SIZE=%#010x\n",
		&fb, scl_r(SCL_DISP_CFG), scl_r(SCL_DISP_PITCH_Y), scl_r(SCL_DISP_SIZE));
}

/* Fill the framebuffer with 8 vertical colour bars (RGB_PACKED, R lsb). */
static void fill_colorbar(u8 *fb)
{
	static const u8 bars[8][3] = {		/* R, G, B */
		{255,255,255}, {255,255,0}, {0,255,255}, {0,255,0},
		{255,0,255},   {255,0,0},   {0,0,255},   {0,0,0},
	};
	unsigned int x, y;

	for (y = 0; y < VID_VACT; y++) {
		u8 *row = fb + (size_t)y * VID_PITCH;
		u8 *r = fb + (size_t)y * VID_HACT;

		for (x = 0; x < VID_HACT; x++) {
			const u8 *c = bars[x * 8 / VID_HACT];

			if (planar) {
				r[x] = c[0];
				r[x + VID_PLANE] = c[1];
				r[x + 2 * VID_PLANE] = c[2];
			} else {
				row[x * 3 + 0] = c[0];
				row[x * 3 + 1] = c[1];
				row[x * 3 + 2] = c[2];
			}
		}
	}
}

/* Scroller demo: animated text rendered straight into the disp's
 * RGB_PLANAR scanout buffer. Independent of whether the SoC pixel
 * output stage is working; `fbcheck` verifies the render by counting
 * lit pixels, so the demo can be validated with no display attached. */
#define SCROLL_SCALE	8			/* 8x8 font -> 64px tall	*/
#define SCROLL_H	(8 * SCROLL_SCALE)
#define SCROLL_ADV	(8 * SCROLL_SCALE)	/* advance per character	*/
#define SCROLL_STEP	6			/* px per frame			*/
#define SCROLL_MS	33			/* ~30 fps			*/

static const u8 font8[][8] = {
	/* ' ' */ { 0,0,0,0,0,0,0,0 },
	/* '!' */ { 0x18,0x18,0x18,0x18,0x18,0x00,0x18,0x00 },
	/* 'I' */ { 0x3C,0x18,0x18,0x18,0x18,0x18,0x3C,0x00 },
	/* 'L' */ { 0x60,0x60,0x60,0x60,0x60,0x60,0x7E,0x00 },
	/* 'T' */ { 0x7E,0x18,0x18,0x18,0x18,0x18,0x18,0x00 },
};
static const char font_chars[] = " !ILT";
static const char scroll_msg[] = "IT LIT! ";

static const u8 *glyph_of(char c)
{
	const char *p = strchr(font_chars, c);

	return font8[p ? (unsigned int)(p - font_chars) : 0];
}

/* Render one frame at horizontal offset @xoff into the planar buffer. */
static void scroll_render(u8 *fb, unsigned int xoff)
{
	const unsigned int len = sizeof(scroll_msg) - 1;
	const unsigned int total = len * SCROLL_ADV;
	u8 *r = fb, *g_ = fb + VID_PLANE, *b = fb + 2 * VID_PLANE;
	unsigned int y0 = (VID_VACT - SCROLL_H) / 2;
	unsigned int x, y;

	memset(fb, 0, VID_FB_SIZE);
	for (y = 0; y < SCROLL_H; y++) {
		unsigned int gy = y / SCROLL_SCALE;
		size_t row = (size_t)(y0 + y) * VID_HACT;

		for (x = 0; x < VID_HACT; x++) {
			unsigned int sx = (x + xoff) % total;
			const u8 *gl = glyph_of(scroll_msg[sx / SCROLL_ADV]);
			unsigned int gx = (sx % SCROLL_ADV) / SCROLL_SCALE;

			if (!(gl[gy] & (0x80u >> gx)))
				continue;
			r[row + x] = 0xff;
			g_[row + x] = (u8)(x * 255u / VID_HACT);
			b[row + x] = (u8)(255u - x * 255u / VID_HACT);
		}
	}
}

static void scroll_fn(struct work_struct *w);
static DECLARE_DELAYED_WORK(scroll_work, scroll_fn);
static unsigned int scroll_x;
static bool scroll_on;

static void scroll_fn(struct work_struct *w)
{
	if (!scroll_on || !g || !g->fb_cpu)
		return;
	scroll_render(g->fb_cpu, scroll_x);
	scroll_x += SCROLL_STEP;
	schedule_delayed_work(&scroll_work, msecs_to_jiffies(SCROLL_MS));
}

static ssize_t scroll_write(struct file *f, const char __user *ubuf,
			    size_t len, loff_t *ppos)
{
	int v, ret;

	ret = kstrtoint_from_user(ubuf, len, 0, &v);
	if (ret)
		return ret;
	if (!g || !g->fb_cpu)
		return -ENODEV;
	if (v) {
		scroll_on = true;
		schedule_delayed_work(&scroll_work, 0);
		pr_info("scroll: started (\"%s\", %dpx/frame, ~%dfps)\n",
			scroll_msg, SCROLL_STEP, 1000 / SCROLL_MS);
	} else {
		scroll_on = false;
		cancel_delayed_work_sync(&scroll_work);
		pr_info("scroll: stopped at x=%u\n", scroll_x);
	}
	return len;
}

static const struct file_operations scroll_fops = {
	.owner = THIS_MODULE, .write = scroll_write, .llseek = noop_llseek,
};

/* `echo <r> [g] [b] > fbfill`: paint the whole framebuffer one flat colour.
 * Solid white is by far the most detectable thing a sink can show, so this is
 * the pixel-path oracle: if white does not appear, no pixel ever will. One arg
 * fills all three channels. Stops the scroller first so it cannot repaint. */
static ssize_t fbfill_write(struct file *f, const char __user *ubuf,
			    size_t len, loff_t *ppos)
{
	char buf[32];
	int r = 255, gg = -1, b = -1, n;

	if (!g || !g->fb_cpu)
		return -ENODEV;
	if (len >= sizeof(buf))
		return -EINVAL;
	if (copy_from_user(buf, ubuf, len))
		return -EFAULT;
	buf[len] = '\0';
	n = sscanf(buf, "%d %d %d", &r, &gg, &b);
	if (n < 1)
		return -EINVAL;
	if (n < 3) {
		gg = r;
		b = r;
	}
	scroll_on = false;
	cancel_delayed_work_sync(&scroll_work);
	if (planar) {
		memset(g->fb_cpu, r & 0xff, VID_PLANE);
		memset(g->fb_cpu + VID_PLANE, gg & 0xff, VID_PLANE);
		memset(g->fb_cpu + 2 * VID_PLANE, b & 0xff, VID_PLANE);
	} else {
		u8 *p = g->fb_cpu;
		size_t i;

		for (i = 0; i < VID_PLANE; i++) {
			*p++ = r & 0xff;
			*p++ = gg & 0xff;
			*p++ = b & 0xff;
		}
	}
	pr_info("fbfill: r=%d g=%d b=%d planar=%d\n", r, gg, b, planar);
	return len;
}

/* fbmap: hand the scanout buffer to userspace so a demo can render straight
 * into it. dma_alloc_coherent memory, so dma_mmap_coherent keeps the
 * cacheability attributes right, plain remap_pfn_range would not. The
 * kernel-side scroller is stopped on open: two writers, one buffer. */
static int fbmap_mmap(struct file *f, struct vm_area_struct *vma)
{
	size_t len = vma->vm_end - vma->vm_start;
	int ret;

	if (!g || !g->fb_cpu)
		return -ENODEV;
	if (vma->vm_pgoff || len > g->fb_size)
		return -EINVAL;

	scroll_on = false;
	cancel_delayed_work_sync(&scroll_work);

	ret = dma_mmap_coherent(g->dev, vma, g->fb_cpu, g->fb_dma, len);
	if (!ret)
		return 0;

	/* Some configurations refuse the coherent helper. The buffer is uncached
	 * DMA memory at a known physical address, so map it write-combined by
	 * hand instead, which is what we want for a framebuffer the CPU only
	 * writes and the disp DMA only reads. */
	pr_info("fbmap: dma_mmap_coherent -> %d, falling back to remap_pfn_range\n",
		ret);
	vma->vm_page_prot = pgprot_writecombine(vma->vm_page_prot);
	return remap_pfn_range(vma, vma->vm_start,
			       (unsigned long)g->fb_dma >> PAGE_SHIFT,
			       len, vma->vm_page_prot);
}

static int fbmap_open(struct inode *i, struct file *f)
{
	if (!g || !g->fb_cpu)
		return -ENODEV;
	pr_info("fbmap: scanout handed to userspace (%zu bytes @ %pad)\n",
		g->fb_size, &g->fb_dma);
	return 0;
}

static const struct file_operations fbmap_fops = {
	.owner = THIS_MODULE,
	.open  = fbmap_open,
	.mmap  = fbmap_mmap,
};

static struct miscdevice fbmap_misc = {
	.minor = MISC_DYNAMIC_MINOR,
	.name  = "badgefb",
	.fops  = &fbmap_fops,
	.mode  = 0600,
};

static const struct file_operations fbfill_fops = {
	.owner = THIS_MODULE, .write = fbfill_write, .llseek = noop_llseek,
};

/* Verify the render without a display: count lit pixels per plane. */

/* Read the live iic2 pad-conf registers (RTC domain). The LT8912B ACKs fine under
 * mainline, so these are known-good values, the reference for the vendor-Debian
 * i2c2 wall, where the chip never ACKs. See badge-debian-vendor-vo-transplant. */
static ssize_t padw_write(struct file *f, const char __user *ubuf,
			  size_t len, loff_t *ppos)
{
	void __iomem *p;
	int v, ret;

	ret = kstrtoint_from_user(ubuf, len, 0, &v);
	if (ret)
		return ret;
	p = ioremap(0x05027040, 8);
	if (!p)
		return -ENOMEM;
	iowrite32(v, p);
	iowrite32(v, p + 4);
	iounmap(p);
	pr_info("padw: iic2 SCL+SDA pad conf <- %#x\n", v);
	return len;
}


/* GPIO bit-banged I2C on the IIC2 pads (plan-B enabler).
 * The vendor-Debian transplant is walled on the LT8912B never ACKing through
 * the DesignWare i2c2 controller, with the cause unexplained (pad conf, mux,
 * controller regs and speed all matched a working system). This bypasses the
 * controller entirely: retarget the two pads to PWR_GPIO (funcsel 3) and drive
 * the bus by hand, so SDA is exercised on a completely different path. The
 * register sequence here is deliberately plain reads/writes of three addresses
 * so it transcribes directly into a `devmem` script for Debian, where /dev/mem
 * is available and this module is not.
 *
 *   pad mux : 0x030010b8 (IIC2_SCL) / 0x030010bc (IIC2_SDA); 0 = IIC2, 3 = GPIO
 *   PWR_GPIO: 0x05021000 DR(+0x00) DDR(+0x04) EXT_PORTA(+0x50); SCL=bit0 SDA=bit1
 * Open-drain is emulated the usual way: drive low = DDR out + DR 0; release =
 * DDR in and let the external pull-up do it.
 */
#define PWRGPIO_BASE	0x05021000u
#define PWRGPIO_DR	0x00u
#define PWRGPIO_DDR	0x04u
#define PWRGPIO_EXT	0x50u
#define MUX_IIC2_BASE	0x030010b8u

struct bb { void __iomem *gpio, *mux; };

static void bb_low(struct bb *b, u32 pin)	/* pull the line down */
{
	iowrite32(ioread32(b->gpio + PWRGPIO_DR) & ~pin, b->gpio + PWRGPIO_DR);
	iowrite32(ioread32(b->gpio + PWRGPIO_DDR) | pin, b->gpio + PWRGPIO_DDR);
	udelay(5);
}

static void bb_rel(struct bb *b, u32 pin)	/* release: input, pull-up wins */
{
	iowrite32(ioread32(b->gpio + PWRGPIO_DDR) & ~pin, b->gpio + PWRGPIO_DDR);
	udelay(5);
}

static int bb_get(struct bb *b, u32 pin)
{
	return !!(ioread32(b->gpio + PWRGPIO_EXT) & pin);
}

static void bb_start(struct bb *b, u32 SCL, u32 SDA)
{
	bb_rel(b, SDA); bb_rel(b, SCL);
	bb_low(b, SDA); bb_low(b, SCL);
}

static void bb_stop(struct bb *b, u32 SCL, u32 SDA)
{
	bb_low(b, SDA); bb_rel(b, SCL); bb_rel(b, SDA);
}

static int bb_wr(struct bb *b, u32 SCL, u32 SDA, u8 v)		/* returns 0 on ACK */
{
	int i, ack;

	for (i = 7; i >= 0; i--) {
		if (v & BIT(i)) bb_rel(b, SDA); else bb_low(b, SDA);
		bb_rel(b, SCL); bb_low(b, SCL);
	}
	bb_rel(b, SDA);			/* release for the ACK bit */
	bb_rel(b, SCL);
	ack = bb_get(b, SDA);
	bb_low(b, SCL);
	return ack;				/* 0 = ACK (slave pulled low) */
}

static u8 bb_rd(struct bb *b, u32 SCL, u32 SDA, int nak)
{
	u8 v = 0;
	int i;

	bb_rel(b, SDA);
	for (i = 7; i >= 0; i--) {
		bb_rel(b, SCL);
		if (bb_get(b, SDA)) v |= BIT(i);
		bb_low(b, SCL);
	}
	if (nak) bb_rel(b, SDA); else bb_low(b, SDA);
	bb_rel(b, SCL); bb_low(b, SCL);
	bb_rel(b, SDA);
	return v;
}


/* `echo <mux> > gpiop`: identify which PWR_GPIO bits are the IIC2 pads.
 * Sets both IIC2 pads to <mux> (0 = IIC2, 3 = PWR_GPIO), parks every line as
 * input, then drives each of the low 4 bits low in turn and reports EXT_PORTA
 * before/after. The bit that moves IS that pad, no guessing from docs. */
static ssize_t gpiop_write(struct file *f, const char __user *ubuf,
			   size_t len, loff_t *ppos)
{
	void __iomem *g, *m;
	u32 s0, s1, base, i;
	int mux = 3, ret;

	ret = kstrtoint_from_user(ubuf, len, 0, &mux);
	if (ret)
		return ret;
	g = ioremap(PWRGPIO_BASE, 0x100);
	m = ioremap(MUX_IIC2_BASE, 8);
	if (!g || !m) {
		if (g) iounmap(g);
		if (m) iounmap(m);
		return -ENOMEM;
	}
	s0 = ioread32(m); s1 = ioread32(m + 4);
	iowrite32(mux, m); iowrite32(mux, m + 4);
	iowrite32(0, g + PWRGPIO_DDR);			/* all inputs */
	udelay(50);
	base = ioread32(g + PWRGPIO_EXT);
	pr_info("gpiop: mux=%d (was %#x/%#x) DR=%#010x DDR=%#010x EXT=%#010x\n",
		mux, s0, s1, ioread32(g + PWRGPIO_DR),
		ioread32(g + PWRGPIO_DDR), base);
	for (i = 0; i < 4; i++) {
		u32 bit = BIT(i), after;

		iowrite32(ioread32(g + PWRGPIO_DR) & ~bit, g + PWRGPIO_DR);
		iowrite32(bit, g + PWRGPIO_DDR);	/* drive just this one low */
		udelay(50);
		after = ioread32(g + PWRGPIO_EXT);
		iowrite32(0, g + PWRGPIO_DDR);
		udelay(50);
		pr_info("gpiop:   drive bit%u low -> EXT=%#010x  (changed: %#010x)\n",
			i, after, base ^ after);
	}
	iowrite32(0, g + PWRGPIO_DDR);
	iowrite32(s0, m); iowrite32(s1, m + 4);
	iounmap(g); iounmap(m);
	return len;
}

static const struct file_operations gpiop_fops = {
	.owner = THIS_MODULE, .write = gpiop_write, .llseek = noop_llseek,
};
/* `echo "<addr7> <reg>" > bitbang` -> reads one register, result in dmesg. */
static ssize_t bitbang_write(struct file *f, const char __user *ubuf,
			     size_t len, loff_t *ppos)
{
	char buf[32];
	struct bb b;
	u32 saved0, saved1;
	int addr = 0x48, reg = 0x00, sclb = 0, sdab = 2, a1, a2, a3;
	u32 SCL, SDA;
	u8 val;

	if (len >= sizeof(buf))
		return -EINVAL;
	if (copy_from_user(buf, ubuf, len))
		return -EFAULT;
	buf[len] = '\0';
	if (sscanf(buf, "%i %i %i %i", &addr, &reg, &sclb, &sdab) < 1)
		return -EINVAL;
	SCL = BIT(sclb); SDA = BIT(sdab);

	b.gpio = ioremap(PWRGPIO_BASE, 0x100);
	b.mux  = ioremap(MUX_IIC2_BASE, 8);
	if (!b.gpio || !b.mux) {
		if (b.gpio) iounmap(b.gpio);
		if (b.mux) iounmap(b.mux);
		return -ENOMEM;
	}
	saved0 = ioread32(b.mux);
	saved1 = ioread32(b.mux + 4);
	iowrite32(3, b.mux);			/* both pads -> PWR_GPIO */
	iowrite32(3, b.mux + 4);
	bb_rel(&b, SCL); bb_rel(&b, SDA);
	udelay(20);

	bb_start(&b, SCL, SDA);
	a1 = bb_wr(&b, SCL, SDA, (addr << 1) | 0);
	a2 = bb_wr(&b, SCL, SDA, reg);
	bb_start(&b, SCL, SDA);			/* repeated start */
	a3 = bb_wr(&b, SCL, SDA, (addr << 1) | 1);
	val = bb_rd(&b, SCL, SDA, 1);
	bb_stop(&b, SCL, SDA);

	iowrite32(saved0, b.mux);		/* hand the pads back to IIC2 */
	iowrite32(saved1, b.mux + 4);
	pr_info("bitbang: addr=%#04x reg=%#04x scl=bit%d sda=bit%d -> %#04x (ack: addr=%d reg=%d rd=%d; 0=ACK)\n",
		addr, reg, sclb, sdab, val, a1, a2, a3);
	iounmap(b.gpio);
	iounmap(b.mux);
	return len;
}

static const struct file_operations bitbang_fops = {
	.owner = THIS_MODULE, .write = bitbang_write, .llseek = noop_llseek,
};
static const struct file_operations padw_fops = {
	.owner = THIS_MODULE, .write = padw_write, .llseek = noop_llseek,
};

static int pads_show(struct seq_file *s, void *unused)
{
	void __iomem *p = ioremap(0x05027040, 8);
	void __iomem *m = ioremap(0x030010b8, 8);

	if (p) {
		seq_printf(s, "pad 0x05027040 IIC2_SCL = %#010x\n", ioread32(p));
		seq_printf(s, "pad 0x05027044 IIC2_SDA = %#010x\n", ioread32(p + 4));
		iounmap(p);
	}
	if (m) {
		seq_printf(s, "mux 0x030010b8 IIC2_SCL = %#010x\n", ioread32(m));
		seq_printf(s, "mux 0x030010bc IIC2_SDA = %#010x\n", ioread32(m + 4));
		iounmap(m);
	}
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(pads);
static int fbcheck_show(struct seq_file *s, void *unused)
{
	const u8 *fb;
	size_t i, lit = 0, rsum = 0;

	if (!g || !g->fb_cpu)
		return -ENODEV;
	fb = g->fb_cpu;
	for (i = 0; i < VID_PLANE; i++)
		if (fb[i]) { lit++; rsum += fb[i]; }
	seq_printf(s, "scroll=%s x=%u\n", scroll_on ? "on" : "off", scroll_x);
	seq_printf(s, "R-plane lit px = %zu / %u (%zu%%)\n",
		   lit, (unsigned int)VID_PLANE, lit * 100 / VID_PLANE);
	seq_printf(s, "R-plane sum    = %zu\n", rsum);
	seq_printf(s, "fb_dma         = %pad size=%zu\n", &g->fb_dma, g->fb_size);
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(fbcheck);

/* sclr_dsi_set_mode */
static int dsi_set_mode(u8 mode)
{
	if (mode == DSI_MODE_IDLE) {
		u32 m = scl_r(SCL_DSI_MAC_EN);

		if (m != DSI_MODE_IDLE)
			scl_w(SCL_DSI_MAC_EN, m);	/* clr_mode: write-1-clear */
		return 0;
	}
	if (scl_r(SCL_DSI_MAC_EN)) {
		pr_warn("dsi_set_mode: MAC_EN not idle (%#x); clearing\n",
			scl_r(SCL_DSI_MAC_EN));
		scl_w(SCL_DSI_MAC_EN, scl_r(SCL_DSI_MAC_EN));
	}
	scl_w(SCL_DSI_MAC_EN, mode);
	return 0;
}

/* full SG2000-side bring-up: mipi_tx_set_combo_dev_cfg + Nick's D-PHY additions
 * (HS-settle, analog, LP-11 handoff) + the dialect HS_0 + a real framebuffer
 * scanout. Emits a 1280x720@60 DSI colorbar the LT8912B can lock. */
static void do_bringup(void)
{
	bool data_en[4] = { false, false, false, false };
	const u8 *lm = (lanes == 2) ? lane_map2 : lane_map4;
	int i;

	nlanes = (lanes == 2) ? 2 : 4;
	pr_info("=== SG2000 DSI bring-up: 1280x720@60 RGB888 x%d lanes, fb=%pad ===\n",
		nlanes, &g->fb_dma);

	g_disp_cfg = 0;		/* fresh cfg accumulation: fmt/pol/from_sc/sync_ext only */
	vip_cold_init();
	scl_top_init();
	/* Set the disp control bits the vendor relies on the FSBL leaving latched (and
	 * mainline lacks), masked so later config commits preserve them: SHRD_SEL(bit18)
	 * = CPU reads return the active bank; FORCE_CLK(bit31) = hold the disp datapath
	 * clock on instead of auto-gating when the tgen is briefly idle. */
	scl_m(SCL_DISP_CFG, BIT(31) | BIT(18), BIT(31) | BIT(18));

	/* lanes */
	dphy_disable_lanes();
	for (i = 0; i < 5; ++i) {
		if (lm[i] > LANE_D3) {		/* unused PHY lane: powerdown role */
			phy_m(PHY_LANE_SEL, 0x7u << (4 * i), lm[i] << (4 * i));
			continue;
		}
		dphy_set_lane(i, lm[i], (pn_swap >> i) & 1, true);
		if (lm[i] != LANE_CLK)
			data_en[lm[i] - 1] = true;
	}
	dphy_lane_en(true, data_en,
		     ((u32)pixclk_khz * VID_BITS / nlanes) > 1500000);
	dphy_set_pll(pixclk_khz, nlanes, VID_BITS);
	/* CLK_DISP_DIV_UP_W1T (VIP_CLK_CTRL0 bit16): the write-1-trigger that latches
	 * the disp clock divider and starts the disp dot clock. cal_pll_reg set the
	 * TXPLL /24 tap (bit4), but the vendor pulses this bit16 for every VO interface
	 * to make the disp clock live (BT601 pulses it with div_cnt=0 and no tap, so
	 * it is mandatory independent of the divider value). Mainline never pulsed it,
	 * so the dot clock never toggled -> tgen (bit7) could not advance -> the scanout
	 * engine stayed idle (CATCH_ACT=0, checksum DAT_IN=0, black). This is the last
	 * cold-init latch the vendor FSBL/prior mode leaves applied and mainline lacks. */
	vip_m(VIP_CLK_CTRL0, BIT(16), BIT(16));
	dphy_set_hs_settle(6, 32, 5);		/* LT9611 hs_timing_cfg */

	/* Fable fix: dphy_set_pll (via _cal_pll_reg) has now set VIP_CLK_CTRL0 bit4,
	 * so the D-PHY TXPLL VCO exposes a /24 = 74.25 MHz disp tap that is the same
	 * VCO as the DSI byte clock -> phase-locked. Gate the DISPPLL-derived
	 * clk_disp_src (148.5) so the disp tgen dot clock uses that TXPLL tap instead
	 * of the free-running DISPPLL, killing the pixel-vs-byte FIFO drift. */
	if (disp_src_off && !g->disp_src_gated) {
		for (i = 0; i < g->nclks; i++) {
			if (strcmp(g->clks[i].id, "disp-src"))
				continue;
			clk_disable_unprepare(g->clks[i].clk);
			g->disp_src_gated = true;
			pr_info("gated clk_disp_src (DISPPLL) -> tgen on TXPLL tap\n");
			break;
		}
	} else if (!disp_src_off && g->disp_src_gated) {
		for (i = 0; i < g->nclks; i++) {
			if (strcmp(g->clks[i].id, "disp-src"))
				continue;
			clk_prepare_enable(g->clks[i].clk);
			g->disp_src_gated = false;
			break;
		}
	}

	disp_set_intf_mipi();			/* incl. dphy_init + analog */
	dsi_config();				/* HS_0 dialect = 0x22000000 */
	disp_set_timing();
	if (use_fb && g->fb_dma)
		disp_set_scanout(g->fb_dma);	/* real framebuffer, not pattern-gen */
	else
		disp_set_pattern(PAT_TYPE_FULL, PAT_COLOR_BAR);	/* Debian-golden path */
	disp_tgen_enable(true);	/* LIVE bit7; the config was already promoted by scanout/timing above */

	/* Start the MAC in HS. lp11=1 (Nick): force LP-11 on the data-override
	 * regs, idle, release, then HS. lp11=0: vendor-exact mipi_tx_enable() =
	 * bare set_mode(HS) with no DATA_OV poke, test whether Nick's override
	 * is what keeps the clock lane out of HS-continuous. */
	if (lp11) {
		phy_w(PHY_DATA_OV, 0x1f1f1f1f);
		dsi_set_mode(DSI_MODE_IDLE);
		phy_w(PHY_DATA_OV, 0);
	}
	dsi_set_mode(DSI_MODE_HS);

	pr_info("done: MAC_EN=%#x LANE_SEL=%#010x HS_0=%#010x HS_1=%#010x DATA12=%#010x\n",
		scl_r(SCL_DSI_MAC_EN), phy_r(PHY_LANE_SEL), scl_r(SCL_DSI_HS_0),
		scl_r(SCL_DSI_HS_1), phy_r(0x2c));
	pr_info("=== bring-up done; run LT8912B lt_landscape, then check capture ===\n");
}

/* safe introspection: clocks (framework, no MMIO) + LT8912B (I2C) */
static int clocks_show(struct seq_file *s, void *u)
{
	int i;

	if (!g)
		return 0;
	for (i = 0; i < g->nclks; i++)
		seq_printf(s, "  %-10s = %lu Hz\n", g->clks[i].id,
			   clk_get_rate(g->clks[i].clk));
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(clocks);

static int lt8912b_probe_one(struct i2c_adapter *a, u8 addr, u8 *val)
{
	u8 reg = 0x00, v = 0;
	struct i2c_msg msgs[2] = {
		{ .addr = addr, .flags = 0,        .len = 1, .buf = &reg },
		{ .addr = addr, .flags = I2C_M_RD, .len = 1, .buf = &v },
	};
	int ret = i2c_transfer(a, msgs, 2);

	if (val)
		*val = v;
	return ret;
}

static int lt8912b_show(struct seq_file *s, void *u)
{
	size_t i;

	if (!g || !g->adap) {
		seq_puts(s, "no i2c adapter\n");
		return 0;
	}
	seq_printf(s, "LT8912B on %s (bus %d):\n", g->adap->name, i2c_bus);
	for (i = 0; i < ARRAY_SIZE(lt8912b_addrs); i++) {
		u8 v = 0;
		int ret = lt8912b_probe_one(g->adap, lt8912b_addrs[i], &v);

		seq_printf(s, ret == 2 ? "  0x%02x: ACK, reg0=%#04x\n"
					: "  0x%02x: no answer (%d)\n",
			   lt8912b_addrs[i], ret == 2 ? v : ret);
	}
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(lt8912b);

/* debugfs triggers */
static ssize_t bringup_write(struct file *f, const char __user *ubuf,
			     size_t len, loff_t *ppos)
{
	int v, ret;

	ret = kstrtoint_from_user(ubuf, len, 0, &v);
	if (ret)
		return ret;
	if (!g || v != 1) {
		pr_warn("bringup: echo 1 to run the full SG2000 DSI colorbar sequence\n");
		return -EINVAL;
	}
	do_bringup();
	return len;
}
static const struct file_operations bringup_fops = {
	.owner = THIS_MODULE, .write = bringup_write, .llseek = noop_llseek,
};

/* live pattern change: `echo <type> <color>` (type 0=full 1=hgrad 2=vgrad
 * 5=off; color 0=white..6=yellow 7=bar). Single arg = vopat-style color idx. */
static ssize_t pattern_write(struct file *f, const char __user *ubuf,
			     size_t len, loff_t *ppos)
{
	char buf[32];
	int type = PAT_TYPE_FULL, color = PAT_COLOR_BAR, n;

	if (!g)
		return -EINVAL;
	if (len >= sizeof(buf))
		return -EINVAL;
	if (copy_from_user(buf, ubuf, len))
		return -EFAULT;
	buf[len] = '\0';
	n = sscanf(buf, "%d %d", &type, &color);
	if (n < 1)
		return -EINVAL;
	if (n == 1) {		/* single arg = color index; 0 = off */
		color = type;
		type = (color == 0) ? PAT_TYPE_OFF : PAT_TYPE_FULL;
	}
	disp_set_pattern(type, color);
	return len;
}
static const struct file_operations pattern_fops = {
	.owner = THIS_MODULE, .write = pattern_write, .llseek = noop_llseek,
};

/* VIP_SYS cold-init on its own (accessibility probe / manual step) */
static ssize_t vipinit_write(struct file *f, const char __user *ubuf,
			     size_t len, loff_t *ppos)
{
	int v, ret;

	ret = kstrtoint_from_user(ubuf, len, 0, &v);
	if (ret)
		return ret;
	if (!g || !g->vipsys || v != 1) {
		pr_warn("vipinit: echo 1 to run\n");
		return -EINVAL;
	}
	vip_cold_init();
	return len;
}
static const struct file_operations vipinit_fops = {
	.owner = THIS_MODULE, .write = vipinit_write, .llseek = noop_llseek,
};

/* interactive MMIO poke: r|w|m <phy|scl|vip> <off> [val|mask val] (-> dmesg) */
static void __iomem *io_blk(const char *name)
{
	if (!g)
		return NULL;
	if (!strcmp(name, "phy"))
		return g->phy;
	if (!strcmp(name, "scl"))
		return g->scaler;
	if (!strcmp(name, "vip"))
		return g->vipsys;
	return NULL;
}

static ssize_t io_write(struct file *f, const char __user *ubuf,
			size_t len, loff_t *ppos)
{
	char buf[96], cmd = 0, blk[8] = "";
	u32 off = 0, a = 0, b = 0, old, nw;
	void __iomem *base;
	int n;

	if (len >= sizeof(buf))
		return -EINVAL;
	if (copy_from_user(buf, ubuf, len))
		return -EFAULT;
	buf[len] = '\0';

	n = sscanf(buf, "%c %7s %x %x %x", &cmd, blk, &off, &a, &b);
	base = io_blk(blk);
	if (n < 3 || !base) {
		pr_warn("io: usage: r|w|m <phy|scl|vip> <off> [val|mask val]\n");
		return -EINVAL;
	}
	switch (cmd) {
	case 'r':
		pr_info("io r %s+%#06x = %#010x\n", blk, off, readl(base + off));
		break;
	case 'w':
		if (n < 4)
			return -EINVAL;
		writel(a, base + off);
		pr_info("io w %s+%#06x <= %#010x\n", blk, off, a);
		break;
	case 'm':
		if (n < 5)
			return -EINVAL;
		old = readl(base + off);
		nw = (old & ~a) | (b & a);
		writel(nw, base + off);
		pr_info("io m %s+%#06x mask %#010x: %#010x -> %#010x\n",
			blk, off, a, old, nw);
		break;
	default:
		pr_warn("io: bad cmd '%c' (r|w|m)\n", cmd);
		return -EINVAL;
	}
	return len;
}
static const struct file_operations io_fops = {
	.owner = THIS_MODULE, .write = io_write, .llseek = noop_llseek,
};

/*
 * Map a reg range by name without claiming it exclusively.
 *
 * devm_platform_ioremap_resource_byname() calls request_mem_region(), and the
 * forward-ported vendor stack (pkgs/video/soph-display) claims vip_sys from
 * cv181x_base, so the exclusive request loses with -EBUSY the moment both are
 * loaded. This is a bring-up harness that deliberately shares the VIP block
 * with whatever else has it open, so map it plainly.
 */
static void __iomem *map_byname(struct platform_device *pdev, const char *name)
{
	struct resource *r = platform_get_resource_byname(pdev, IORESOURCE_MEM, name);
	void __iomem *p;

	if (!r)
		return IOMEM_ERR_PTR(-EINVAL);
	p = devm_ioremap(&pdev->dev, r->start, resource_size(r));
	return p ? p : IOMEM_ERR_PTR(-ENOMEM);
}

/* platform driver */
static int bringup_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct bringup *b;
	size_t i;
	int ret;

	b = devm_kzalloc(dev, sizeof(*b), GFP_KERNEL);
	if (!b)
		return -ENOMEM;
	b->dev = dev;

	b->scaler = map_byname(pdev, "scaler");
	if (IS_ERR(b->scaler))
		return dev_err_probe(dev, PTR_ERR(b->scaler), "map scaler\n");
	b->phy = map_byname(pdev, "dsi-phy");
	if (IS_ERR(b->phy))
		return dev_err_probe(dev, PTR_ERR(b->phy), "map dsi-phy\n");
	b->vipsys = map_byname(pdev, "vip-sys");
	if (IS_ERR(b->vipsys))
		return dev_err_probe(dev, PTR_ERR(b->vipsys), "map vip-sys\n");

	/* The ungate: hold the VIP/display clocks so the blocks are reachable. */
	b->nclks = devm_clk_bulk_get_all(dev, &b->clks);
	if (b->nclks < 0)
		return dev_err_probe(dev, b->nclks, "get clocks\n");
	ret = clk_bulk_prepare_enable(b->nclks, b->clks);
	if (ret)
		return dev_err_probe(dev, ret, "enable %d clocks\n", b->nclks);

	/* Colorbar framebuffer for the disp DMA scanout (needs cma=16M on cmdline). */
	if (dma_coerce_mask_and_coherent(dev, DMA_BIT_MASK(32)))
		dev_warn(dev, "no 32-bit DMA mask\n");
	b->fb_size = VID_FB_SIZE;
	b->fb_cpu = dma_alloc_coherent(dev, b->fb_size, &b->fb_dma, GFP_KERNEL);
	if (b->fb_cpu) {
		fill_colorbar(b->fb_cpu);
		dev_info(dev, "framebuffer: %zu bytes @ %pad (colorbar)\n",
			 b->fb_size, &b->fb_dma);
	} else {
		b->fb_dma = 0;
		dev_warn(dev, "framebuffer alloc failed; bringup falls back to pattern-gen\n");
	}

	b->adap = i2c_get_adapter(i2c_bus);
	if (!b->adap)
		dev_warn(dev, "no i2c adapter %d; LT8912B probe disabled\n", i2c_bus);

	platform_set_drvdata(pdev, b);
	g = b;

	if (b->adap) {
		for (i = 0; i < ARRAY_SIZE(lt8912b_addrs); i++) {
			u8 v = 0;
			int r = lt8912b_probe_one(b->adap, lt8912b_addrs[i], &v);

			dev_info(dev, r == 2 ? "LT8912B 0x%02x: ACK, reg0=%#04x\n"
					     : "LT8912B 0x%02x: no answer (%d)\n",
				 lt8912b_addrs[i], r == 2 ? v : r);
		}
	}

	b->dbg = debugfs_create_dir("lt8912b_bringup", NULL);
	debugfs_create_file("clocks",  0400, b->dbg, NULL, &clocks_fops);
	debugfs_create_file("lt8912b", 0400, b->dbg, NULL, &lt8912b_fops);
	debugfs_create_file("bringup", 0200, b->dbg, NULL, &bringup_fops);
	debugfs_create_file("pattern", 0200, b->dbg, NULL, &pattern_fops);
	debugfs_create_file("io",      0200, b->dbg, NULL, &io_fops);
	debugfs_create_file("vipinit", 0200, b->dbg, NULL, &vipinit_fops);
	debugfs_create_file("scroll",  0200, b->dbg, NULL, &scroll_fops);
	debugfs_create_file("fbcheck", 0400, b->dbg, NULL, &fbcheck_fops);
	debugfs_create_file("fbfill",  0200, b->dbg, NULL, &fbfill_fops);
	/* The scanout map is a real device node, not debugfs: debugfs wraps files
	 * in a proxy fops that does not forward .mmap, so mmap() there fails with
	 * ENODEV no matter what the driver provides. */
	if (misc_register(&fbmap_misc))
		dev_warn(dev, "fbmap: misc_register failed; no /dev/badgefb\n");
	debugfs_create_file("pads",    0400, b->dbg, NULL, &pads_fops);
	debugfs_create_file("padw",    0200, b->dbg, NULL, &padw_fops);
	debugfs_create_file("bitbang", 0200, b->dbg, NULL, &bitbang_fops);
	debugfs_create_file("gpiop",   0200, b->dbg, NULL, &gpiop_fops);

	dev_info(dev, "up: %d VIP clocks enabled, LT8912B probed. `echo 1 > /sys/kernel/debug/lt8912b_bringup/bringup` to start.\n",
		 b->nclks);
	return 0;
}

static void bringup_remove(struct platform_device *pdev)
{
	struct bringup *b = platform_get_drvdata(pdev);

	misc_deregister(&fbmap_misc);
	debugfs_remove_recursive(b->dbg);
	g = NULL;
	if (b->fb_cpu)
		scroll_on = false;
		cancel_delayed_work_sync(&scroll_work);
		dma_free_coherent(&pdev->dev, b->fb_size, b->fb_cpu, b->fb_dma);
	if (b->adap)
		i2c_put_adapter(b->adap);
	clk_bulk_disable_unprepare(b->nclks, b->clks);
	dev_info(&pdev->dev, "down: clocks gated, unloaded\n");
}

static const struct of_device_id bringup_of_match[] = {
	{ .compatible = "badge,sg2000-hdmi-bringup" },
	{ }
};
MODULE_DEVICE_TABLE(of, bringup_of_match);

static struct platform_driver bringup_driver = {
	.probe = bringup_probe,
	.remove = bringup_remove,
	.driver = {
		.name = "lt8912b-bringup",
		.of_match_table = bringup_of_match,
	},
};
module_platform_driver(bringup_driver);

MODULE_AUTHOR("badgeos");
MODULE_DESCRIPTION("SG2000 HDMI (LT8912B) mainline bring-up harness (#80)");
MODULE_LICENSE("GPL");
