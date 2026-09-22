// SPDX-License-Identifier: GPL-2.0-only
/*
 * Sophgo SG2000 MIPI DSI host: manual 1280x720 test-pattern path.
 *
 * Register sequences follow sophgo/osdrv aa542c41df94f7bc656cb740f6622a5dca7dc403
 * (interdrv/vpss/chip/cv181x/{scaler.c,dsi_phy.c,scaler_reg.h,reg_disp.h},
 * interdrv/vo/chip/cv181x/vo_mipi_tx.c, interdrv/base/chip/cv181x/reg_vip_sys.h)
 * and the SG2000 TRM v1.0 (sophgo/sophgo-doc 370d81b365ed528dc8f5dc91f63ed445e1142d4d).
 *
 * This is not a display driver. It registers a DSI host so the LT8912B bridge
 * driver can bind, holds the bridge chain on an unregistered DRM device, and
 * drives one fixed mode from the display block's internal pattern generator
 * through the sysfs `pinstripe` control. No /dev/dri node, no framebuffer.
 */
#include <linux/clk.h>
#include <linux/clk-provider.h>
#include <linux/completion.h>
#include <linux/delay.h>
#include <linux/i2c.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/mfd/syscon.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_graph.h>
#include <linux/platform_device.h>
#include <linux/regmap.h>

#include <drm/bridge/lt8912b.h>
#include <drm/drm_bridge.h>
#include <drm/drm_drv.h>
#include <drm/drm_encoder.h>
#include <drm/drm_mipi_dsi.h>
#include <drm/drm_mode_config.h>
#include <drm/drm_modes.h>

/* Scaler top (sc_top): scaler_reg.h REG_SCL_TOP_*. */
#define SC_TOP_CFG0		0x00
#define SC_TOP_CFG1		0x04
#define SC_TOP_SHD		0x10
#define SC_TOP_VO_MUX		0x70
/* scaler.c:sclr_ctrl_init -> sclr_top_set_cfg: force_clk_enable (31) | ip_trig_src (3);
 * TOP_CFG1: sc_debug_en (12) | qos_en 0xff (16..23), display fed from DRAM, scalers off.
 * Golden Debian reads back exactly these words.
 */
#define SC_TOP_CFG0_INIT	0x80000008
#define SC_TOP_CFG1_INIT	0x00ff1200
#define SC_TOP_REG_DONE		BIT(0)	/* sclr_top_reg_done */
#define SC_TOP_SHD_RAW_BANK	BIT(9)	/* reg_shrd_sel: read the working bank */
#define SC_TOP_FORCE_UP		0xff	/* sclr_top_reg_force_up: SHD[7:0] */

/* Display timing generator (disp): reg_disp.h. Counters are 14 bits, end:16 | start. */
#define DISP_CFG		0x00
#define DISP_TOTAL		0x04
#define DISP_VSYNC		0x08
#define DISP_VFDE		0x0c
#define DISP_VMDE		0x10
#define DISP_HSYNC		0x14
#define DISP_HFDE		0x18
#define DISP_HMDE		0x1c
#define DISP_PAT_CFG		0x94
#define DISP_PAT_COLOR0		0x98
#define DISP_PAT_COLOR1		0x9c
#define DISP_CACHE		0xc0
#define DISP_CFG_POLARITY	0x60	/* bit 6 hsync high, bit 5 vsync high */
#define DISP_CFG_TGEN		BIT(7)
#define DISP_CFG_COMMIT		BIT(16)	/* shadow commit trigger */
#define DISP_CFG_SHADOW_MASK	BIT(17)
#define DISP_CFG_READ_WORKING	BIT(18)	/* sclr_disp_reg_shadow_sel(false) */
/* scaler.c:sclr_disp_set_cfg at init: RGB planar format (2 << 12), source DRAM,
 * no external sync; the TGEN bit is sequenced separately. Cache mode on.
 */
#define DISP_CFG_INIT_MASK	0xf01f
#define DISP_CFG_INIT		0x2000
#define DISP_CACHE_MODE		BIT(0)
#define DISP_TIMING_MASK	0x3fff3fff
/* scaler.c:sclr_disp_set_pattern: vo.c pattern COLOR_BAR (7 << 24), enable (1),
 * 10-bit full-scale colours; window background off (bit 5).
 */
#define DISP_PAT_MASK		0x1f000016
#define DISP_PAT_COLORBAR	0x07000002
#define DISP_PAT_OFF_MASK	0x16
#define DISP_PAT_WINDOW_BG	BIT(5)

/* DSI MAC (dsi_mac): scaler_reg.h REG_SCL_DSI_*; TRM mipi_tx_control_registers. */
#define MAC_EN			0x00	/* bits 2:0 read-write-set mode request, 5:4 done */
#define MAC_HS0			0x04	/* lanes 25:24, EoT 26, continuous clock 29, format 31:30 */
#define MAC_HS1			0x08	/* word count 15:0, event delay 26:16 */
#define MAC_MODE_VIDEO		0x4	/* SCLR_DSI_MODE_HS */
#define MAC_HS0_MASK		0xe7000000
#define MAC_HS1_MASK		0x07ffffff

/* D-PHY (dphy): dsi_phy.c offsets. */
#define DPHY_EN			0x00
#define DPHY_HS			0x14
#define DPHY_PLL		0x6c
#define DPHY_UPDATE		0x8c
#define DPHY_SET		0x90
#define DPHY_MAP		0x9c
#define DPHY_PN			0xa0

