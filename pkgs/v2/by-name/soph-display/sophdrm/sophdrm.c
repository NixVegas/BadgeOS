// SPDX-License-Identifier: GPL-2.0
/*
 * soph_drm: a DRM/KMS front end for the cvitek VIP display block.
 *
 * Why this exists.
 *
 * The badge drives HDMI through the forward-ported vendor VIP stack
 * (cv181x_vpss/vo/mipi_tx + soph_dispsrc), which works: DSI D-PHY in HS, MAC
 * in video mode, LT8912B locked at DT 0x3e, clean 720p60. But it is a private
 * ioctl/debugfs interface, so nothing that speaks KMS (a Wayland compositor,
 * modetest, anything) can put a pixel on it. There is no /dev/dri node for
 * the HDMI path at all.
 *
 * Mainline has no display driver for this SoC. Not "an incomplete one": there
 * is no CV18xx/SG200x DRM driver in-tree, on dri-devel, in Armbian, or in
 * Sophgo's own 6.x trees. The one serious attempt (a sibling tree's
 * `sophgo-dsi`, a proper from-scratch DSI host + KMS driver) is stuck at the
 * DSI MAC's high-speed entry: `MAC start error=-110`, MAC_EN never sets.
 *
 * This driver takes the other route. It does not re-derive the DSI bring-up,
 * because the vendor stack already does that correctly on this board. It
 * layers KMS on top of the hardware state the vendor stack has already
 * established, and drives only the DISP's two pixel paths, the video layer
 * and the GOP overlay. Everything hard (PLL, D-PHY, DSI MAC, bridge, DISP
 * timing) is left exactly as the vendor drivers left it.
 *
 * So: load the display stack (soph-display-load-display), then load this. The
 * mode we advertise is whatever sclr_disp_get_hw_timing() reports the hardware
 * is actually running. We never program timing, never touch tgen, and cannot
 * hang the DSI link, because we never write to it.
 *
 * Two modes, one per pixel path.
 *
 * The DISP block has two pixel paths, and the connector offers one mode on
 * each. Both modes run the same 1280x720p60 line, so a switch between them
 * reprograms the pixel paths and leaves the timing generator and the DSI link
 * alone. The monitor still re-syncs on a switch: the LT8912B driver resets
 * its MIPI receiver on every enable, and that alone blanks the sink for about
 * two seconds.
 *
 *   1280x720, preferred: the video layer scans the compositor's buffer 1:1.
 *   Its packed RGB formats are 24bpp only (TRM 19.2.4.2), so this mode takes
 *   DRM_FORMAT_RGB888, which is the vendor's SCL_FMT_BGR_PACKED byte for byte
 *   (B, G, R in memory). The compositor renders straight into the buffer the
 *   display reads, and a page flip is an address write that latches at the
 *   next frame start. It also takes NV12, so a client's video frame can be
 *   scanned out as it is; the layer's input CSC turns it into RGB.
 *
 *   640x360: the GOP overlay, doubled by its own 2x scaler. The GOP blanks the
 *   whole output above about 1024 source pixels per line, so it cannot carry
 *   the full width itself. It takes XRGB8888 and ARGB8888 and blends on
 *   per-pixel alpha, see soph_gop_alpha_fill().
 *
 * soph_pipe_check() holds each mode to its formats. A compositor that
 * test-commits its candidate formats, as wlroots does, lands on RGB888 at
 * 1280x720 and on XRGB8888 at 640x360 with no policy of its own. Its own
 * render buffer is never NV12, which only reaches the plane as a client
 * buffer scanned out directly.
 */
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/property.h>
#include <linux/dma-mapping.h>
#include <linux/hrtimer.h>
#include <linux/ktime.h>

#include <drm/drm_atomic_helper.h>
#include <drm/drm_color_mgmt.h>
#include <drm/drm_drv.h>
#include <drm/drm_fb_dma_helper.h>
#include <drm/drm_fourcc.h>
#include <drm/drm_framebuffer.h>
#include <drm/drm_gem_dma_helper.h>
#include <drm/drm_gem_framebuffer_helper.h>
#include <drm/drm_managed.h>
#include <drm/drm_modeset_helper_vtables.h>
#include <drm/drm_print.h>
#include <drm/drm_probe_helper.h>
#include <drm/drm_simple_kms_helper.h>
#include <drm/drm_vblank.h>
#include <drm/drm_bridge.h>
#include <drm/drm_of.h>
#include <drm/drm_mipi_dsi.h>

#include "scaler.h"
#include <linux/cvi_comm_mipi_tx.h>

/* The GOP instance/layer/window the vendor fbdev uses, mirrored exactly.
 * cvifb drives SCL_GOP_DISP layer 1 overlay window 0; that combination is
 * known to paint on this hardware, so it is not a free choice. */
#define SOPH_GOP_LAYER	1
#define SOPH_GOP_OW	0

/*
 * Largest source line the DISP GOP will fetch, in pixels. Above this the
 * overlay does not degrade, it blanks the entire display output. 1024 is
 * measured good and 1152 measured bad on badge #1; the exact cutoff between
 * them is not known, so take the value that is known to work.
 */
#define SOPH_GOP_MAX_SRC_W	1024

/*
 * Where the video layer reads while it is hidden: the 80x80 reset geometry,
 * RGB888 lines padded to the DISP's 32-byte stride. See soph_video_park().
 */
#define SOPH_PARK_W		80
#define SOPH_PARK_H		80
#define SOPH_PARK_PITCH		ALIGN(SOPH_PARK_W * 3, 32)

/* 1 when the GOP's 2x scaler is doubling our half-resolution scanout. */
static u8 soph_gop_scale;

/*
 * Compositor frame-rate divisor. The poller sees each of the panel's 60 Hz
 * frame starts; reporting only every Nth to DRM paces the compositor to
 * 60/N Hz. Every frame a compositor renders is DDR traffic racing the DISP's
 * scanout read, so this is the lever for a display that starves under a busy
 * client. 1 = 60 Hz (no cap). Writable at runtime
 * (/sys/module/soph_drm/parameters/vbl_div) so the stable point can be dialled
 * in without a rebuild.
 */
static unsigned int vbl_div = 1;
module_param(vbl_div, uint, 0644);
MODULE_PARM_DESC(vbl_div,
		 "report vblank to the compositor every Nth real frame (1=60Hz, 2=30Hz, 3=20Hz)");

/*
 * Exported by cv181x_vpss via patches/scaler-disp-frame-start-poll.patch; the
 * vendor ships no header for it. True when the DISP has started a frame since
 * the last call.
 */
bool sclr_disp_frame_start_poll(void);

/*
 * Send limited-range RGB (16..235) instead of full range.
 *
 * The badge's HDMI link has little margin, and full-swing content breaks it:
 * two or more near-white pixels beside near-black on one line (sway's I-beam
 * cursor, black-on-white text) shift the rest of the frame sideways or blank
 * the monitor. It is analog and content-dependent, not a pipeline fault:
 * whether a pattern fails depends on what precedes it on the line, the bridge's
 * TX analog settings move it, and the same pattern can pass one run and fail
 * the next. Compressing the output to 16..235 removed it on badge #1 for the
 * cursor, a black-on-white terminal and every synthetic trigger found.
 *
 * It is also what a CE mode like 720p calls for: the bridge's AVI infoframe
 * leaves the quantization range at default, which for a CE video format
 * means limited. A sink that treats the input as full range shows blacks at
 * 16 and whites at 235. Writable at runtime; takes effect on the next enable.
 */
static bool rgb_limited = true;
module_param(rgb_limited, bool, 0644);
MODULE_PARM_DESC(rgb_limited,
		 "send limited-range RGB (16..235); full range breaks the badge's HDMI link on high-contrast edges");

/* Exported by cv181x_vpss via patches/scaler-disp-out-csc-matrix.patch. */
void sclr_disp_set_out_csc_matrix(const struct sclr_csc_matrix *cfg);

/* 0..255 -> 16..235 on each channel: 219/255 in Q10, plus 16. */
static const struct sclr_csc_matrix soph_rgb_limited_csc = {
	.coef = {
		{ 879, 0, 0 },
		{ 0, 879, 0 },
		{ 0, 0, 879 },
	},
	.add = { 16, 16, 16 },
};

/* A module parameter that takes one of a fixed set of names. */
struct soph_choice {
	const char * const *names;
	unsigned int count;
	unsigned int value;
};

static int soph_choice_set(const char *val, const struct kernel_param *kp)
{
	struct soph_choice *c = kp->arg;
	int i = __sysfs_match_string(c->names, c->count, val);

	if (i < 0)
		return i;
	WRITE_ONCE(c->value, i);
	return 0;
}

static int soph_choice_get(char *buf, const struct kernel_param *kp)
{
	const struct soph_choice *c = kp->arg;

	return scnprintf(buf, PAGE_SIZE, "%s\n", c->names[READ_ONCE(c->value)]);
}

static const struct kernel_param_ops soph_choice_ops = {
	.set = soph_choice_set,
	.get = soph_choice_get,
};

/*
 * The YCbCr encoding and range of NV12 buffers. "auto" takes the plane's
 * COLOR_ENCODING and COLOR_RANGE; anything else overrides them. wlroots never
 * sets those properties, so under a compositor the plane stays at the KMS
 * default, BT.601 limited range, and a client whose frames are something else
 * says so here instead. Read on every NV12 flip.
 */
enum { SOPH_YUV_AUTO, SOPH_YUV_BT601, SOPH_YUV_BT709 };
static const char * const soph_yuv_encodings[] = { "auto", "bt601", "bt709" };
static struct soph_choice yuv_encoding = {
	soph_yuv_encodings, ARRAY_SIZE(soph_yuv_encodings), SOPH_YUV_AUTO,
};
module_param_cb(yuv_encoding, &soph_choice_ops, &yuv_encoding, 0644);
MODULE_PARM_DESC(yuv_encoding,
		 "YCbCr encoding of NV12 buffers: auto (the plane's COLOR_ENCODING), bt601 or bt709");

