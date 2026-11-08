/*
 * st7701-panel-init - bring up the ST7701 panel (HD228001C31, 368x552, two data lanes)
 * through the vendor mipi_tx driver: reset, SET_DEV_CFG, reset again in LP-11 as the
 * vendor's vo_mipi_tx.c does, the init sequence, then HS video of soph_dispsrc's colour
 * bars.
 *
 * Needs cv181x_mipi_tx with disp_working_bank=1, soph_dispsrc, and debugfs.
 */
#define _DEFAULT_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <gpiod.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

/* /dev/cvi-mipi-tx's ABI, from osdrv's cvi_comm_mipi_tx.h, as in dsiup.c. */
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

struct cmd_info_s {
	unsigned int devno;
	unsigned short data_type, cmd_size;
	unsigned char *cmd;
};

_Static_assert(sizeof(struct combo_dev_cfg_s) == 72, "the vendor's SET_DEV_CFG layout");
_Static_assert(sizeof(struct cmd_info_s) == 16, "the vendor's SET_CMD layout");

#define M 't'
#define CVI_VIP_MIPI_TX_SET_DEV_CFG   _IOW(M, 0x01, struct combo_dev_cfg_s)
#define CVI_VIP_MIPI_TX_SET_CMD       _IOW(M, 0x02, struct cmd_info_s)
#define CVI_VIP_MIPI_TX_ENABLE        _IO(M, 0x03)
#define CVI_VIP_MIPI_TX_DISABLE       _IO(M, 0x05)
#define CVI_VIP_MIPI_TX_SET_HS_SETTLE _IOW(M, 0x06, struct hs_settle_s)

/* The panel's timing: 696x602 total, 75 Hz at 31.424 MHz; D0, clock, D1 on the first
 * three PHY lanes. phy_data_rate stays 0, as in the vendor's own config for this panel. */
static const struct combo_dev_cfg_s cfg_368x552 = {
	.lane_id = { MIPI_TX_LANE_0, MIPI_TX_LANE_CLK, MIPI_TX_LANE_1, -1, -1 },
	.output_mode = OUTPUT_MODE_DSI_VIDEO,
	.video_mode = BURST_MODE,
	.output_format = OUT_FORMAT_RGB_24_BIT,
	.sync_info = {
		.vid_hsa_pixels = 8,   .vid_hbp_pixels = 160,
		.vid_hfp_pixels = 160, .vid_hline_pixels = 368,
		.vid_vsa_lines = 10,   .vid_vbp_lines = 20,
		.vid_vfp_lines = 20,   .vid_active_lines = 552,
		.vid_vsa_pos_polarity = true, .vid_hsa_pos_polarity = false,
	},
	.pixel_clk = 31424,
};

static const struct hs_settle_s hs = { .prepare = 6, .zero = 32, .trail = 1 };

/* The panel's init sequence, from the vendor's dsi_st7701_hd228001c31.h: wait after
 * the command in ms, DSI packet type, payload. */