/* VIP system syscon: reg_vip_sys.h. Shared with capture: masked regmap access only. */
#define VIP_RESET		0x00
#define VIP_CLK_CTRL0		0x18
#define VIP_DISP_SEL_BT_DIV1	BIT(4)		/* dsi_phy.c:_cal_pll_reg pixel clock route */
#define VIP_DISPLAY_RESETS	0x04900a00	/* disp 9, dsi_mac 11, mac_apb 20, phy_apb 23, phy 26 */

/*
 * The one supported mode: 1280x720p60, the LT9611_1280x720_60HZ table of the
 * Debian vendor reference. Every derived register word below is fixed for it.
 */
static const struct drm_display_mode sophgo_720p = {
	.clock = 74250,
	.hdisplay = 1280, .hsync_start = 1390, .hsync_end = 1430, .htotal = 1650,
	.vdisplay = 720, .vsync_start = 725, .vsync_end = 730, .vtotal = 750,
	.flags = DRM_MODE_FLAG_PHSYNC | DRM_MODE_FLAG_PVSYNC,
};

/* vo_mipi_tx.c:_fill_disp_timing counts from the sync origin: sync runs 1..width,
 * active starts at 1 + total - sync_start, total stores count - 1.
 */
#define DISP_TOTAL_720P		0x067102ed	/* 1649 << 16 | 749 */
#define DISP_HSYNC_720P		0x00280001	/* 40 pixels from 1 */
#define DISP_HACTIVE_720P	0x06040105	/* 261..1540 */
#define DISP_VSYNC_720P		0x00050001	/* 5 lines from 1 */
#define DISP_VACTIVE_720P	0x02e9001a	/* 26..745 */
#define DISP_POLARITY_720P	0x60		/* both syncs positive */

/* scaler.c:sclr_dsi_config for four lanes RGB888: lanes/2 << 24; EoT and the
 * continuous clock are reset defaults the vendor never clears and the golden
 * transmitter runs with (the bridge's NO_EOT_PACKET request is not honoured).
 * HS1: word count 1280 * 3 bytes, event delay 1280 / 10 pixel clocks.
 */
#define MAC_HS0_720P		0x26000000
#define MAC_HS1_720P		0x00800f00

/* dsi_phy.c:dphy_dsi_set_lane for the badge: pads 0..4 carry data0, data1,
 * clock, data2, data3 (four bits per pad, 0 = clock), 90 degree clock phase
 * (bit 24 + clock pad), no PN swap. Lane enable: clock and four data lanes;
 * no preamble below 1.5 Gbit/s per lane (here 445.5 Mbit/s).
 */
#define DPHY_MAP_720P		0x04043021
#define DPHY_PN_720P		0
#define DPHY_LANE_EN		0x1f
/* dsi_phy.c:dphy_set_hs_settle raw counts: trail 5, zero 32, prepare 6. */
#define DPHY_HS_720P		0x05200600
/* dsi_phy.c:_cal_pll_reg with the 25 MHz reference: 74250 kHz * 24 bpp =
 * 1782000 kbit/s; per-lane 445500 needs VCO gain 4 (div_out 2), VCO 1782000 kHz,
 * pixel divider 24 (<= 127, so the VIP divider selects div1), loop 1,
 * synthesizer set = (900000 * 8 << 26) / 1782000.
 */
#define DPHY_TXPLL_720P		0x218
#define DPHY_LOOP_720P		(1 << 20)
#define DPHY_SET_720P		0x10295fad

#define SOPHGO_ESC_HZ		20000000	/* clk_dsi_esc from AXI6 */
#define SOPHGO_DSI_SRC_HZ	900000000	/* MIPIMPLL full-rate synthesizer source */
#define SOPHGO_CLK_BT_VIP	120		/* dt-bindings/clock/sophgo,cv1800.h */

enum sophgo_clock {
	SOPHGO_CLK_SC_TOP,
	SOPHGO_CLK_DISP,
	SOPHGO_CLK_DSI_MAC,
	SOPHGO_CLK_DSI_ESC,
	SOPHGO_CLK_DISPPLL,
	SOPHGO_CLK_DISP_SRC,
	SOPHGO_CLK_DSI_SRC,
	SOPHGO_CLK_CFG_REG,
	SOPHGO_CLK_COUNT,
};

/* cfg_reg (CLK_CFG_REG_VIP) gates the register interface of every block below
 * and must stay held across all direct accesses; the syscon takes it per access.
 */
static const char *const sophgo_clock_names[SOPHGO_CLK_COUNT] = {
	"sc_top", "clk_disp", "clk_dsi", "dsi_esc", "disppll", "disp_src", "dsi_src", "cfg_reg",
};

struct sophgo_dsi {
	struct drm_device drm;
	struct drm_encoder encoder;
	struct device *dev;
	struct mipi_dsi_host host;
	struct mipi_dsi_device *peripheral;
	struct drm_bridge *bridge;
	struct device_node *bridge_node;
	void __iomem *top, *disp, *mac, *phy;
	struct regmap *vip;
	struct clk_bulk_data clocks[SOPHGO_CLK_COUNT];
	struct clk *bt, *esc_parent;
	/* Serializes attach, detach, shutdown and the sysfs control. */
	struct mutex lock;
	/* Shared with the bridge; first error and its stage stick until a clean stop. */
	struct lt8912b_pipeline status;
	/* Owned resources, released in reverse order by sophgo_release(). */
	bool clocks_on, bt_on, esc_set, div_set, phy_on, display_on;
	struct clk *esc_old_parent;
	unsigned long esc_old_rate, pll_hz;
	unsigned int div_old, mac_en;
	bool terminal;
};