enum { SOPH_RANGE_AUTO, SOPH_RANGE_LIMITED, SOPH_RANGE_FULL };
static const char * const soph_yuv_ranges[] = { "auto", "limited", "full" };
static struct soph_choice yuv_range = {
	soph_yuv_ranges, ARRAY_SIZE(soph_yuv_ranges), SOPH_RANGE_AUTO,
};
module_param_cb(yuv_range, &soph_choice_ops, &yuv_range, 0644);
MODULE_PARM_DESC(yuv_range,
		 "YCbCr range of NV12 buffers: auto (the plane's COLOR_RANGE), limited or full");

/*
 * The video layer's input CSC for an NV12 plane state.
 *
 * The vendor's csc_mtrx names its YUV->RGB ranges the wrong way round: the
 * *_LIMIT_YUV2RGB entries take Y as it is, which is the full-range formula,
 * and the *_FULL_YUV2RGB entries scale Y - 16 by 255/219, which is limited
 * range. So limited range maps to *_FULL_YUV2RGB and full to *_LIMIT_YUV2RGB.
 */
static enum sclr_csc soph_yuv_csc(const struct drm_plane_state *s)
{
	bool bt709 = s->color_encoding == DRM_COLOR_YCBCR_BT709;
	bool full = s->color_range == DRM_COLOR_YCBCR_FULL_RANGE;

	switch (READ_ONCE(yuv_encoding.value)) {
	case SOPH_YUV_BT601:
		bt709 = false;
		break;
	case SOPH_YUV_BT709:
		bt709 = true;
		break;
	}
	switch (READ_ONCE(yuv_range.value)) {
	case SOPH_RANGE_LIMITED:
		full = false;
		break;
	case SOPH_RANGE_FULL:
		full = true;
		break;
	}

	if (bt709)
		return full ? SCL_CSC_709_LIMIT_YUV2RGB : SCL_CSC_709_FULL_YUV2RGB;
	return full ? SCL_CSC_601_LIMIT_YUV2RGB : SCL_CSC_601_FULL_YUV2RGB;
}

/*
 * Exported by cv181x_vpss (scaler.c, EXPORT_SYMBOL_GPL). Programs the DDR
 * controller for a 250ns soft timeout on display (OSD) reads, 0x08004544 =
 * 0x01110e00, 0x08004548 = 0, so the DISP DMA is serviced ahead of CPU
 * traffic under contention. The vendor comments it as called "in _fb_enable
 * functions" but nothing in the tree actually calls it; our forward-port never
 * did either, which is why the DISP FIFO periodically starves (lb_empty) at
 * native 1280x720 even with vip_axi_realtime_fab_priority() applied. The
 * fabric priority orders VIP's own ports; this is the DDR-controller side.
 */
void _ddr_ctrl_patch(bool enable);

/*
 * Also exported by cv181x_vpss (scaler.c, EXPORT_SYMBOL_GPL). Sets the VIP
 * subsystem's AXI-fabric master priority (0x0A0C8070 = 0x1032AA0F) so the
 * DISP read wins arbitration IN the VIP fabric, the fabric-side companion
 * to _ddr_ctrl_patch's DDR-controller-side soft deadline. The two levers are
 * separate hardware: _ddr_ctrl_patch only touches the OSD port at the DDR
 * controller (0x08004544), which does nothing for the video-layer scanout
 * read the native path uses. The vendor VO calls this during its own init;
 * soph_drm drives the DISP directly and never did, which is why native
 * 1280x720 starves (bw_fail/lb_empty) even with _ddr_ctrl_patch applied.
 * Bandwidth is only ~11-15% of peak here, so this is an arbitration fix, not
 * a bandwidth one. Applied on enable alongside _ddr_ctrl_patch.
 */
void vip_axi_realtime_fab_priority(void);

static bool nomodeset;
module_param(nomodeset, bool, 0444);
MODULE_PARM_DESC(nomodeset, "register the DRM device but never touch the GOP");

/* What is on the DSI link, by device-tree compatible. */
struct soph_profile {
	const struct combo_dev_cfg_s *link;	/* NULL: keep the link as it is */
	int connector_type;
	bool bridge;
	bool gop_mode;
	bool sync_low;		/* force VS/HS active-low in the DISP */
	bool limited_rgb;	/* rgb_limited applies */
	u32 refresh;		/* Hz; the pixel clock cannot be read back */
	u32 mode_flags;
	u16 width, height;	/* 0: whatever the DISP is running */
};

struct soph_drm {
	struct drm_device drm;
	struct drm_simple_display_pipe pipe;
	struct drm_connector connector;
	const struct soph_profile *profile;

	/* The panel's own mode, which the video layer scans 1:1, and the
	 * half-size mode the GOP's 2x scaler doubles; see soph_read_mode(). */
	struct drm_display_mode native_mode, gop_mode;
	/* The video layer, not the GOP, carries the plane since the last
	 * enable. */
	bool video_layer;
	/* A small black buffer of our own for the hidden video layer. */
	dma_addr_t park_dma;
	/*
	 * What the video layer was last given through sclr_disp_set_layer(),
	 * so a flip that changes none of it writes only the addresses; see
	 * soph_video_stage(). layer_fmt is SCL_FMT_MAX when nothing is known.
	 */
	enum sclr_format layer_fmt;
	enum sclr_csc layer_csc;
	u16 layer_pitch_y, layer_pitch_c;

	/* Vblank, polled.
	 *
	 * The real source is the CVI_VIP_SCL interrupt (GIC 41), but
	 * cv181x_vpss owns that handler and exports no hook to chain onto. So
	 * an hrtimer polls the raw DISP frame-start status several times a
	 * frame and reports a vblank for each frame start it sees. */
	struct hrtimer vbl_timer;
	ktime_t vbl_period;
	ktime_t poll_period;	/* vbl_period / SOPH_VBL_OVERSAMPLE */
	bool vbl_enabled;

	/* Latch for soph_check_underrun(), so a starving display logs on the
	 * transition rather than every single frame. */
	bool starving;
	/* The same for the chroma line-buffer flags of an NV12 layer. */
	bool chroma_bad;
	/* The chroma error bits already latched at the last format change,
	 * which soph_check_underrun() does not report again. */
	u32 chroma_err_old;
	/* A whole layer is staged for the next frame start (layer_staged,
	 * under flip_lock, except at enable, where the poller is stopped
	 * and Linux runs on one CPU), and the frame start the poller just
	 * saw latched one, so the line buffers are refilling (layer_refill,
	 * the poller's own). */
	bool layer_staged;
	bool layer_refill;
	/* The status bits predate this enable; the poller clears them at the
	 * first frame start. See soph_check_underrun(). */
	bool dbg_stale;
	unsigned int vbl_count;
	unsigned int vbl_gate;		/* real vblanks since the last reported one (vbl_div) */

	/*
	 * Page flips.
	 *
	 * Both paths scan the framebuffer itself, the video layer as RGB888 or
	 * NV12 and the GOP as XRGB/ARGB8888, so nothing is converted, the
	 * driver owns no pixel buffers, and a flip is a new scanout address
	 * (plus format, pitches and input CSC when those change).
	 *
	 * A DISP register written with the shadow mask clear sits in the shadow
	 * bank until the next frame start, which copies it into the working
	 * bank; measured on badge #1, a GOP address written 5 ms into a frame
	 * went live exactly at the next frame start. sclr_disp_reg_force_up()
	 * is not a vsync trigger, it copies the shadow bank at once, mid-scan,
	 * and a flip forced that way tears wherever the scanout happens to be.
	 *
	 * So a flip only writes the new address and clears the frame-start
	 * status. The next frame start latches the address; the poller sees
	 * that start and completes the flip then, which is the first moment
	 * the old buffer is no longer being read. Completing it any earlier
	 * hands the compositor a buffer the display is still scanning, and
	 * whatever it redraws next, typically the cursor, tears.
	 *
	 * flip_lock orders a commit's register write and status clear against
	 * the poller, so a frame start the poller reports is always one that
	 * came after the write.
	 */
	spinlock_t flip_lock;
	unsigned int vbl_miss;		/* poll ticks since the last frame start */

	/*
	 * The DSI host this driver presents to the rest of DRM.
	 *
	 * We do not own the DSI MAC registers, cv181x_vpss does, but a
	 * mipi_dsi_host is how a bridge finds its upstream, and it is found by
	 * of_node. Registering one is what lets the mainline lontium-lt8912b
	 * driver bind from the device tree and do the bridge's register
	 * sequence at the right point in the modeset, instead of a shell script
	 * banging i2c at a moment somebody guessed.
	 */
	struct drm_bridge *bridge;
};

static inline struct soph_drm *to_soph(struct drm_device *d)
{
	return container_of(d, struct soph_drm, drm);
}

/*
 * DISP registers are shadowed. DISP_CFG bit18 (SHRD_SEL) selects which bank a
 * CPU *read* sees: 0 = the just-consumed shadow, 1 = the working bank. Every
 * vendor sclr_* helper is a read-modify-write, so with bit18 clear they read
 * zeros and write them back, silently landing fmt=0 and pitch=0. Nothing on
 * mainline sets it, so we do, before touching anything.
 */
static void soph_read_working_bank(void)
{
	sclr_disp_reg_shadow_sel(false);
}

/* vblank */

/* Defined below, next to the other register pokes. */
static void soph_check_underrun(struct soph_drm *sd);

/*
 * Poll ~4x per frame, so a frame start is seen within a quarter frame of it.
 * If none shows for two frames (the timing generator has stopped), report a
 * vblank anyway so the compositor cannot stall.
 */
#define SOPH_VBL_OVERSAMPLE 4

static enum hrtimer_restart soph_vbl_fn(struct hrtimer *t)
{
	struct soph_drm *sd = container_of(t, struct soph_drm, vbl_timer);
	bool vblank = false;