static const struct panel_command {
	unsigned delay_ms, type, size;
	unsigned char data[17];
} init[] = {
	{ 0, 0x29, 6, { 0xff, 0x77, 0x01, 0x00, 0x00, 0x13 } },
	{ 0, 0x15, 2, { 0xef, 0x08 } },
	{ 0, 0x29, 6, { 0xff, 0x77, 0x01, 0x00, 0x00, 0x10 } },
	{ 0, 0x29, 3, { 0xc0, 0x44, 0x00 } },
	{ 0, 0x29, 3, { 0xc1, 0x0b, 0x02 } },
	{ 0, 0x29, 3, { 0xc2, 0x07, 0x1f } },
	{ 0, 0x15, 2, { 0xcc, 0x10 } },
	{ 0, 0x29, 17, { 0xb0, 0x0f, 0x1e, 0x25, 0x0d, 0x11, 0x06, 0x12, 0x08, 0x08, 0x2a, 0x05, 0x12, 0x10, 0x2b, 0x32, 0x1f } },
	{ 0, 0x29, 17, { 0xb1, 0x0f, 0x1e, 0x25, 0x0d, 0x11, 0x05, 0x12, 0x08, 0x08, 0x2b, 0x05, 0x12, 0x10, 0x2b, 0x32, 0x1f } },
	{ 0, 0x29, 6, { 0xff, 0x77, 0x01, 0x00, 0x00, 0x11 } },
	{ 0, 0x15, 2, { 0xb0, 0x35 } },
	{ 0, 0x15, 2, { 0xb1, 0x45 } },
	{ 0, 0x15, 2, { 0xb2, 0x87 } },
	{ 0, 0x15, 2, { 0xb3, 0x80 } },
	{ 0, 0x15, 2, { 0xb5, 0x80 } },
	{ 0, 0x15, 2, { 0xb7, 0x85 } },
	{ 0, 0x15, 2, { 0xb8, 0x11 } },
	{ 0, 0x15, 2, { 0xbb, 0x03 } },
	{ 0, 0x15, 2, { 0xc0, 0x07 } },
	{ 0, 0x15, 2, { 0xc1, 0x78 } },
	{ 0, 0x15, 2, { 0xc2, 0x78 } },
	{ 100, 0x15, 2, { 0xd0, 0x88 } },
	{ 0, 0x29, 4, { 0xe0, 0x00, 0x00, 0x02 } },
	{ 0, 0x29, 12, { 0xe1, 0x03, 0x30, 0x07, 0x30, 0x02, 0x30, 0x06, 0x30, 0x00, 0x44, 0x44 } },
	{ 0, 0x29, 12, { 0xe2, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 } },
	{ 0, 0x29, 5, { 0xe3, 0x00, 0x00, 0x22, 0x00 } },
	{ 0, 0x29, 3, { 0xe4, 0x22, 0x00 } },
	{ 0, 0x29, 17, { 0xe5, 0x0a, 0x34, 0x30, 0xe0, 0x08, 0x32, 0x30, 0xe0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 } },
	{ 0, 0x29, 5, { 0xe6, 0x00, 0x00, 0x22, 0x00 } },
	{ 0, 0x29, 3, { 0xe7, 0x22, 0x00 } },
	{ 0, 0x29, 17, { 0xe8, 0x09, 0x33, 0x30, 0xe0, 0x07, 0x31, 0x30, 0xe0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 } },
	{ 0, 0x29, 8, { 0xeb, 0x00, 0x01, 0x10, 0x10, 0x11, 0x00, 0x00 } },
	{ 0, 0x29, 17, { 0xed, 0xff, 0xff, 0xf0, 0x45, 0xba, 0x2f, 0xff, 0xff, 0xff, 0xff, 0xf2, 0xab, 0x54, 0x0f, 0xff, 0xff } },
	{ 0, 0x29, 7, { 0xef, 0x08, 0x08, 0x08, 0x45, 0x3f, 0x54 } },
	{ 0, 0x29, 6, { 0xff, 0x77, 0x01, 0x00, 0x00, 0x13 } },
	{ 0, 0x29, 3, { 0xe8, 0x00, 0x0e } },
	{ 120, 0x05, 1, { 0x11 } },
	{ 10, 0x29, 3, { 0xe8, 0x00, 0x0c } },
	{ 0, 0x29, 3, { 0xe8, 0x00, 0x00 } },
	{ 0, 0x29, 6, { 0xff, 0x77, 0x01, 0x00, 0x00, 0x00 } },
	{ 50, 0x05, 1, { 0x29 } },
};

static void sleep_ms(unsigned ms)
{
	struct timespec t = { ms / 1000, ms % 1000 * 1000000L };

	while (nanosleep(&t, &t) && errno == EINTR)
		;
}

static int fail(const char *what)
{
	fprintf(stderr, "st7701-panel-init: %s: %s\n", what, strerror(errno));
	return 1;
}