static struct sophgo_dsi *host_to_dsi(struct mipi_dsi_host *host)
{
	return container_of(host, struct sophgo_dsi, host);
}

static void sophgo_rmw(void __iomem *reg, u32 mask, u32 value)
{
	writel((readl(reg) & ~mask) | (value & mask), reg);
}

/* DISP_CFG bit 16 is a commit command: never replay it from a readback. */
static void sophgo_disp_cfg(struct sophgo_dsi *dsi, u32 mask, u32 value)
{
	u32 old = readl(dsi->disp + DISP_CFG) & ~DISP_CFG_COMMIT;

	writel((old & ~mask) | (value & mask), dsi->disp + DISP_CFG);
}

static bool sophgo_rate_near(unsigned long got, unsigned long want)
{
	unsigned long delta = got > want ? got - want : want - got;

	return got && want && delta <= want / 1000000;
}

static bool sophgo_owned(struct sophgo_dsi *dsi)
{
	return dsi->clocks_on || dsi->bt_on || dsi->esc_set || dsi->div_set || dsi->phy_on ||
	       dsi->display_on || dsi->status.host_started || dsi->status.prepared ||
	       dsi->status.started || dsi->status.supplies_owned;
}

/* MAC_EN is read-write-set: writing the active mode back clears it
 * (scaler.c:sclr_dsi_clr_mode). A mode this host never requested is refused,
 * and a timeout is not quiescence: the caller keeps every resource.
 */
static int sophgo_mac_quiesce(struct sophgo_dsi *dsi)
{
	u32 val = readl(dsi->mac + MAC_EN);
	int ret;

	if ((val & 0xf) && (val & 0xf) != MAC_MODE_VIDEO)
		return -EBUSY;
	if (val & MAC_MODE_VIDEO)
		writel(val, dsi->mac + MAC_EN);
	ret = read_poll_timeout(readl, val, !(val & 0xf), 1000, 20000, false, dsi->mac + MAC_EN);
	dsi->mac_en = val;
	return ret;
}

static int sophgo_mac_configure(struct sophgo_dsi *dsi)
{
	int ret = sophgo_mac_quiesce(dsi);

	if (ret)
		return ret;
	sophgo_rmw(dsi->mac + MAC_HS0, MAC_HS0_MASK, MAC_HS0_720P);
	sophgo_rmw(dsi->mac + MAC_HS1, MAC_HS1_MASK, MAC_HS1_720P);
	readl(dsi->mac + MAC_HS1);
	return 0;
}

/* vo_mipi_tx.c:mipi_tx_enable writes the HS request and returns without
 * polling. The 20 ms poll only records the acknowledgement: the status line
 * reports the observed MAC_EN, and a missing acknowledgement is not fatal here.
 */
static int sophgo_mac_start(struct sophgo_dsi *dsi)
{
	u32 val = readl(dsi->mac + MAC_EN);

	if (val & 0xf)
		return -EBUSY;
	/* Settle time between TGEN start and the HS request; kept from the
	 * demonstrated sequence, its necessity has not been isolated.
	 */
	usleep_range(5000, 7000);
	writel(val | MAC_MODE_VIDEO, dsi->mac + MAC_EN);
	if (read_poll_timeout(readl, val, (val & 0xf) == MAC_MODE_VIDEO, 1000, 20000, false,
			      dsi->mac + MAC_EN))
		dev_warn(dsi->dev, "MAC did not acknowledge video within 20 ms: MAC_EN=%#x\n", val);
	dsi->mac_en = val;
	return 0;
}

/* vo_mipi_tx.c:mipi_tx_set_combo_dev_cfg -> dsi_phy.c: disable lanes, map,
 * PN, enable; then dphy_dsi_set_pll (VIP divider first), dphy_set_hs_settle,
 * and dphy_init's LP-11 writes: full PD word, lane and analogue overrides,
 * ending with the dphy_dsi_analog_setting(false) value in 0x74. Bit meanings
 * of the analogue words are undocumented; this reproduces the vendor writes.
 */
static void sophgo_dphy_program(struct sophgo_dsi *dsi)
{
	void __iomem *phy = dsi->phy;

	sophgo_rmw(phy + DPHY_EN, 0x3f, 0);
	sophgo_rmw(phy + DPHY_MAP, 0xfffff, 0);
	readl(phy + DPHY_EN);
	sophgo_rmw(phy + DPHY_MAP, 0x1f077777, DPHY_MAP_720P);
	sophgo_rmw(phy + DPHY_PN, 0x1f, DPHY_PN_720P);
	sophgo_rmw(phy + DPHY_EN, 0x3f, DPHY_LANE_EN);

	sophgo_rmw(phy + DPHY_PLL, 0x300000, DPHY_LOOP_720P);
	sophgo_rmw(phy + DPHY_PLL, 0x7ff, DPHY_TXPLL_720P);
	writel(DPHY_SET_720P, phy + DPHY_SET);
	sophgo_rmw(phy + DPHY_UPDATE, 1, 0);
	sophgo_rmw(phy + DPHY_UPDATE, 1, 1);
	sophgo_rmw(phy + DPHY_HS, 0xffffff00, DPHY_HS_720P);

	writel(0, phy + 0x64);
	sophgo_rmw(phy + 0x4c, 0x001f001f, 0);
	sophgo_rmw(phy + 0x54, 0x1f1f, 0);
	sophgo_rmw(phy + 0x50, 0x1f1f1f1f, 0);
	sophgo_rmw(phy + 0xc4, 0x1f1f, 0);
	sophgo_rmw(phy + 0xc8, 0x1f1f, 0);
	writel(0x100, phy + 0x0c);
	writel(0x100, phy + 0x10);
	sophgo_rmw(phy + 0xc0, 0xfffff, 0);
	sophgo_rmw(phy + 0xb4, 1, 0);
	sophgo_rmw(phy + 0x60, 0x10000, 0);
	sophgo_rmw(phy + 0x5c, 0x1f000000, 0);
	sophgo_rmw(phy + 0x88, 0xfffff, 0);
	sophgo_rmw(phy + 0x74, 0x3ff, 0);
	/* scaler.c:sclr_disp_set_intf(MIPI): the parallel VO output is off. */
	sophgo_rmw(dsi->top + SC_TOP_VO_MUX, 0xf, 0);
	readl(dsi->top + SC_TOP_VO_MUX);
}