	spin_lock(&sd->flip_lock);
	if (sclr_disp_frame_start_poll()) {
		vblank = true;
		sd->vbl_miss = 0;
		sd->layer_refill = sd->layer_staged;
		sd->layer_staged = false;
		/* The first whole frame since enable starts here. */
		if (sd->dbg_stale) {
			sclr_disp_get_dbg_status(true);
			/* Nothing is latched any more, so nothing is old. */
			sd->chroma_err_old = 0;
			sd->dbg_stale = false;
		}
	} else if (++sd->vbl_miss > 2 * SOPH_VBL_OVERSAMPLE) {
		vblank = true;
		sd->vbl_miss = 0;
	}
	spin_unlock(&sd->flip_lock);

	/*
	 * Complete the armed page flips. Doing that only every vbl_div-th
	 * frame paces the compositor to 60/vbl_div Hz.
	 */
	if (vblank && ++sd->vbl_gate >= (vbl_div ? vbl_div : 1)) {
		sd->vbl_gate = 0;
		drm_crtc_handle_vblank(&sd->pipe.crtc);

		/* Diagnostics roughly once a second. */
		if (++sd->vbl_count >= 60) {
			sd->vbl_count = 0;
			soph_check_underrun(sd);
		}
	}

	hrtimer_forward_now(t, sd->poll_period);
	return HRTIMER_RESTART;
}

static int soph_enable_vblank(struct drm_simple_display_pipe *pipe)
{
	struct soph_drm *sd = to_soph(pipe->crtc.dev);

	sd->vbl_enabled = true;
	hrtimer_start(&sd->vbl_timer, sd->poll_period, HRTIMER_MODE_REL);
	return 0;
}

static void soph_disable_vblank(struct drm_simple_display_pipe *pipe)
{
	struct soph_drm *sd = to_soph(pipe->crtc.dev);

	sd->vbl_enabled = false;
	hrtimer_cancel(&sd->vbl_timer);
}

/* the GOP plane */

/*
 * Force the whole surface opaque.
 *
 * wlroots scans out XRGB8888 for the primary plane (it will not commit an
 * ARGB8888-only plane), and pixman leaves the X byte 0. The GOP blends on
 * per-pixel alpha with no global/opaque mode, so an all-zero alpha composites
 * the whole surface transparent == black (bench 2026-09-20). Set the alpha
 * byte to 0xff. write-only (no read-modify-write, a RMW over a write-combine
 * buffer would be pathologically slow). X is don't-care for the XRGB8888 the
 * compositor rendered, so overwriting it is harmless.
 *
 * The whole buffer, not the commit's damage. KMS damage says what changed on
 * screen since the last flip, but a compositor rotating buffers also repaints
 * whatever changed since it last drew into *this* buffer, and every pixel it
 * repaints comes back with alpha 0. The buffer is not on screen yet, so the
 * fill races nothing; it costs one byte store per pixel at the GOP's 640x360.
 */
static void soph_gop_alpha_fill(struct drm_framebuffer *fb)
{
	struct drm_gem_dma_object *gem;
	unsigned int y, x;

	if (fb->format->format != DRM_FORMAT_XRGB8888)
		return;
	gem = drm_fb_dma_get_gem_obj(fb, 0);
	if (!gem || !gem->vaddr)
		return;

	for (y = 0; y < fb->height; y++) {
		u8 *a = (u8 *)gem->vaddr + fb->offsets[0] +
			(size_t)y * fb->pitches[0] + 3;

		for (x = 0; x < fb->width; x++)
			a[(size_t)x << 2] = 0xffu;
	}
}

/*
 * Point the GOP overlay window at `addr` and size it to `fb`, the same shape
 * as cvifb_pan_display(). The writes land in the DISP shadow bank and go live
 * at the next frame start.
 */
static void soph_gop_set(struct drm_framebuffer *fb, dma_addr_t addr)
{
	struct sclr_gop_ow_cfg ow = {};

	ow.fmt = SCL_GOP_FMT_ARGB8888;
	ow.img_size.w = fb->width;
	ow.img_size.h = fb->height;
	/* mem_size.w is in bytes (cvifb passes the byte pitch here), while
	 * img_size.w is in pixels. Getting these the same way round is what
	 * makes the DMA fetch the right number of bytes per line. */
	ow.mem_size.w = fb->pitches[0];
	ow.mem_size.h = fb->height;
	ow.pitch = fb->pitches[0];
	ow.start.x = 0;
	ow.start.y = 0;
	/*
	 * end is the last covered output pixel, and the overlay is doubled by
	 * the GOP's own 2x scaler, so the window we occupy on screen is twice
	 * the source. This is the vendor's formula from vo_set_rgn_cfg():
	 *
	 *   end = start + (img_size << scl_en) - scl_en
	 *
	 * With soph_gop_scale it degenerates to end = img_size when the scaler
	 * is off, which is what this used to hardcode.
	 */
	ow.end.x = ow.start.x + (ow.img_size.w << soph_gop_scale) - soph_gop_scale;
	ow.end.y = ow.start.y + (ow.img_size.h << soph_gop_scale) - soph_gop_scale;
	ow.crop_pixels = 0;
	ow.addr = addr;

	sclr_gop_ow_set_cfg(SCL_GOP_DISP, SOPH_GOP_LAYER, SOPH_GOP_OW, &ow, true);
}

static void soph_gop_enable(bool on)
{
	struct sclr_gop_cfg *cfg = sclr_gop_get_cfg(SCL_GOP_DISP, SOPH_GOP_LAYER);

	/*
	 * Drive the 2x scaler when the panel is wider than the GOP can fetch.
	 *
	 * The DISP GOP tops out a little over 1024 source pixels per line: a
	 * 1280-wide overlay does not merely get truncated, it takes the whole
	 * display output to black. Measured on badge #1 against a live scroller
	 * underneath, holding everything else constant:
	 *
	 *   1024 px/line  ->  overlay composites (monitor 138.5)
	 *   1152 px/line  ->  black (6.9)
	 *   1280 px/line  ->  black (7.0)
	 *
	 * It is a pixel limit, not a bandwidth one: 1280 at ARGB1555 and at
	 * ARGB4444 (2560 B/line, half of the 1024-px ARGB8888 case that works)
	 * are both black too. Splitting across ow0+ow1 at 640 each does not
	 * help either, the limit is shared across overlay windows, not per
	 * window.
	 *
	 * The way out is the GOP's own 2x scaler: a 640x360 source covers the
	 * full 1280x720 output while fetching only 640 px/line. Verified at
	 * 188.95 mean luma (white test buffer) where 1:1 gave 7.0.
	 */
	cfg->gop_ctrl.b.hscl_en = soph_gop_scale;
	cfg->gop_ctrl.b.vscl_en = soph_gop_scale;
	/* Clear every ow enable, then set only ours. The low byte is the eight
	 * ow0..ow7 enables; leaving a stale one set composites somebody else's
	 * buffer over ours. */
	cfg->gop_ctrl.raw &= ~0xffu;
	cfg->gop_ctrl.b.ow0_en = on ? 1 : 0;
	sclr_gop_set_cfg(SCL_GOP_DISP, SOPH_GOP_LAYER, cfg, true);
}

/*
 * Enabling the overlay is a transition, not a state.
 *
 * Writing ow0_en=1 into a GOP that is already enabled does not latch the new
 * window config: every register reads back correct, FMT, ADDR, H_RANGE,
 * V_RANGE, CROP_PITCH, SIZE, and ow0_en itself, and nothing composites. The
 * video layer underneath stays fully visible, so it looks like the GOP is
 * inert rather than drawing something wrong.
 *
 * The vendor's own fbdev does the off/on cycle and never says why:
 * cvifb.c's _fb_activate_var() calls _fb_enable(false), reprograms, then
 * _fb_enable(true). Measured on badge #1: with the cycle the overlay appears
 * immediately; without it, never.
 */
static void soph_gop_latch(void)
{
	soph_gop_enable(false);
	sclr_disp_reg_force_up();
	soph_gop_enable(true);
}

/* the video layer */

/* True for the panel's own size, the mode the video layer carries. */
static bool soph_mode_is_native(const struct soph_drm *sd,
				const struct drm_display_mode *m)
{
	return m->hdisplay == sd->native_mode.hdisplay &&
	       m->vdisplay == sd->native_mode.vdisplay;
}

/* What the video layer needs to scan a plane state's framebuffer. */
struct soph_layer {
	enum sclr_format fmt;
	enum sclr_csc csc;
	struct sclr_mem mem;
};

/*
 * RGB888 is the vendor's SCL_FMT_BGR_PACKED with the input CSC off. NV12 is
 * SCL_FMT_NV12, U at the lower address as in DRM's NV12: the TRM's
 * reg_fmt_sel table names the same value "NV21 {V,U}", but it lists
 * components MSB first, as its "RGB packed {R,G,B}" for the B-first value 3
 * shows.
 */
static void soph_video_layer(const struct soph_drm *sd,
			     struct drm_plane_state *state,
			     struct soph_layer *l)
{
	struct drm_framebuffer *fb = state->fb;
	bool nv12 = fb->format->format == DRM_FORMAT_NV12;

	memset(l, 0, sizeof(*l));
	l->fmt = nv12 ? SCL_FMT_NV12 : SCL_FMT_BGR_PACKED;
	l->csc = nv12 ? soph_yuv_csc(state) : SCL_CSC_NONE;
	l->mem.addr0 = drm_fb_dma_get_gem_addr(fb, state, 0);
	l->mem.pitch_y = fb->pitches[0];
	if (nv12) {
		l->mem.addr1 = drm_fb_dma_get_gem_addr(fb, state, 1);
		l->mem.pitch_c = fb->pitches[1];
	}
	l->mem.width = sd->native_mode.hdisplay;
	l->mem.height = sd->native_mode.vdisplay;
}

