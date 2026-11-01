/*
 * dsiup - bring the SG2000 DSI link up through the forward-ported vendor
 * mipi_tx driver, the same way the vendor's sample_dsi does.
 *
 * sample_dsi is middleware-linked and not available on NixOS, but all it does
 * for a panel is SET_DEV_CFG (which programs the D-PHY lanes + PLL, the DISP
 * timing and the DSI MAC in one go) followed by enable (DSI MAC -> HS).
 * This is that, with the LT9611_1280x720_60HZ profile inlined.
 *
 * Build: aarch64 (and riscv64) freestanding userspace, no vendor headers.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdbool.h>
#include <sys/ioctl.h>

#define MIPI_TX_NAME "/dev/cvi-mipi-tx"
#define LANE_MAX_NUM 5

enum output_mode_e { OUTPUT_MODE_CSI = 0, OUTPUT_MODE_DSI_VIDEO = 1, OUTPUT_MODE_DSI_CMD = 2 };
enum video_mode_e  { BURST_MODE = 0, NON_BURST_MODE_SYNC_PULSES = 1, NON_BURST_MODE_SYNC_EVENTS = 2 };
enum output_format_e { OUT_FORMAT_RGB_16_BIT = 0, OUT_FORMAT_RGB_18_BIT, OUT_FORMAT_RGB_24_BIT,
		       OUT_FORMAT_RGB_30_BIT };
enum mipi_tx_lane_id { MIPI_TX_LANE_CLK = 0, MIPI_TX_LANE_0, MIPI_TX_LANE_1,
		       MIPI_TX_LANE_2, MIPI_TX_LANE_3, MIPI_TX_LANE_MAX };

struct sync_info_s {
	unsigned short vid_hsa_pixels, vid_hbp_pixels, vid_hfp_pixels, vid_hline_pixels;
	unsigned short vid_vsa_lines, vid_vbp_lines, vid_vfp_lines, vid_active_lines;
	unsigned short edpi_cmd_size;
	bool vid_vsa_pos_polarity, vid_hsa_pos_polarity;
};

struct combo_dev_cfg_s {
	unsigned int devno;
	enum mipi_tx_lane_id lane_id[LANE_MAX_NUM];
	enum output_mode_e output_mode;
	enum video_mode_e video_mode;
	enum output_format_e output_format;
	struct sync_info_s sync_info;
	unsigned int phy_data_rate;
	unsigned int pixel_clk;
	bool lane_pn_swap[LANE_MAX_NUM];
};

struct hs_settle_s { unsigned char prepare, zero, trail; };

#define M 't'
#define CVI_VIP_MIPI_TX_SET_DEV_CFG   _IOW(M, 0x01, struct combo_dev_cfg_s)
#define CVI_VIP_MIPI_TX_GET_DEV_CFG   _IOWR(M, 0x01, struct combo_dev_cfg_s)
#define CVI_VIP_MIPI_TX_ENABLE        _IO(M, 0x03)
#define CVI_VIP_MIPI_TX_DISABLE       _IO(M, 0x05)
#define CVI_VIP_MIPI_TX_SET_HS_SETTLE _IOW(M, 0x06, struct hs_settle_s)

/*
 * 1280x720@60, 74.25 MHz, RGB888.
 *
 * vid_hline_pixels is the active width, not htotal: the driver's
 * _fill_disp_timing() computes htotal = hsa + hbp + hline + hfp - 1, and
 * sclr_dsi_config() takes hline as the DSI long-packet width.
 *
 * Both polarities are false on purpose. The vendor's own LT9611 profile sets
 * them, which leaves DISP_CFG bits 5/6 (VS_POL|HS_POL) set, and the LT8912B
 * is programmed positive-sync (0x48:0xab = 0x03), so inverted sync makes the
 * bridge sample the blanking interval as active video and emit a uniform
 * black at an otherwise valid 720p60 lock. That was the bug.
 */
static struct combo_dev_cfg_s cfg_720p60 = {
	.devno = 0,
	.output_mode = OUTPUT_MODE_DSI_VIDEO,
	.video_mode = BURST_MODE,
	.output_format = OUT_FORMAT_RGB_24_BIT,
	.sync_info = {
		.vid_hsa_pixels = 40,  .vid_hbp_pixels = 220,
		.vid_hfp_pixels = 110, .vid_hline_pixels = 1280,
		.vid_vsa_lines = 5,    .vid_vbp_lines = 20,
		.vid_vfp_lines = 5,    .vid_active_lines = 720,
		.vid_vsa_pos_polarity = false, .vid_hsa_pos_polarity = false,
	},
	.pixel_clk = 74250,
};

static void usage(void)
{
	fprintf(stderr,
		"usage: dsiup [--lanes 2|4] [--vpol 0|1] [--hpol 0|1]\n"
		"             [--hs p,z,t] [--disable] [--show]\n");
}