/* sclr_disp_set_intf(DISABLE) -> dphy_init: lanes off, then PD=0x1f1f. */
static void sophgo_dphy_power_down(void __iomem *phy)
{
	sophgo_rmw(phy + DPHY_EN, 0x3f, 0);
	sophgo_rmw(phy + DPHY_MAP, 0xfffff, 0);
	sophgo_rmw(phy + 0x44, 0x1f1f1f1f, 0);
	sophgo_rmw(phy + 0x64, 0x1f1f, 0x1f1f);
	readl(phy + 0x64);
}

/* Vendor scaler.c:sclr_ctrl_init order: scaler-top config, raw readback bank,
 * reg_done and force_up once; then the DISP fields under the shadow mask
 * reading the working bank, timing with TGEN off, pattern, TGEN on, commit.
 */
static void sophgo_display_start(struct sophgo_dsi *dsi)
{
	void __iomem *top = dsi->top, *disp = dsi->disp;

	writel(SC_TOP_CFG0_INIT, top + SC_TOP_CFG0);
	writel(SC_TOP_CFG1_INIT, top + SC_TOP_CFG1);
	writel(SC_TOP_SHD_RAW_BANK, top + SC_TOP_SHD);
	sophgo_rmw(top + SC_TOP_CFG0, SC_TOP_REG_DONE, SC_TOP_REG_DONE);
	sophgo_rmw(top + SC_TOP_SHD, SC_TOP_FORCE_UP, SC_TOP_FORCE_UP);
	readl(top + SC_TOP_CFG0);

	sophgo_disp_cfg(dsi, DISP_CFG_READ_WORKING, DISP_CFG_READ_WORKING);
	sophgo_disp_cfg(dsi, DISP_CFG_SHADOW_MASK, DISP_CFG_SHADOW_MASK);
	sophgo_disp_cfg(dsi, DISP_CFG_INIT_MASK, DISP_CFG_INIT);
	sophgo_rmw(disp + DISP_CACHE, DISP_CACHE_MODE, DISP_CACHE_MODE);
	readl(disp + DISP_CFG);

	sophgo_disp_cfg(dsi, DISP_CFG_TGEN, 0);
	sophgo_disp_cfg(dsi, DISP_CFG_POLARITY, DISP_POLARITY_720P);
	sophgo_rmw(disp + DISP_TOTAL, DISP_TIMING_MASK, DISP_TOTAL_720P);
	sophgo_rmw(disp + DISP_VSYNC, DISP_TIMING_MASK, DISP_VSYNC_720P);
	sophgo_rmw(disp + DISP_VFDE, DISP_TIMING_MASK, DISP_VACTIVE_720P);
	sophgo_rmw(disp + DISP_VMDE, DISP_TIMING_MASK, DISP_VACTIVE_720P);
	sophgo_rmw(disp + DISP_HSYNC, DISP_TIMING_MASK, DISP_HSYNC_720P);
	sophgo_rmw(disp + DISP_HFDE, DISP_TIMING_MASK, DISP_HACTIVE_720P);
	sophgo_rmw(disp + DISP_HMDE, DISP_TIMING_MASK, DISP_HACTIVE_720P);

	sophgo_rmw(disp + DISP_PAT_CFG, DISP_PAT_WINDOW_BG, 0);
	writel(0x03ff03ff, disp + DISP_PAT_COLOR0);
	sophgo_rmw(disp + DISP_PAT_COLOR1, 0x3ff, 0x3ff);
	sophgo_rmw(disp + DISP_PAT_CFG, DISP_PAT_MASK, DISP_PAT_COLORBAR);
	/* vo_mipi_tx.c:mipi_tx_set_combo_dev_cfg starts TGEN after the timing,
	 * before the bridge is released from reset and before the HS request.
	 */
	sophgo_disp_cfg(dsi, DISP_CFG_TGEN, DISP_CFG_TGEN);
	sophgo_disp_cfg(dsi, DISP_CFG_SHADOW_MASK, 0);
	sophgo_disp_cfg(dsi, DISP_CFG_COMMIT, DISP_CFG_COMMIT);
	readl(disp + DISP_CFG);
}