/* The latching chroma error bits of the DISP debug status. */
static const union sclr_disp_dbg_status soph_chroma_errs = {
	.b = { .err_fwr_u = 1, .err_fwr_v = 1, .err_erd_u = 1, .err_erd_v = 1 },
};

static const char *soph_layer_fmt_name(enum sclr_format fmt)
{
	switch (fmt) {
	case SCL_FMT_BGR_PACKED:
		return "RGB888";
	case SCL_FMT_NV12:
		return "NV12";
	default:
		return "none";
	}
}

/* Hand the video layer a whole new layer, landing at one frame start. */
static void soph_video_load(struct soph_drm *sd, const struct soph_layer *l)
{
	if (l->fmt != sd->layer_fmt) {
		drm_dbg_kms(&sd->drm,
			    "video layer %s -> %s, input CSC %d, pitches %u/%u\n",
			    soph_layer_fmt_name(sd->layer_fmt),
			    soph_layer_fmt_name(l->fmt), l->csc,
			    l->mem.pitch_y, l->mem.pitch_c);
		/*
		 * Judge the chroma flags afresh in the new format, without
		 * clearing anything: the write-1-clear would take bw_fail
		 * with it. Errors already latched stay unreported.
		 */
		sd->chroma_bad = false;
		sd->chroma_err_old = sclr_disp_get_dbg_status(false).raw &
				     soph_chroma_errs.raw;
	}
	sclr_disp_set_layer(l->fmt, &l->mem, l->csc);
	sd->layer_fmt = l->fmt;
	sd->layer_csc = l->csc;
	sd->layer_pitch_y = l->mem.pitch_y;
	sd->layer_pitch_c = l->mem.pitch_c;
	sd->layer_staged = true;
}

/*
 * Stage a framebuffer for the next frame start.
 *
 * A flip that keeps the format, the input CSC and the pitches writes only
 * new addresses, through sclr_disp_set_mem(): it rewrites the geometry and
 * pitches unchanged, then the addresses of all planes in one shadow window.
 * Anything else, a flip between RGB888 and NV12 in particular, goes through
 * soph_video_load(), so format, CSC, pitches and addresses all latch at the
 * same frame start and no frame scans one buffer in the other's format.
 */
static void soph_video_stage(struct soph_drm *sd, struct drm_plane_state *state)
{
	struct soph_layer l;

	soph_video_layer(sd, state, &l);
	if (l.fmt == sd->layer_fmt && l.csc == sd->layer_csc &&
	    l.mem.pitch_y == sd->layer_pitch_y &&
	    l.mem.pitch_c == sd->layer_pitch_c)
		sclr_disp_set_mem(&l.mem);
	else
		soph_video_load(sd, &l);
}

/*
 * Park the video layer on the driver's own small buffer while it is hidden.
 *
 * The window background hides the layer but does not stop it: it goes on
 * fetching whatever it was last given, after 1280x720 a whole frame of a
 * buffer the compositor may already have freed, about 166 MB/s of DDR reads
 * that nobody sees. Parked, it fetches under 20 KB a frame instead. 80x80
 * is the reset geometry the GOP path has always run over. Every plane points
 * into the buffer, whichever format is left programmed.
 */
static void soph_video_park(struct soph_drm *sd)
{
	struct sclr_mem mem = {
		.addr0 = sd->park_dma,
		.addr1 = sd->park_dma,
		.addr2 = sd->park_dma,
		.pitch_y = SOPH_PARK_PITCH,
		.pitch_c = SOPH_PARK_PITCH,
		.width = SOPH_PARK_W,
		.height = SOPH_PARK_H,
	};

	sclr_disp_set_mem(&mem);
	/* The pitches and size are the park buffer's now, so the next stage
	 * must load a whole layer. */
	sd->layer_fmt = SCL_FMT_MAX;
}

static void soph_pipe_enable(struct drm_simple_display_pipe *pipe,
			     struct drm_crtc_state *cstate,
			     struct drm_plane_state *pstate)
{
	struct soph_drm *sd = to_soph(pipe->crtc.dev);
	struct drm_framebuffer *fb = pstate->fb;
	unsigned int w = cstate->mode.hdisplay;
	unsigned int h = cstate->mode.vdisplay;
	struct sclr_top_cfg *tcfg;
	struct sclr_disp_cfg *cfg;
	struct soph_layer layer;

	sd->video_layer = soph_mode_is_native(sd, &cstate->mode);

	if (nomodeset)
		goto out;
	if (!fb)
		goto out;

	soph_read_working_bank();

	/*
	 * Give display reads priority so the DISP FIFO stops losing arbitration
	 * to CPU traffic (compositor blit + llvmpipe + Quake). two levers, both
	 * needed for the native video-layer scanout: the VIP AXI fabric master
	 * priority (vip_axi_realtime_fab_priority) and a 250ns soft deadline at
	 * the DDR controller (_ddr_ctrl_patch). soph_drm applied only the latter,
	 * which covers the OSD port and not the video-layer read, so native still
	 * starved; the fabric-priority call is the missing half. Applied on every
	 * enable; deliberately not undone in disable(), like tgen, the display
	 * owns these for as long as it is up.
	 */
	vip_axi_realtime_fab_priority();
	_ddr_ctrl_patch(true);

	if (sd->video_layer) {
		/*
		 * Primary plane = the DISP video layer, scanning the compositor's
		 * RGB888 buffer 1:1, or a client's NV12 one. Field-for-field the
		 * proven sequence from soph_dispsrc's scanout path, with the
		 * layer itself loaded last through soph_video_load().
		 */
		soph_video_layer(sd, pstate, &layer);
		cfg = sclr_disp_get_cfg();
		cfg->disp_from_sc = false;
		cfg->sync_ext = false;
		cfg->tgen_en = true;
		cfg->fmt = layer.fmt;
		cfg->in_csc = layer.csc;
		/*
		 * RGB in (SCL_FMT_BGR_PACKED, or NV12 after the input CSC), RGB
		 * out: the output CSC must be an identity passthrough. SCL_CSC_NONE
		 * is the right request -- BUT the vendor's
		 * sclr_disp_set_out_csc(SCL_CSC_NONE) only `_reg_write(OUT_CSC0,
		 * 0)`, which zeroes coef[0][0] and LEAVES OUT_CSC1..4 / SUB at
		 * whatever the VIP stack last loaded (its BT.601 YUV->RGB matrix
		 * for the video/VO path). The hardware still applies that mangled
		 * matrix, which is the colour shift seen on the native video layer
		 * (register diff vs the GOP overlay path: OUT_CSC0 0x400 vs 0x000,
		 * nothing else differs). Fixed in the vendor function to write a
		 * full identity matrix for NONE -- see disp-out-csc-none-identity
		 * in soph-display's postPatch.
		 */
		cfg->out_csc = SCL_CSC_NONE;
		cfg->burst = 15;
		cfg->out_bit = 8;
		cfg->drop_mode = SCL_DISP_DROP_MODE_DITHER;
		cfg->mem = layer.mem;

		/* Both sit IN front of the scanout; the window background in
		 * particular must be off when the video layer provides pixels. */
		sclr_disp_set_pattern(SCL_PAT_TYPE_OFF, SCL_PAT_COLOR_WHITE, NULL);
		sclr_disp_enable_window_bgcolor(false);
		soph_gop_enable(false);
		sclr_disp_set_cfg(cfg);
		soph_video_load(sd, &layer);
	} else {
		/*
		 * Primary plane = the GOP overlay, scanning the compositor's
		 * XRGB8888 or ARGB8888 buffer directly. The mode is half the
		 * panel each way and the GOP's 2x scaler doubles it back.
		 *
		 * Here the window background must be ON: it is what the DISP
		 * output stage composites the overlay over, and with it off the
		 * stage shows the video layer, which on this path is parked on
		 * an 80x80 buffer (soph_video_park()); it starves and emits
		 * black no matter what the GOP puts on top.
		 */
		soph_gop_scale = 1;

		tcfg = sclr_top_get_cfg();
		tcfg->disp_enable = true;
		sclr_top_set_cfg(tcfg);

		sclr_disp_set_pattern(SCL_PAT_TYPE_OFF, SCL_PAT_COLOR_WHITE, NULL);
		sclr_disp_set_frame_bgcolor(0, 0, 0);
		sclr_disp_set_window_bgcolor(0, 0, 0);
		sclr_disp_enable_window_bgcolor(true);
		soph_video_park(sd);

		soph_gop_alpha_fill(fb);
		wmb();
		soph_gop_set(fb, drm_fb_dma_get_gem_addr(fb, pstate, 0));
		soph_gop_latch();
	}

	/* After the paths above, which leave the output CSC at identity or off. */
	if (rgb_limited && sd->profile->limited_rgb)
		sclr_disp_set_out_csc_matrix(&soph_rgb_limited_csc);

	/*
	 * Own the timing generator. A CRTC that owns the output owns its
	 * timing: when some unrelated vendor producer exits, tgen_en goes to 0,
	 * the DSI stops and the sink reports "No Signal".
	 */
	sclr_disp_tgen_enable(true);
	sclr_disp_reg_force_up();

	/* Judge starvation afresh on this path; see soph_check_underrun(). */
	sd->starving = false;
	sd->chroma_bad = false;
	sd->dbg_stale = true;

	drm_info(&sd->drm, "%s on: %ux%u %p4cc\n",
		 sd->video_layer ? "video layer" : "GOP", w, h,
		 &fb->format->format);
out:
	drm_crtc_vblank_on(&pipe->crtc);
}