/* Write one of soph_dispsrc's debugfs controls. */
static int dispsrc(const char *control, const char *value)
{
	char path[64];
	ssize_t n;
	int fd, saved;

	snprintf(path, sizeof(path), "/sys/kernel/debug/soph_dispsrc/%s", control);
	fd = open(path, O_WRONLY | O_CLOEXEC);
	if (fd < 0)
		return -1;
	n = write(fd, value, strlen(value));
	saved = n < 0 ? errno : EIO;
	close(fd);
	errno = saved;
	return n == (ssize_t)strlen(value) ? 0 : -1;
}

/* Pulse lcd-reset (active low): 10 ms in reset, then 120 ms for the ST7701 to wake. */
static int reset_panel(void)
{
	struct gpiod_line_settings *settings = gpiod_line_settings_new();
	struct gpiod_line_config *config = gpiod_line_config_new();
	struct gpiod_line_request *request = NULL;
	struct gpiod_chip *chip = NULL;
	glob_t chips = { 0 };
	unsigned int offset;
	int line = -1, rc = -1;

	if (!settings || !config || glob("/dev/gpiochip*", 0, NULL, &chips))
		goto out;
	for (size_t i = 0; i < chips.gl_pathc && line < 0; i++) {
		if (chip)
			gpiod_chip_close(chip);
		chip = gpiod_chip_open(chips.gl_pathv[i]);
		line = chip ? gpiod_chip_get_line_offset_from_name(chip, "lcd-reset") : -1;
	}
	if (line < 0) {
		errno = ENODEV;
		goto out;
	}
	offset = line;
	gpiod_line_settings_set_direction(settings, GPIOD_LINE_DIRECTION_OUTPUT);
	gpiod_line_settings_set_active_low(settings, true);
	gpiod_line_settings_set_output_value(settings, GPIOD_LINE_VALUE_ACTIVE);
	if (gpiod_line_config_add_line_settings(config, &offset, 1, settings))
		goto out;
	request = gpiod_chip_request_lines(chip, NULL, config);
	if (!request)
		goto out;
	sleep_ms(10);
	rc = gpiod_line_request_set_value(request, offset, GPIOD_LINE_VALUE_INACTIVE);
	sleep_ms(120);
out:
	if (request)
		gpiod_line_request_release(request);
	if (chip)
		gpiod_chip_close(chip);
	if (config)
		gpiod_line_config_free(config);
	gpiod_line_settings_free(settings);
	globfree(&chips);
	return rc;
}

int main(void)
{
	int fd = open("/dev/cvi-mipi-tx", O_RDWR | O_CLOEXEC);

	if (fd < 0)
		return fail("/dev/cvi-mipi-tx");
	/* Stop the DISP and the link, and point the DISP at the pattern generator, which
	 * reads no memory, before SET_DEV_CFG briefly runs the timing. */
	if (dispsrc("tgen", "0") || ioctl(fd, CVI_VIP_MIPI_TX_DISABLE))
		return fail("stop the DISP and the link");
	if (reset_panel())
		return fail("reset the panel");
	if (dispsrc("pattern", "0 7"))
		return fail("select the colour bars");
	if (ioctl(fd, CVI_VIP_MIPI_TX_SET_DEV_CFG, &cfg_368x552) || dispsrc("tgen", "0"))
		return fail("SET_DEV_CFG");
	if (reset_panel())
		return fail("reset the panel in LP-11");
	if (ioctl(fd, CVI_VIP_MIPI_TX_SET_HS_SETTLE, &hs))
		return fail("SET_HS_SETTLE");
	for (size_t i = 0; i < sizeof(init) / sizeof(init[0]); i++) {
		struct cmd_info_s cmd = {
			.data_type = init[i].type,
			.cmd_size = init[i].size,
			.cmd = (unsigned char *)init[i].data,
		};

		if (ioctl(fd, CVI_VIP_MIPI_TX_SET_CMD, &cmd))
			return fail("init sequence");
		sleep_ms(init[i].delay_ms);
	}
	if (ioctl(fd, CVI_VIP_MIPI_TX_ENABLE) || dispsrc("tgen", "1"))
		return fail("HS video");
	puts("st7701-panel-init: 368x552 at 75 Hz, colour bars");
	return 0;
}