static void sophgo_display_stop(struct sophgo_dsi *dsi)
{
	sophgo_disp_cfg(dsi, DISP_CFG_READ_WORKING, DISP_CFG_READ_WORKING);
	sophgo_disp_cfg(dsi, DISP_CFG_SHADOW_MASK, DISP_CFG_SHADOW_MASK);
	sophgo_disp_cfg(dsi, DISP_CFG_TGEN, 0);
	sophgo_rmw(dsi->disp + DISP_PAT_CFG, DISP_PAT_WINDOW_BG, 0);
	sophgo_rmw(dsi->disp + DISP_PAT_CFG, DISP_PAT_OFF_MASK, 0);
	sophgo_disp_cfg(dsi, DISP_CFG_SHADOW_MASK, 0);
	sophgo_disp_cfg(dsi, DISP_CFG_COMMIT, DISP_CFG_COMMIT);
	readl(dsi->disp + DISP_CFG);
}

/* DISPPLL reports zero until locked (kernel patch), so a nonzero rate is the
 * lock observation; CCF success alone is not. The 1 ppm bound is a paper
 * tolerance for the escape divider, not a measured one.
 */
static int sophgo_clocks_ready(struct sophgo_dsi *dsi)
{
	struct clk *esc = dsi->clocks[SOPHGO_CLK_DSI_ESC].clk;
	unsigned long rate;
	int ret;

	ret = read_poll_timeout(clk_get_rate, rate, sophgo_rate_near(rate, dsi->pll_hz), 100,
				200000, false, dsi->clocks[SOPHGO_CLK_DISPPLL].clk);
	if (ret)
		return ret;
	if (clk_get_rate(dsi->clocks[SOPHGO_CLK_DSI_SRC].clk) != SOPHGO_DSI_SRC_HZ ||
	    !sophgo_rate_near(clk_get_rate(esc), SOPHGO_ESC_HZ) ||
	    !clk_is_match(clk_get_parent(esc), dsi->esc_parent))
		return -ERANGE;
	return 0;
}

/* vo_mipi_tx.c:_init_resources enables the display clocks before the DSI
 * ones and pulses no local reset; asserted display resets are refused, not
 * cleared. The escape clock and the VIP pixel-clock divider are saved and
 * restored on release. Ownership flags mark each step for partial unwind.
 */
static int sophgo_prepare(struct sophgo_dsi *dsi)
{
	struct clk *esc = dsi->clocks[SOPHGO_CLK_DSI_ESC].clk;
	unsigned int val;
	long rounded;
	int ret;

	ret = clk_bulk_prepare_enable(SOPHGO_CLK_COUNT, dsi->clocks);
	if (ret)
		return ret;
	dsi->clocks_on = true;
	ret = clk_prepare_enable(dsi->bt);
	if (ret)
		return ret;
	dsi->bt_on = true;
	ret = read_poll_timeout(clk_get_rate, dsi->pll_hz, dsi->pll_hz, 100, 200000, false,
				dsi->clocks[SOPHGO_CLK_DISPPLL].clk);
	if (ret)
		return ret;
	if (clk_get_rate(dsi->clocks[SOPHGO_CLK_DSI_SRC].clk) != SOPHGO_DSI_SRC_HZ)
		return -ERANGE;
	ret = regmap_read(dsi->vip, VIP_RESET, &val);
	if (ret)
		return ret;
	if (val & VIP_DISPLAY_RESETS)
		return -EBUSY;
	/* A firmware-preselected MAC must be idle before its PHY changes. */
	ret = sophgo_mac_quiesce(dsi);
	if (ret)
		return ret;

	dsi->esc_old_parent = clk_get_parent(esc);
	dsi->esc_old_rate = clk_get_rate(esc);
	if (!dsi->esc_old_parent || !dsi->esc_old_rate)
		return -ERANGE;
	dsi->esc_set = true;
	ret = clk_set_parent(esc, dsi->esc_parent);
	if (ret)
		return ret;
	rounded = clk_round_rate(esc, SOPHGO_ESC_HZ);
	if (rounded < 0)
		return rounded;
	if (!sophgo_rate_near(rounded, SOPHGO_ESC_HZ))
		return -ERANGE;
	ret = clk_set_rate(esc, rounded);
	if (ret)
		return ret;
	ret = sophgo_clocks_ready(dsi);
	if (ret)
		return ret;

	/* dsi_phy.c:_cal_pll_reg changes only disp_sel_bt_div1; the shared
	 * syscon serializes it. Drain the write before the first PHY access.
	 */
	ret = regmap_read(dsi->vip, VIP_CLK_CTRL0, &dsi->div_old);
	if (ret)
		return ret;
	dsi->div_old &= VIP_DISP_SEL_BT_DIV1;
	dsi->div_set = true;
	ret = regmap_update_bits(dsi->vip, VIP_CLK_CTRL0, VIP_DISP_SEL_BT_DIV1,
				 VIP_DISP_SEL_BT_DIV1);
	if (ret)
		return ret;
	ret = regmap_read(dsi->vip, VIP_CLK_CTRL0, &val);
	if (ret)
		return ret;
	dsi->phy_on = true;
	sophgo_dphy_program(dsi);
	return sophgo_mac_configure(dsi);
}

/* Hardware is quiescent on entry. A failed restore keeps the remaining
 * references so the stop can be retried without touching unowned state.
 */