int main(int argc, char **argv)
{
	int fd, i, lanes = 2, rc;
	bool disable = false, show = false;
	struct hs_settle_s hs = { 6, 32, 5 };
	bool set_hs = true;

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--lanes") && i + 1 < argc)
			lanes = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--vpol") && i + 1 < argc)
			cfg_720p60.sync_info.vid_vsa_pos_polarity = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--hpol") && i + 1 < argc)
			cfg_720p60.sync_info.vid_hsa_pos_polarity = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--hs") && i + 1 < argc) {
			unsigned p, z, t;
			if (sscanf(argv[++i], "%u,%u,%u", &p, &z, &t) == 3) {
				hs.prepare = p; hs.zero = z; hs.trail = t;
			}
		} else if (!strcmp(argv[i], "--no-hs"))
			set_hs = false;
		else if (!strcmp(argv[i], "--disable"))
			disable = true;
		else if (!strcmp(argv[i], "--show"))
			show = true;
		else { usage(); return 2; }
	}

	/*
	 * Physical PHY lane -> DSI role. This board only carries D0/D1: the
	 * D2/D3 differential pair measures dead, so 4-lane locks sync and
	 * shows nothing. lane_id[i] is indexed by PHY lane.
	 */
	for (i = 0; i < LANE_MAX_NUM; i++)
		cfg_720p60.lane_id[i] = (enum mipi_tx_lane_id)-1;
	if (lanes == 4) {
		cfg_720p60.lane_id[0] = MIPI_TX_LANE_0;
		cfg_720p60.lane_id[1] = MIPI_TX_LANE_1;
		cfg_720p60.lane_id[2] = MIPI_TX_LANE_CLK;
		cfg_720p60.lane_id[3] = MIPI_TX_LANE_2;
		cfg_720p60.lane_id[4] = MIPI_TX_LANE_3;
	} else {
		cfg_720p60.lane_id[0] = MIPI_TX_LANE_0;
		cfg_720p60.lane_id[1] = MIPI_TX_LANE_1;
		cfg_720p60.lane_id[2] = MIPI_TX_LANE_CLK;
	}
	cfg_720p60.phy_data_rate = cfg_720p60.pixel_clk * 24 / (lanes * 1000);

	fd = open(MIPI_TX_NAME, O_RDWR);
	if (fd < 0) {
		fprintf(stderr, "open %s: %s\n", MIPI_TX_NAME, strerror(errno));
		return 1;
	}

	if (disable) {
		rc = ioctl(fd, CVI_VIP_MIPI_TX_DISABLE);
		printf("DISABLE rc=%d (%s)\n", rc, rc ? strerror(errno) : "ok");
		close(fd);
		return rc ? 1 : 0;
	}

	if (show) {
		struct combo_dev_cfg_s g;

		memset(&g, 0, sizeof(g));
		rc = ioctl(fd, CVI_VIP_MIPI_TX_GET_DEV_CFG, &g);
		if (rc) {
			fprintf(stderr, "GET_DEV_CFG: %s\n", strerror(errno));
			close(fd);
			return 1;
		}
		printf("lanes=[%d %d %d %d %d] mode=%d fmt=%d pixclk=%u\n",
		       g.lane_id[0], g.lane_id[1], g.lane_id[2], g.lane_id[3],
		       g.lane_id[4], g.output_mode, g.output_format, g.pixel_clk);
		printf("hsa=%u hbp=%u hline=%u hfp=%u  vsa=%u vbp=%u vact=%u vfp=%u  pol v=%d h=%d\n",
		       g.sync_info.vid_hsa_pixels, g.sync_info.vid_hbp_pixels,
		       g.sync_info.vid_hline_pixels, g.sync_info.vid_hfp_pixels,
		       g.sync_info.vid_vsa_lines, g.sync_info.vid_vbp_lines,
		       g.sync_info.vid_active_lines, g.sync_info.vid_vfp_lines,
		       g.sync_info.vid_vsa_pos_polarity, g.sync_info.vid_hsa_pos_polarity);
		close(fd);
		return 0;
	}

	rc = ioctl(fd, CVI_VIP_MIPI_TX_SET_DEV_CFG, &cfg_720p60);
	if (rc) {
		fprintf(stderr, "SET_DEV_CFG: %s\n", strerror(errno));
		close(fd);
		return 1;
	}
	printf("SET_DEV_CFG ok (%d data lanes, %u kHz)\n", lanes, cfg_720p60.pixel_clk);

	if (set_hs) {
		rc = ioctl(fd, CVI_VIP_MIPI_TX_SET_HS_SETTLE, &hs);
		printf("SET_HS_SETTLE(%u,%u,%u) rc=%d\n", hs.prepare, hs.zero, hs.trail, rc);
	}

	rc = ioctl(fd, CVI_VIP_MIPI_TX_ENABLE);
	if (rc) {
		fprintf(stderr, "ENABLE: %s\n", strerror(errno));
		close(fd);
		return 1;
	}
	printf("ENABLE ok -- DSI is in HS video mode\n");
	close(fd);
	return 0;
}