static void soph_pipe_disable(struct drm_simple_display_pipe *pipe)
{
	struct soph_drm *sd = to_soph(pipe->crtc.dev);

	drm_crtc_vblank_off(&pipe->crtc);

	if (nomodeset)
		return;

	soph_read_working_bank();
	soph_gop_enable(false);
	/*
	 * Hide and park the video layer as well. It scans the compositor's
	 * own buffer, which can be freed as soon as this commit is done with
	 * it: the window background puts black in front, and parking moves
	 * the reads off that buffer.
	 */
	sclr_disp_set_window_bgcolor(0, 0, 0);
	sclr_disp_enable_window_bgcolor(true);
	soph_video_park(sd);
	sclr_disp_reg_force_up();
	/*
	 * tgen is deliberately left running here even though enable() turns it
	 * on. A CRTC disable is often transient, a modeset, a DPMS blip, a
	 * compositor restart, and dropping the timing generator drops the
	 * DSI link with it, which on this board means the sink resyncs (or
	 * does not). Blanking the pixel paths is enough: with ow0_en clear and
	 * the window background on there is nothing composited, and the link
	 * stays up for whatever comes next.
	 */
}

/*
 * Report DISP starvation, on the transition only.
 *
 * The display DMA shares a 16-bit DDR3 bus (3.73 GB/s theoretical peak, per
 * the SG2000 TRM) with the CPU, gmac0's descriptor rings and everything else
 * on this board. When it loses that race the line buffer runs dry and the
 * picture tears or drops, and the hardware says so in the debug-status
 * register, which beats guessing from a camera pointed at the monitor.
 *
 * Latched, because a persistently starved display would otherwise log every
 * frame. dispsrc.c reads these same bits the same way.
 *
 * Each enable starts from clean status. The flags latch until cleared, and
 * while the GOP carries the plane the video layer is never fed and bw_fail
 * stays set; the video-layer check below never clears it, so a switch from
 * 640x360 to 1280x720 would report the GOP session as starvation. So the
 * poller clears all the flags once, at the first frame start after enable
 * (dbg_stale). The only frame that goes unjudged is the one the enable
 * switched paths in the middle of; a display that really starves latches
 * the flag again on a later frame and is reported within a second.
 *
 * Nothing else on the video-layer path clears them (the GOP branch below
 * clears its own flag on every read). A flip between RGB888 and NV12 is
 * not an enable: it happens on every cursor show and hide, and a clear
 * there would erase a bw_fail before it was ever sampled. It only restarts
 * the chroma judgement, remembering the chroma errors already latched
 * (chroma_err_old).
 */
static void soph_check_underrun(struct soph_drm *sd)
{
	union sclr_disp_dbg_status st;
	bool bad;
	u32 errs;

	if (!sd->video_layer) {
		/*
		 * The GOP has its own flag. The video-layer bits below stay set
		 * on this path because the video layer is never fed, so they
		 * say nothing. Clear the flag on each read so every second
		 * reports its own.
		 */
		st = sclr_disp_get_dbg_status(true);
		bad = st.b.osd_bw_fail;
		if (bad == sd->starving)
			return;
		sd->starving = bad;
		if (bad)
			drm_warn(&sd->drm, "GOP starved (osd_bw_fail) -- DDR contention\n");
		else
			drm_info(&sd->drm, "GOP bandwidth recovered\n");
		return;
	}

	/*
	 * bw_fail is the video layer's flag: its DMA fell behind. clr =
	 * false, because the write-1-clear variant would steal it from
	 * cv181x_vo's own irq handler, which reports "disp bw failed" from
	 * it; so this reports the first occurrence in a session and then
	 * stays quiet.
	 *
	 * lb_empty_* are not a starvation flag. They have no clear bit and
	 * read the line buffers' level at that instant, and the Y buffer runs
	 * empty for about 140 us of every frame even on an idle desktop
	 * (measured on badge #1: 0.7% of samples, about once a frame, bw_fail
	 * never set), so a once-a-second sample of it reports starvation that
	 * is not there. They are printed for context only.
	 */
	st = sclr_disp_get_dbg_status(false);
	bad = st.b.bw_fail;

	if (bad != sd->starving) {
		sd->starving = bad;
		if (bad)
			drm_warn(&sd->drm,
				 "DISP starved (bw_fail %d lb_empty %d%d%d) -- DDR contention\n",
				 st.b.bw_fail, st.b.lb_empty_y, st.b.lb_empty_u,
				 st.b.lb_empty_v);
		else
			drm_info(&sd->drm, "DISP bandwidth recovered\n");
	}

	/*
	 * NV12 also feeds a chroma line buffer, so its flags are judged on an
	 * NV12 layer only: lb_empty at the instant of reading, and the
	 * err_fwr/err_erd errors, which latch like bw_fail.
	 *
	 * An idle line buffer reads empty: packed RGB leaves U and V at
	 * lb_empty 1 on a healthy desktop (DISP_DBG 0x00060000, measured on
	 * badge #1). Under NV12, U carries the interleaved UV plane and reads
	 * 0, while V stays idle and reads 1 at every sample, so lb_empty_v is
	 * printed but not judged. An error that was already latched at the
	 * last format change is not judged either; it was reported, if at
	 * all, when it first appeared.
	 *
	 * Nor is lb_empty_u in a frame that latched a whole new layer: the
	 * line buffers refill from the new planes then, and U reads empty for
	 * a moment that is not an underrun. Under sway that is every cursor
	 * show and hide over a scanned-out NV12 window, so every RGB888-to-NV12
	 * layer write would otherwise warn and then clear. Such a frame says
	 * nothing about lb_empty_u either way, so it leaves the last judgement
	 * alone unless an error has latched.
	 */
	if (sd->layer_fmt != SCL_FMT_NV12)
		return;
	errs = st.raw & soph_chroma_errs.raw & ~sd->chroma_err_old;
	if (sd->layer_refill && !errs)
		return;
	bad = st.b.lb_empty_u || errs;
	if (bad == sd->chroma_bad)
		return;
	sd->chroma_bad = bad;
	if (bad)
		drm_warn(&sd->drm,
			 "DISP chroma: lb_empty_u/v %d%d err_fwr_u/v %d%d err_erd_u/v %d%d\n",
			 st.b.lb_empty_u, st.b.lb_empty_v, st.b.err_fwr_u,
			 st.b.err_fwr_v, st.b.err_erd_u, st.b.err_erd_v);
	else
		drm_info(&sd->drm, "DISP chroma flags clear\n");
}

static void soph_pipe_update(struct drm_simple_display_pipe *pipe,
			     struct drm_plane_state *old)
{
	struct drm_plane_state *state = pipe->plane.state;
	struct drm_crtc *crtc = &pipe->crtc;
	struct soph_drm *sd = to_soph(crtc->dev);
	struct drm_pending_vblank_event *event;
	struct drm_framebuffer *fb = state->fb;
	unsigned long flags;
	bool video_layer;

	/*
	 * The path comes from the mode being committed, not from
	 * sd->video_layer: in a modeset the atomic helpers commit the planes
	 * before they enable the CRTC (drm_atomic_helper_commit_tail), so this
	 * runs ahead of the enable that switches paths.
	 */
	video_layer = soph_mode_is_native(sd, &crtc->state->mode);

	if (fb && !nomodeset) {
		/* Finish the pixels before anything points at them. */
		if (!video_layer)
			soph_gop_alpha_fill(fb);
		wmb();

		/*
		 * Stage the new address, then forget any frame start seen so
		 * far: the next one is the one that latches the address, and
		 * the poller completes the flip when it sees it.
		 */
		spin_lock_irqsave(&sd->flip_lock, flags);
		if (video_layer)
			soph_video_stage(sd, state);
		else
			soph_gop_set(fb, drm_fb_dma_get_gem_addr(fb, state, 0));
		sclr_disp_frame_start_poll();
		spin_unlock_irqrestore(&sd->flip_lock, flags);
	}

	/* Complete the flip at the next vblank when vblanks are running, so
	 * the compositor is paced; send it immediately otherwise, or it would
	 * wait forever. */
	event = crtc->state->event;
	if (!event)
		return;
	crtc->state->event = NULL;

	spin_lock_irq(&crtc->dev->event_lock);
	if (drm_crtc_vblank_get(crtc) == 0)
		drm_crtc_arm_vblank_event(crtc, event);
	else
		drm_crtc_send_vblank_event(crtc, event);
	spin_unlock_irq(&crtc->dev->event_lock);
}

/* The two modes the connector offers, and nothing else: see soph_read_mode(). */
static enum drm_mode_status
soph_pipe_mode_valid(struct drm_simple_display_pipe *pipe,
		     const struct drm_display_mode *mode)
{
	struct soph_drm *sd = to_soph(pipe->crtc.dev);

	if (soph_mode_is_native(sd, mode))
		return MODE_OK;
	if (sd->profile->gop_mode &&
	    mode->hdisplay == sd->gop_mode.hdisplay &&
	    mode->vdisplay == sd->gop_mode.vdisplay)
		return MODE_OK;
	return MODE_BAD;
}

/*
 * Pair each mode with what its pixel path can scan.
 *
 * 1280x720 is the video layer, at the size of the mode (the plane cannot be
 * positioned or scaled, so that also pins the source to the buffer's origin).
 * RGB888 needs a pitch the DISP can stride, 32-byte aligned (TRM 19.2.4.3),
 * and its address is the GEM object's own, so the offset must be 0. NV12
 * needs both pitches and both plane start addresses 32-byte aligned (TRM
 * 19.2.4.2); the planes may share one GEM object or sit in two. Every pitch
 * must also fit struct sclr_mem's 16-bit fields, or it would be scanned
 * truncated.
 *
 * 640x360 is the GOP: XRGB8888 or ARGB8888, no wider than it can fetch. It
 * has no YUV format, so NV12 is rejected there.
 *
 * A compositor searching formats gets -EINVAL for each wrong one and moves on
 * to the next. Every constraint lives here rather than at AddFB2: a failed
 * test commit makes wlroots composite the client buffer instead, a failed
 * AddFB2 poisons it for good.
 */
static int soph_pipe_check(struct drm_simple_display_pipe *pipe,
			   struct drm_plane_state *plane_state,
			   struct drm_crtc_state *crtc_state)
{
	struct soph_drm *sd = to_soph(pipe->crtc.dev);
	struct drm_framebuffer *fb = plane_state->fb;
	const struct drm_display_mode *mode = &crtc_state->mode;
	u32 format;