static int sophgo_release(struct sophgo_dsi *dsi)
{
	struct clk *esc = dsi->clocks[SOPHGO_CLK_DSI_ESC].clk;
	unsigned int val;
	int ret;

	if (dsi->phy_on) {
		sophgo_dphy_power_down(dsi->phy);
		dsi->phy_on = false;
	}
	if (dsi->esc_set) {
		ret = clk_set_parent(esc, dsi->esc_old_parent);
		if (ret)
			return ret;
		ret = clk_set_rate(esc, dsi->esc_old_rate);
		if (ret)
			return ret;
		if (!clk_is_match(clk_get_parent(esc), dsi->esc_old_parent) ||
		    clk_get_rate(esc) != dsi->esc_old_rate)
			return -ERANGE;
		dsi->esc_set = false;
	}
	if (dsi->div_set) {
		ret = regmap_update_bits(dsi->vip, VIP_CLK_CTRL0, VIP_DISP_SEL_BT_DIV1, dsi->div_old);
		if (ret)
			return ret;
		ret = regmap_read(dsi->vip, VIP_CLK_CTRL0, &val);
		if (ret)
			return ret;
		if ((val & VIP_DISP_SEL_BT_DIV1) != dsi->div_old)
			return -EIO;
		dsi->div_set = false;
	}
	if (dsi->bt_on) {
		clk_disable_unprepare(dsi->bt);
		dsi->bt_on = false;
	}
	if (dsi->clocks_on) {
		clk_bulk_disable_unprepare(SOPHGO_CLK_COUNT, dsi->clocks);
		dsi->clocks_on = false;
	}
	return 0;
}

/* Ordered stop from any partial state: bridge receiver reset, MAC
 * acknowledged stop, display off, bridge rails, PHY and clocks. Returns
 * nonzero while anything remains owned; every stage keeps what it could
 * not release so the stop can be retried.
 */
static int sophgo_stop(struct sophgo_dsi *dsi)
{
	int ret;

	drm_atomic_bridge_chain_disable(dsi->bridge, NULL);
	if (dsi->clocks_on) {
		ret = sophgo_mac_quiesce(dsi);
		lt8912b_pipeline_error(&dsi->status, "MAC stop", ret);
		if (ret)
			return ret;
		if (dsi->display_on) {
			sophgo_display_stop(dsi);
			dsi->display_on = false;
		}
	}
	dsi->status.host_started = false;
	drm_atomic_bridge_chain_post_disable(dsi->bridge, NULL);
	if (dsi->status.supplies_owned)
		return dsi->status.error ?: -EBUSY;
	ret = sophgo_release(dsi);
	lt8912b_pipeline_error(&dsi->status, "PHY and clock release", ret);
	if (ret)
		return ret;
	dsi->status.host_prepared = false;
	return sophgo_owned(dsi) ? (dsi->status.error ?: -EBUSY) : 0;
}

/* Host preparation (LP-11 pads, TGEN running, MAC idle) precedes the bridge's
 * pre_enable; the MAC HS request precedes the bridge's video enable. The
 * bridge callbacks are void, so the shared status carries their result.
 */
static int sophgo_start(struct sophgo_dsi *dsi)
{
	int ret;

	if (sophgo_owned(dsi))
		return -EBUSY;
	memset(&dsi->status, 0, sizeof(dsi->status));
	ret = sophgo_prepare(dsi);
	lt8912b_pipeline_error(&dsi->status, "clocks and PHY", ret);
	if (ret)
		goto fail;
	sophgo_display_start(dsi);
	dsi->display_on = true;
	dsi->status.host_prepared = true;
	drm_bridge_chain_mode_set(dsi->bridge, &sophgo_720p, &sophgo_720p);
	drm_atomic_bridge_chain_pre_enable(dsi->bridge, NULL);
	if (dsi->status.error)
		goto fail;
	ret = sophgo_mac_start(dsi);
	lt8912b_pipeline_error(&dsi->status, "MAC start", ret);
	if (ret)
		goto fail;
	dsi->status.host_started = true;
	drm_atomic_bridge_chain_enable(dsi->bridge, NULL);
	if (!dsi->status.error && !dsi->status.started)
		lt8912b_pipeline_error(&dsi->status, "bridge did not start", -EIO);
	if (dsi->status.error)
		goto fail;
	dev_info(dsi->dev, "pattern started: MAC_EN=%#x\n", dsi->mac_en);
	return 0;
fail:
	sophgo_stop(dsi);
	return dsi->status.error;
}

/* No forced reset or clock removal is known to be safe after an
 * unacknowledged stop. Keep every resource and this context alive until a
 * person power-cycles the board; the status line stays readable.
 */
static void __noreturn sophgo_quarantine(struct sophgo_dsi *dsi)
{
	DECLARE_COMPLETION_ONSTACK(physical_recovery);

	dsi->terminal = true;
	dev_crit(dsi->dev, "display pipeline held after a failed stop; physical recovery required\n");
	mutex_unlock(&dsi->lock);
	for (;;)
		wait_for_completion(&physical_recovery);
}

static ssize_t pinstripe_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct sophgo_dsi *dsi = dev_get_drvdata(dev);
	ssize_t ret;

	mutex_lock(&dsi->lock);
	/* mac is the MAC_EN mode field last observed: 0x4 means video acknowledged. */
	ret = sysfs_emit(buf, "terminal=%u started=%u owned=%u mac=%#x stage=%s error=%d\n",
			 dsi->terminal, dsi->status.started, sophgo_owned(dsi), dsi->mac_en & 0xf,
			 dsi->status.stage ?: "idle", dsi->status.error);
	mutex_unlock(&dsi->lock);
	return ret;
}

static ssize_t pinstripe_store(struct device *dev, struct device_attribute *attr,
			       const char *buf, size_t count)
{
	struct sophgo_dsi *dsi = dev_get_drvdata(dev);
	bool start = sysfs_streq(buf, "start");
	int ret;

	if (!start && !sysfs_streq(buf, "stop"))
		return -EINVAL;
	mutex_lock(&dsi->lock);
	if (dsi->terminal || !dsi->peripheral)
		ret = -ENODEV;
	else
		ret = start ? sophgo_start(dsi) : sophgo_stop(dsi);
	mutex_unlock(&dsi->lock);
	return ret ?: count;
}
static DEVICE_ATTR_RW(pinstripe);

static struct attribute *sophgo_attrs[] = { &dev_attr_pinstripe.attr, NULL };
ATTRIBUTE_GROUPS(sophgo);

static const struct drm_encoder_funcs sophgo_encoder_funcs = {
	.destroy = drm_encoder_cleanup,
};

/* The bridge attaches during its own probe, after drm_bridge_add(); the host
 * must not look for it earlier. Linux 7.2.2 lontium-lt8912b.c registers type
 * "lt8912" with four lanes, RGB888 and VIDEO | LPM | NO_HFP | NO_EOT_PACKET.
 * Only that peripheral is accepted; it needs no DSI command transfers.
 */
static int sophgo_dsi_attach(struct mipi_dsi_host *host, struct mipi_dsi_device *device)
{
	struct sophgo_dsi *dsi = host_to_dsi(host);
	struct i2c_client *client;
	struct device_link *link;
	int ret;

	if (strcmp(device->name, "lt8912") || device->lanes != 4 ||
	    device->format != MIPI_DSI_FMT_RGB888 || !(device->mode_flags & MIPI_DSI_MODE_VIDEO))
		return -EINVAL;
	mutex_lock(&dsi->lock);
	if (dsi->peripheral) {
		ret = -EBUSY;
		goto unlock;
	}
	dsi->bridge = of_drm_find_and_get_bridge(dsi->bridge_node);
	if (!dsi->bridge) {
		ret = -EPROBE_DEFER;
		goto unlock;
	}
	/* Unbind the I2C consumer, and with it this attachment, before the
	 * host is removed; otherwise host removal unregisters a DSI child the
	 * bridge's devres still owns.
	 */
	client = of_find_i2c_device_by_node(dsi->bridge_node);
	if (!client) {
		ret = -EPROBE_DEFER;
		goto put_bridge;
	}
	link = device_link_add(&client->dev, dsi->dev, DL_FLAG_AUTOREMOVE_CONSUMER);
	put_device(&client->dev);
	if (!link) {
		ret = -ENOMEM;
		goto put_bridge;
	}
	ret = drm_encoder_init(&dsi->drm, &dsi->encoder, &sophgo_encoder_funcs,
			       DRM_MODE_ENCODER_DSI, NULL);
	if (ret)
		goto unlink;
	ret = drm_bridge_attach(&dsi->encoder, dsi->bridge, NULL, DRM_BRIDGE_ATTACH_NO_CONNECTOR);
	if (ret) {
		drm_encoder_cleanup(&dsi->encoder);
		goto unlink;
	}
	lt8912b_pipeline_bind(dsi->bridge, &dsi->status);
	dsi->peripheral = device;
	goto unlock;
unlink:
	device_link_del(link);
put_bridge:
	drm_bridge_put(dsi->bridge);
	dsi->bridge = NULL;
unlock:
	mutex_unlock(&dsi->lock);
	return ret;
}

static int sophgo_dsi_detach(struct mipi_dsi_host *host, struct mipi_dsi_device *device)
{
	struct sophgo_dsi *dsi = host_to_dsi(host);

	mutex_lock(&dsi->lock);
	if (dsi->peripheral != device) {
		mutex_unlock(&dsi->lock);
		return -EINVAL;
	}
	if (dsi->terminal || (sophgo_owned(dsi) && sophgo_stop(dsi)))
		sophgo_quarantine(dsi);
	lt8912b_pipeline_bind(dsi->bridge, NULL);
	drm_encoder_cleanup(&dsi->encoder);
	drm_bridge_put(dsi->bridge);
	dsi->bridge = NULL;
	dsi->peripheral = NULL;
	mutex_unlock(&dsi->lock);
	return 0;
}

static ssize_t sophgo_dsi_transfer(struct mipi_dsi_host *host, const struct mipi_dsi_msg *msg)
{
	return -EOPNOTSUPP;
}

static const struct mipi_dsi_host_ops sophgo_dsi_host_ops = {
	.attach = sophgo_dsi_attach,
	.detach = sophgo_dsi_detach,
	.transfer = sophgo_dsi_transfer,
};

static const struct drm_driver sophgo_drm_driver = {
	.driver_features = DRIVER_MODESET,
	.name = "sophgo-dsi",
	.desc = "SG2000 DSI host (bridge chain only, never registered)",
};

static void sophgo_clk_put(void *clk)
{
	clk_put(clk);
}

/* clk_bt_vip is an AXI gate beside the display gates that the vendor kernel
 * leaves running and mainline's clk_disable_unused turns off; the vendor
 * mipi_tx node lists it as clk_bt. The board DT does not, so resolve it from
 * the host's own clock provider by binding id and check the name.
 */
static int sophgo_bt_clock_get(struct sophgo_dsi *dsi)
{
	struct of_phandle_args args;
	struct clk *clk;
	int ret;

	ret = of_parse_phandle_with_args(dsi->dev->of_node, "clocks", "#clock-cells", 0, &args);
	if (ret)
		return ret;
	if (args.args_count != 1) {
		of_node_put(args.np);
		return -EINVAL;
	}
	args.args[0] = SOPHGO_CLK_BT_VIP;
	clk = of_clk_get_from_provider(&args);
	of_node_put(args.np);
	if (IS_ERR(clk))
		return PTR_ERR(clk);
	if (!__clk_get_name(clk) || strcmp(__clk_get_name(clk), "clk_bt_vip")) {
		clk_put(clk);
		return -ENODEV;
	}
	dsi->bt = clk;
	return devm_add_action_or_reset(dsi->dev, sophgo_clk_put, clk);
}