	if (!fb)
		return 0;
	format = fb->format->format;

	if (soph_mode_is_native(sd, mode)) {
		if (format == DRM_FORMAT_RGB888 &&
		    fb->width == mode->hdisplay &&
		    fb->height == mode->vdisplay &&
		    fb->pitches[0] % 32 == 0 && fb->pitches[0] <= U16_MAX &&
		    fb->offsets[0] == 0)
			return 0;
		if (format == DRM_FORMAT_NV12 &&
		    fb->width == mode->hdisplay &&
		    fb->height == mode->vdisplay &&
		    fb->pitches[0] % 32 == 0 && fb->pitches[1] % 32 == 0 &&
		    fb->pitches[0] <= U16_MAX && fb->pitches[1] <= U16_MAX &&
		    IS_ALIGNED(drm_fb_dma_get_gem_addr(fb, plane_state, 0), 32) &&
		    IS_ALIGNED(drm_fb_dma_get_gem_addr(fb, plane_state, 1), 32))
			return 0;
	} else if ((format == DRM_FORMAT_XRGB8888 ||
		    format == DRM_FORMAT_ARGB8888) &&
		   fb->width <= SOPH_GOP_MAX_SRC_W) {
		return 0;
	}

	drm_dbg_kms(&sd->drm, "no %p4cc %ux%u pitch %u fb for %ux%u\n",
		    &format, fb->width, fb->height, fb->pitches[0],
		    mode->hdisplay, mode->vdisplay);
	return -EINVAL;
}

static const struct drm_simple_display_pipe_funcs soph_pipe_funcs = {
	.mode_valid	= soph_pipe_mode_valid,
	.enable		= soph_pipe_enable,
	.disable	= soph_pipe_disable,
	.check		= soph_pipe_check,
	.update		= soph_pipe_update,
	.enable_vblank	= soph_enable_vblank,
	.disable_vblank	= soph_disable_vblank,
	/* .prepare_fb deliberately unset: drm_simple_kms_plane_prepare_fb()
	 * falls back to drm_gem_plane_helper_prepare_fb() on its own for a
	 * DRIVER_GEM driver, which is exactly the implicit-fence handling we
	 * want. Setting it by hand needs the (pipe, state) signature, not the
	 * plane helper's (plane, state), an easy way to not compile. */
};

/*
 * What we advertise to userspace: XRGB8888 and ARGB8888 for the GOP's
 * 640x360, RGB888 and NV12 for the video layer's 1280x720. soph_pipe_check()
 * pairs them with the modes.
 *
 * The GOP's two: wlroots insists on XRGB8888 for the primary scanout plane,
 * offered ARGB8888 alone it refuses to commit at all (sway stays up but the
 * CRTC never activates -> black), so XRGB8888 must be offered and is what
 * gets used. The overlay blends per-pixel alpha and pixman leaves XRGB8888's
 * X byte 0 (store_scanline_x8r8g8b8: values & 0x00ffffff), which composites
 * transparent == black; soph_gop_alpha_fill() therefore forces the buffer's
 * alpha to 0xff so the GOP renders it opaque. (The GOP has no global-alpha
 * and no opaque format, forcing the buffer alpha is the only lever, and it is
 * cheap at the GOP's 640x360.)
 *
 * The video layer's two: it has no 32bpp packed format, and RGB888 is its
 * SCL_FMT_BGR_PACKED byte for byte, so the compositor renders the very bytes
 * the display reads. NV12 is a decoder's frame, scanned out as it is. NV21
 * would be just as easy for the layer, but wlroots counts NV21 as having
 * alpha, so a surface in it occludes nothing and never gets scanned out.
 */
static const uint32_t soph_formats[] = {
	DRM_FORMAT_XRGB8888,
	DRM_FORMAT_ARGB8888,
	DRM_FORMAT_RGB888,
	DRM_FORMAT_NV12,
};

/* connector */

static int soph_conn_get_modes(struct drm_connector *connector)
{
	struct soph_drm *sd = to_soph(connector->dev);
	const struct drm_display_mode *modes[] = {
		&sd->native_mode,
		&sd->gop_mode,
	};
	struct drm_display_mode *mode;
	int i, n = 0;

	for (i = 0; i < (sd->profile->gop_mode ? 2 : 1); i++) {
		mode = drm_mode_duplicate(connector->dev, modes[i]);
		if (!mode)
			continue;
		drm_mode_probed_add(connector, mode);
		n++;
	}
	return n;
}

static const struct drm_connector_helper_funcs soph_conn_helper_funcs = {
	.get_modes = soph_conn_get_modes,
};

static const struct drm_connector_funcs soph_conn_funcs = {
	.fill_modes		= drm_helper_probe_single_connector_modes,
	.destroy		= drm_connector_cleanup,
	.reset			= drm_atomic_helper_connector_reset,
	.atomic_duplicate_state	= drm_atomic_helper_connector_duplicate_state,
	.atomic_destroy_state	= drm_atomic_helper_connector_destroy_state,
};

/*
 * Exported by cv181x_mipi_tx via patches/mipi-tx-export-kernel-bringup.patch.
 * The vendor ships no header for these, the whole module's interface is its
 * ioctl, so they are declared where they are used.
 */
int soph_mipi_tx_setup(const struct combo_dev_cfg_s *cfg);
void soph_mipi_tx_teardown(void);

/*
 * The DSI link this panel is on: 1280x720p60, RGB888, two data lanes.
 *
 * Two lanes rather than four: four lanes would not sync together and showed
 * nothing, and two carry 720p60 RGB888 with room to spare. lane_id[] is
 * indexed by PHY lane and says what each one carries; -1 is unused.
 *
 * This is the profile the out-of-tree `dsiup` tool used to poke in from
 * userspace before anything could drive the display. Programming it from
 * probe is what lets this driver own its output instead of inheriting
 * whatever somebody else left in the registers.
 */
static const struct combo_dev_cfg_s soph_dsi_720p60 = {
	.devno = 0,
	.lane_id = { MIPI_TX_LANE_0, MIPI_TX_LANE_1, MIPI_TX_LANE_CLK, -1, -1 },
	.output_mode = OUTPUT_MODE_DSI_VIDEO,
	.video_mode = BURST_MODE,
	.output_format = OUT_FORMAT_RGB_24_BIT,
	.sync_info = {
		.vid_hsa_pixels = 40,
		.vid_hbp_pixels = 220,
		.vid_hfp_pixels = 110,
		.vid_hline_pixels = 1280,
		.vid_vsa_lines = 5,
		.vid_vbp_lines = 20,
		.vid_vfp_lines = 5,
		.vid_active_lines = 720,
		.vid_vsa_pos_polarity = true,
		.vid_hsa_pos_polarity = true,
	},
	/* pixel_clk * bits_per_pixel / lanes, in Mbit/s */
	.phy_data_rate = 74250 * 24 / (2 * 1000),
	.pixel_clk = 74250,
};

static const struct soph_profile soph_hdmi_profile = {
	.link = &soph_dsi_720p60,
	.connector_type = DRM_MODE_CONNECTOR_HDMIA,
	.bridge = true,
	.gop_mode = true,
	.sync_low = true,
	.limited_rgb = true,
	.refresh = 60,
};

/* The MaixCAM carrier's ST7701, as st7701-panel-init left it: 368x552, 696x602 total
 * at 31.424 MHz, V+/H-, full-range RGB. */
static const struct soph_profile soph_panel_profile = {
	.connector_type = DRM_MODE_CONNECTOR_DSI,
	.refresh = 75,
	.mode_flags = DRM_MODE_FLAG_PVSYNC | DRM_MODE_FLAG_NHSYNC,
	.width = 368,
	.height = 552,
};

/*
 * On sync polarity, and why this driver does not touch it.
 *
 * The bring-up script cleared DISP_CFG bits 5 and 6 to drive VS/HS
 * active-low, and that was right for the bridge as that script configured it.
 * It is wrong here. The mainline lontium-lt8912b driver derives the bridge's
 * sync polarity from the DRM mode, and the mode this sink gives us,
 * CEA 1280x720@60, is +hsync +vsync. SET_DEV_CFG already programs the DISP
 * positive from the DSI profile, so the two agree and there is nothing to fix.
 *
 * Measured on badge #1, which is the only reason this comment exists: forcing
 * the bits low here produced a black screen on every attempt, where leaving
 * them alone produced a picture. Inverting a working display to apply a fix
 * from the era of a different bridge configuration is a mistake worth naming.
 */
/*
 * The DSI host is module-scope, not part of struct soph_drm.
 *
 * soph_drm is devm-allocated against the platform device and freed on every
 * deferred probe, and this probe does defer, because the bridge it wants is
 * the lontium-lt8912b that is itself waiting for this host to exist. A host
 * embedded in soph_drm would therefore be registered, freed underneath the DSI
 * core, and re-registered on the next attempt.
 *
 * It also must not be unregistered when the bridge is not ready yet. Doing
 * that is a deadlock: we register the host, fail to find the bridge, tear the
 * host down and defer; lt8912b then probes, finds no host, and defers too.
 * Measured on badge #1 as 250 lt8912 probe attempts and no card1.
 *
 * The platform device outlives all of this, so pointing the host at it is safe.
 */
static struct mipi_dsi_host soph_dsi_host;
static bool soph_dsi_host_registered;

static int soph_dsi_host_attach(struct mipi_dsi_host *host,
				struct mipi_dsi_device *dev)
{
	/*
	 * The DSI link is already up: probe ran soph_mipi_tx_setup() with this
	 * board's 2-lane profile, which is what the bridge asks for. Only the
	 * EoT packet follows the peripheral's flags.
	 *
	 * Do not re-run soph_mipi_tx_setup() here. It re-programs the DSI MAC
	 * and the DISP timing, and bridge-attach happens after the pipe is
	 * already configured, so a second bring-up corrupts a working display.
	 * Measured on badge #1: identical register readback to the good state,
	 * black panel. That cost real time, the readback is taken long after
	 * attach and shows nothing wrong.
	 */
	dev_info(host->dev, "DSI attach: %u lanes, format %u, flags 0x%lx\n",
		 dev->lanes, dev->format, dev->mode_flags);
	sclr_dsi_set_eot(!(dev->mode_flags & MIPI_DSI_MODE_NO_EOT_PACKET));
	return 0;
}