static int sophgo_dsi_probe(struct platform_device *pdev)
{
	static const struct {
		const char *name;
		resource_size_t size;
	} windows[] = { { "sc_top", 0x74 }, { "disp", 0xc4 }, { "dsi_mac", 0x0c }, { "dphy", 0xcc } };
	struct device *dev = &pdev->dev;
	struct sophgo_dsi *dsi;
	void __iomem **maps[4];
	unsigned int i;
	int ret;

	dsi = devm_drm_dev_alloc(dev, &sophgo_drm_driver, struct sophgo_dsi, drm);
	if (IS_ERR(dsi))
		return PTR_ERR(dsi);
	dsi->dev = dev;
	mutex_init(&dsi->lock);
	platform_set_drvdata(pdev, dsi);
	ret = drmm_mode_config_init(&dsi->drm);
	if (ret)
		return ret;

	maps[0] = &dsi->top;
	maps[1] = &dsi->disp;
	maps[2] = &dsi->mac;
	maps[3] = &dsi->phy;
	for (i = 0; i < ARRAY_SIZE(windows); i++) {
		struct resource *res = platform_get_resource_byname(pdev, IORESOURCE_MEM,
								   windows[i].name);

		if (!res || resource_size(res) < windows[i].size)
			return dev_err_probe(dev, -EINVAL, "%s window missing or short\n",
					     windows[i].name);
		*maps[i] = devm_ioremap_resource(dev, res);
		if (IS_ERR(*maps[i]))
			return PTR_ERR(*maps[i]);
	}
	/* The VIP window is shared with capture: only the syscon's regmap
	 * touches it, and its CLK_CFG_REG_VIP reference gates every access.
	 */
	dsi->vip = syscon_regmap_lookup_by_phandle(dev->of_node, "sophgo,vip-sys");
	if (IS_ERR(dsi->vip))
		return dev_err_probe(dev, PTR_ERR(dsi->vip), "VIP syscon unavailable\n");
	for (i = 0; i < SOPHGO_CLK_COUNT; i++)
		dsi->clocks[i].id = sophgo_clock_names[i];
	ret = devm_clk_bulk_get(dev, SOPHGO_CLK_COUNT, dsi->clocks);
	if (ret)
		return dev_err_probe(dev, ret, "display clocks unavailable\n");
	dsi->esc_parent = devm_clk_get(dev, "esc_parent");
	if (IS_ERR(dsi->esc_parent))
		return PTR_ERR(dsi->esc_parent);
	ret = sophgo_bt_clock_get(dsi);
	if (ret)
		return dev_err_probe(dev, ret, "clk_bt_vip unavailable\n");
	dsi->bridge_node = of_graph_get_remote_node(dev->of_node, 0, -1);
	if (!dsi->bridge_node)
		return dev_err_probe(dev, -ENODEV, "no bridge on port 0\n");
	dsi->host.dev = dev;
	dsi->host.ops = &sophgo_dsi_host_ops;
	ret = mipi_dsi_host_register(&dsi->host);
	if (ret)
		of_node_put(dsi->bridge_node);
	return ret;
}

static void sophgo_dsi_remove(struct platform_device *pdev)
{
	struct sophgo_dsi *dsi = platform_get_drvdata(pdev);

	mipi_dsi_host_unregister(&dsi->host);
	of_node_put(dsi->bridge_node);
}

static void sophgo_dsi_shutdown(struct platform_device *pdev)
{
	struct sophgo_dsi *dsi = platform_get_drvdata(pdev);

	mutex_lock(&dsi->lock);
	if (dsi->peripheral && (dsi->terminal || (sophgo_owned(dsi) && sophgo_stop(dsi))))
		sophgo_quarantine(dsi);
	mutex_unlock(&dsi->lock);
}

/* System sleep is not handled: refusing it keeps the bridge from resuming
 * on its own ahead of the host.
 */
static int sophgo_dsi_suspend(struct device *dev)
{
	return -EOPNOTSUPP;
}

static const struct dev_pm_ops sophgo_dsi_pm = {
	.suspend = sophgo_dsi_suspend,
	.freeze = sophgo_dsi_suspend,
	.poweroff = sophgo_dsi_suspend,
};

static const struct of_device_id sophgo_dsi_of_match[] = {
	{ .compatible = "sophgo,sg2000-dsi" },
	{}
};
MODULE_DEVICE_TABLE(of, sophgo_dsi_of_match);

static struct platform_driver sophgo_dsi_platform_driver = {
	.probe = sophgo_dsi_probe,
	.remove = sophgo_dsi_remove,
	.shutdown = sophgo_dsi_shutdown,
	.driver = {
		.name = "sophgo-dsi",
		.dev_groups = sophgo_groups,
		.pm = &sophgo_dsi_pm,
		.of_match_table = sophgo_dsi_of_match,
	},
};
module_platform_driver(sophgo_dsi_platform_driver);

MODULE_DESCRIPTION("Sophgo SG2000 DSI host with a manual test-pattern path");
MODULE_AUTHOR("BadgeOS contributors");
MODULE_LICENSE("GPL");