static int soph_dsi_host_detach(struct mipi_dsi_host *host,
				struct mipi_dsi_device *dev)
{
	return 0;
}

static ssize_t soph_dsi_host_transfer(struct mipi_dsi_host *host,
				      const struct mipi_dsi_msg *msg)
{
	int ret;

	/*
	 * The vendor exports DCS write/read against the MAC, which is all a
	 * bridge needs. LT8912B in particular sends nothing over DSI, it is
	 * configured entirely over i2c, so this exists to make the host
	 * complete rather than because the current sink uses it.
	 */
	if (msg->rx_buf && msg->rx_len) {
		ret = sclr_dsi_dcs_read_buffer(msg->type,
					       msg->tx_len ?
						 *(const u8 *)msg->tx_buf : 0,
					       msg->rx_buf, msg->rx_len);
		return ret < 0 ? ret : msg->rx_len;
	}

	ret = sclr_dsi_dcs_write_buffer(msg->type, msg->tx_buf, msg->tx_len,
					true);
	return ret < 0 ? ret : msg->tx_len;
}

static const struct mipi_dsi_host_ops soph_dsi_host_ops = {
	.attach = soph_dsi_host_attach,
	.detach = soph_dsi_host_detach,
	.transfer = soph_dsi_host_transfer,
};

/*
 * A DRM mode with `hdisplay` x `vdisplay` active pixels on the line the
 * hardware is running.
 *
 * The DISP timing is in absolute counter positions; DRM wants them as a
 * monotonic hdisplay/hsync_start/hsync_end/htotal sequence, so rebase each on
 * the start of active video. The totals and the clock are the line's own
 * whatever the active size.
 */
static void soph_fill_mode(struct drm_display_mode *m,
			   const struct sclr_disp_timing *t,
			   unsigned int hdisplay, unsigned int vdisplay,
			   u32 refresh)
{
	memset(m, 0, sizeof(*m));
	m->hdisplay   = hdisplay;
	m->vdisplay   = vdisplay;
	m->htotal     = t->htotal + 1;
	m->vtotal     = t->vtotal + 1;
	m->hsync_start = m->hdisplay + (t->hsync_start - t->hfde_start);
	m->hsync_end   = m->hdisplay + (t->hsync_end   - t->hfde_start);
	m->vsync_start = m->vdisplay + (t->vsync_start - t->vfde_start);
	m->vsync_end   = m->vdisplay + (t->vsync_end   - t->vfde_start);

	/* Keep the sequence monotonic even if the rebase above produced
	 * something odd; drm_mode_vrefresh() and userspace both assume it. */
	if (m->hsync_start < m->hdisplay || m->hsync_end <= m->hsync_start ||
	    m->htotal <= m->hsync_end) {
		m->hsync_start = m->hdisplay + 1;
		m->hsync_end   = m->hdisplay + 2;
	}
	if (m->vsync_start < m->vdisplay || m->vsync_end <= m->vsync_start ||
	    m->vtotal <= m->vsync_end) {
		m->vsync_start = m->vdisplay + 1;
		m->vsync_end   = m->vdisplay + 2;
	}

	m->clock = (u32)((u64)m->htotal * m->vtotal * refresh / 1000);
	m->type = DRM_MODE_TYPE_DRIVER;
	drm_mode_set_name(m);
}

/*
 * Build the two modes from what the hardware is actually running.
 *
 * We are a passenger on the vendor stack's modeset, so the honest mode is the
 * one read back out of the timing registers, not a constant. native_mode is
 * that line as it is; gop_mode is the same line with half the active size.
 */
static int soph_read_mode(struct soph_drm *sd)
{
	struct sclr_disp_timing t = {};
	unsigned int w, h;
	u32 refresh;

	soph_read_working_bank();
	sclr_disp_get_hw_timing(&t);

	/*
	 * Force sync active-low.
	 *
	 * SET_DEV_CFG leaves the DISP driving VS/HS active-high (from the DSI
	 * profile), and on this board the LT8912B does not lock to that: the
	 * panel is black. Clearing the two polarity bits is what the
	 * bring-up script did via /dev/mem; sclr_disp_set_timing() writes the
	 * same DISP_CFG bits 5 and 6 from these two fields.
	 *
	 * It is unconditional by necessity: sclr_disp_get_hw_timing() reads
	 * every timing register except the polarity bits, so the two pol fields
	 * come back as whatever the caller's struct held (zero, here) and a
	 * "only write if set" test would never fire.
	 *
	 * measured, not theorised, and I got this wrong twice: v0/h0 lights the
	 * panel and v1/h1 leaves it black, whatever CEA nominally says for
	 * 1280x720p60. Removing this because "positive is correct for a
	 * DT-configured bridge" produced three black-screen deploys. Do not.
	 */
	if (sd->profile->sync_low) {
		t.vsync_pol = false;
		t.hsync_pol = false;
		sclr_disp_set_timing(&t);
		sclr_disp_get_hw_timing(&t);
	}

	if (!t.htotal || !t.vtotal || t.hfde_end <= t.hfde_start ||
	    t.vfde_end <= t.vfde_start) {
		drm_err(&sd->drm,
			"DISP timing looks unprogrammed (h %u v %u hfde %u..%u) -- load the vendor display stack first\n",
			t.htotal, t.vtotal, t.hfde_start, t.hfde_end);
		return -ENODEV;
	}

	w = t.hfde_end - t.hfde_start + 1;
	h = t.vfde_end - t.vfde_start + 1;
	if (sd->profile->width &&
	    (w != sd->profile->width || h != sd->profile->height)) {
		drm_err(&sd->drm,
			"DISP is running %ux%u, not the panel's %ux%u -- initialise the panel first\n",
			w, h, sd->profile->width, sd->profile->height);
		return -ENODEV;
	}

	/* The pixel clock cannot be read back; the clock follows from the
	 * profile's refresh and the blanking totals. */
	refresh = sd->profile->refresh;

	soph_fill_mode(&sd->native_mode, &t, w, h, refresh);
	sd->native_mode.type |= DRM_MODE_TYPE_PREFERRED;
	sd->native_mode.flags = sd->profile->mode_flags;
	if (!sd->profile->gop_mode)
		goto done;

	/*
	 * The GOP mode is the panel halved, and the overlay's 2x scaler puts
	 * it back. The GOP stops fetching above ~1024 source pixels per line
	 * and blanks the whole display output; measured on badge #1: 1024
	 * composites, 1152 and 1280 are black, and it is a pixel limit rather
	 * than a bandwidth one (1280 at 16bpp is half the bytes of the working
	 * 1024 at 32bpp and still black). So a 1280-wide panel is driven from a
	 * 640x360 scanout. The video layer has no such limit.
	 *
	 * Only hdisplay/vdisplay are halved, not the totals or the clock. Keep
	 * the full 1650x750 / ~74 MHz timing, that is what the LT8912B bridge
	 * actually drives and validates, and it accepts it (bench gen 50: the
	 * 640-active/74 MHz mode committed). Halving the totals dropped the
	 * clock to ~18.5 MHz, below HDMI's ~25 MHz minimum, so the bridge
	 * pruned the mode -> connector exposed zero modes -> Sway left the
	 * output at 0x0 -> black (bench gen 54). soph_drm never programs the
	 * tgen from this mode anyway; only hdisplay/vdisplay (the GOP fetch
	 * size, which the 2x scaler upsizes) matter to the hardware, so a
	 * 640-active-in-1650 timing is correct here even though it looks odd.
	 */
	soph_fill_mode(&sd->gop_mode, &t, w / 2, h / 2, refresh);
	sd->gop_mode.flags = sd->profile->mode_flags;

done:
	sd->vbl_period = ns_to_ktime(NSEC_PER_SEC / refresh);
	/* Poll several times per frame to catch the real frame-end for a
	 * tear-free flip; see soph_vbl_fn. */
	sd->poll_period = ns_to_ktime(NSEC_PER_SEC / (refresh * SOPH_VBL_OVERSAMPLE));

	drm_info(&sd->drm,
		 "hardware mode %s (htotal %u vtotal %u, %u kHz), GOP mode %s\n",
		 sd->native_mode.name, sd->native_mode.htotal,
		 sd->native_mode.vtotal, sd->native_mode.clock,
		 sd->profile->gop_mode ? sd->gop_mode.name : "none");
	return 0;
}

/* driver */

DEFINE_DRM_GEM_DMA_FOPS(soph_drm_fops);

/*
 * Dumb buffers are what the plane scans, so give every one a pitch the DISP
 * can stride: 32-byte aligned (TRM 19.2.4.3). A 1280-pixel RGB888 line is
 * 3840 bytes, which already is.
 */
static int soph_dumb_create(struct drm_file *file, struct drm_device *dev,
			    struct drm_mode_create_dumb *args)
{
	args->pitch = ALIGN(DIV_ROUND_UP(args->width * args->bpp, 8), 32);
	return drm_gem_dma_dumb_create_internal(file, dev, args);
}

static const struct drm_driver soph_drm_driver = {
	.driver_features	= DRIVER_GEM | DRIVER_MODESET | DRIVER_ATOMIC,
	.fops			= &soph_drm_fops,
	.name			= "sophdrm",
	.desc			= "Sophgo CV181x VIP display",
	.major			= 1,
	.minor			= 0,
	DRM_GEM_DMA_DRIVER_OPS_VMAP_WITH_DUMB_CREATE(soph_dumb_create),
};

static const struct drm_mode_config_funcs soph_mode_config_funcs = {
	.fb_create	= drm_gem_fb_create,
	.atomic_check	= drm_atomic_helper_check,
	.atomic_commit	= drm_atomic_helper_commit,
};

static struct platform_device *soph_pdev;

static int soph_drm_probe(struct platform_device *pdev)
{
	struct soph_drm *sd;
	struct drm_device *drm;
	int ret;

	sd = devm_drm_dev_alloc(&pdev->dev, &soph_drm_driver,
				struct soph_drm, drm);
	if (IS_ERR(sd))
		return PTR_ERR(sd);
	drm = &sd->drm;
	platform_set_drvdata(pdev, sd);
	sd->profile = device_get_match_data(&pdev->dev) ?: &soph_hdmi_profile;

	/* GEM DMA buffers come out of CMA, same pool the VIP video buffers and
	 * gmac0's descriptor rings share. A 1280x720 RGB888 buffer is 2.7 MB
	 * and a compositor wants two or three of them. */
	ret = dma_coerce_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(32));
	if (ret)
		return ret;

	/* Zeroed, so the parked video layer reads black. */
	if (!dmam_alloc_coherent(&pdev->dev, SOPH_PARK_PITCH * SOPH_PARK_H,
				 &sd->park_dma, GFP_KERNEL))
		return -ENOMEM;
	sd->layer_fmt = SCL_FMT_MAX;

	/*
	 * Real-time priority for the display on the VIP AXI fabric. Without it
	 * the DISP DMA loses arbitration and the picture freezes on frame 1
	 * ("disp bw failed at frame#1") while the bridge stays locked, which
	 * reads like a link fault and is not one. cv181x_vpss exports the
	 * helper but nothing in the vendor tree calls it. Idempotent, so it is
	 * fine that soph_dispsrc does this too.
	 */
	vip_axi_realtime_fab_priority();

	/*
	 * Raise the DSI link ourselves. soph_read_mode() below reads the DISP
	 * timing back out of the hardware, and SET_DEV_CFG is what programs it
	 * (along with the D-PHY lanes, the PLL and the DSI MAC), so this has to
	 * happen first or we find the 320x240 reset timing and refuse to probe.
	 */
	if (!soph_dsi_host_registered && sd->profile->link) {
		ret = soph_mipi_tx_setup(sd->profile->link);
		if (ret) {
			drm_err(drm, "DSI bring-up failed (%d)\n", ret);
			return ret;
		}
	}

	/*
	 * Publish the DSI host, then pick up whatever the tree says is on the
	 * other end. lontium-lt8912b registers itself against this host from
	 * its own i2c probe, so it may well have deferred until now.
	 */
	if (pdev->dev.of_node && sd->profile->bridge) {
		if (!soph_dsi_host_registered) {
			soph_dsi_host.dev = &pdev->dev;
			soph_dsi_host.ops = &soph_dsi_host_ops;
			ret = mipi_dsi_host_register(&soph_dsi_host);
			if (ret)
				return dev_err_probe(&pdev->dev, ret,
						     "failed to register DSI host\n");
			soph_dsi_host_registered = true;
		}

		/*
		 * Deliberately leaves the host registered when this defers,
		 * see the comment on soph_dsi_host.
		 */
		sd->bridge = devm_drm_of_get_bridge(&pdev->dev,
						    pdev->dev.of_node, 0, 0);
		if (IS_ERR(sd->bridge)) {
			ret = PTR_ERR(sd->bridge);
			sd->bridge = NULL;
			return dev_err_probe(&pdev->dev, ret,
					     "waiting for the HDMI bridge\n");
		}
	}

	ret = soph_read_mode(sd);
	if (ret)
		return ret;

	ret = drmm_mode_config_init(drm);
	if (ret)
		return ret;
	/* Framebuffers range from the GOP mode, if there is one, up to the panel. */
	drm->mode_config.min_width = sd->profile->gop_mode ?
		sd->gop_mode.hdisplay : sd->native_mode.hdisplay;
	drm->mode_config.max_width = sd->native_mode.hdisplay;
	drm->mode_config.min_height = sd->profile->gop_mode ?
		sd->gop_mode.vdisplay : sd->native_mode.vdisplay;
	drm->mode_config.max_height = sd->native_mode.vdisplay;
	drm->mode_config.preferred_depth = 32;
	drm->mode_config.funcs = &soph_mode_config_funcs;

	spin_lock_init(&sd->flip_lock);
	hrtimer_setup(&sd->vbl_timer, soph_vbl_fn, CLOCK_MONOTONIC,
		      HRTIMER_MODE_REL);

	ret = drm_vblank_init(drm, 1);
	if (ret)
		return ret;

	/*
	 * Always our own connector, offering exactly the two modes. The bridge
	 * chain's connector would offer the sink's EDID modes instead: 640x360
	 * is never among them, 1280x720 only if the sink says so, and anything
	 * else is a mode this driver cannot scan. The bridge is still driven
	 * at a real 720p line by its force_720p param, whichever mode is set.
	 */
	drm_connector_helper_add(&sd->connector, &soph_conn_helper_funcs);
	ret = drm_connector_init(drm, &sd->connector, &soph_conn_funcs,
				 sd->profile->connector_type);
	if (ret)
		return ret;
	/* No hotplug visibility on a link we do not drive: claim
	 * always-connected rather than lie about detection. */
	sd->connector.status = connector_status_connected;
	sd->connector.polled = 0;
	/* The LT8912B reads display_info.is_hdmi to choose HDMI vs DVI
	 * signalling; with our own (EDID-less) connector it would stay
	 * zeroed and program DVI. Force HDMI. */
	sd->connector.display_info.is_hdmi = sd->profile->bridge;

	ret = drm_simple_display_pipe_init(drm, &sd->pipe, &soph_pipe_funcs,
					   soph_formats,
					   ARRAY_SIZE(soph_formats),
					   NULL, &sd->connector);
	if (ret)
		return ret;

	/* How NV12 buffers are encoded; see soph_yuv_csc(). Before the reset
	 * below, which puts the defaults into the plane state. */
	ret = drm_plane_create_color_properties(&sd->pipe.plane,
						BIT(DRM_COLOR_YCBCR_BT601) |
						BIT(DRM_COLOR_YCBCR_BT709),
						BIT(DRM_COLOR_YCBCR_LIMITED_RANGE) |
						BIT(DRM_COLOR_YCBCR_FULL_RANGE),
						DRM_COLOR_YCBCR_BT601,
						DRM_COLOR_YCBCR_LIMITED_RANGE);
	if (ret)
		return ret;

	if (sd->bridge) {
		/* Without its own EDID connector: ours is the connector. */
		ret = drm_bridge_attach(&sd->pipe.encoder, sd->bridge, NULL,
					DRM_BRIDGE_ATTACH_NO_CONNECTOR);
		if (ret)
			return dev_err_probe(&pdev->dev, ret,
					     "failed to attach HDMI bridge\n");
	}

	drm_mode_config_reset(drm);

	ret = drm_dev_register(drm, 0);
	if (ret)
		return ret;

	drm_info(drm, "registered on %s\n", dev_name(&pdev->dev));
	return 0;
}

static void soph_drm_remove(struct platform_device *pdev)
{
	struct soph_drm *sd = platform_get_drvdata(pdev);

	drm_dev_unplug(&sd->drm);
	drm_atomic_helper_shutdown(&sd->drm);
	hrtimer_cancel(&sd->vbl_timer);
}

/*
 * Bind to the DSI host node when the device tree has one.
 *
 * This driver used to manufacture its own platform device unconditionally,
 * because the DISP registers belong to cv181x_vpss and there was nothing for
 * it to bind to. That is still true of the registers, but a device with no
 * of_node cannot be found as a mipi_dsi_host, so no bridge could ever be wired
 * to it and the sink had to be configured from userspace. The node carries no
 * registers, only identity and the graph edge.
 */
static const struct of_device_id soph_drm_of_match[] = {
	{ .compatible = "badge,sg2000-soph-dsi", .data = &soph_hdmi_profile },
	{ .compatible = "badge,sg2002-soph-dsi-st7701", .data = &soph_panel_profile },
	{ }
};
MODULE_DEVICE_TABLE(of, soph_drm_of_match);

static struct platform_driver soph_drm_platform_driver = {
	.probe	= soph_drm_probe,
	.remove	= soph_drm_remove,
	.driver	= {
		.name = "soph-drm",
		.of_match_table = soph_drm_of_match,
	},
};

static int __init soph_drm_init(void)
{
	struct device_node *np;
	int ret;

	ret = platform_driver_register(&soph_drm_platform_driver);
	if (ret)
		return ret;

	/*
	 * Only manufacture a device when the tree has no node for us. With a
	 * node (arm) we bind to it and get an of_node, which is what makes the
	 * DSI host findable and the HDMI bridge attachable. Without one (the
	 * riscv DTB has no display work yet) fall back to the old behaviour so
	 * that arch keeps working exactly as before.
	 */
	np = of_find_matching_node(NULL, soph_drm_of_match);
	if (np) {
		of_node_put(np);
		return 0;
	}

	soph_pdev = platform_device_register_simple("soph-drm", -1, NULL, 0);
	if (IS_ERR(soph_pdev)) {
		if (soph_dsi_host_registered) {
		mipi_dsi_host_unregister(&soph_dsi_host);
		soph_dsi_host_registered = false;
	}
	platform_driver_unregister(&soph_drm_platform_driver);
		return PTR_ERR(soph_pdev);
	}
	return 0;
}

static void __exit soph_drm_exit(void)
{
	platform_device_unregister(soph_pdev);
	platform_driver_unregister(&soph_drm_platform_driver);
}

module_init(soph_drm_init);
module_exit(soph_drm_exit);
MODULE_AUTHOR("badgeos");
MODULE_DESCRIPTION("KMS front end for the cvitek VIP display block (#82)");
MODULE_LICENSE("GPL");
