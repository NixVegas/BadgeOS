// SPDX-License-Identifier: GPL-2.0
/*
 * soph_dispsrc, give the vendor DISP block something to scan out.
 *
 * The forward-ported vendor stack (cv181x_vpss/vo/mipi_tx) brings the DSI link
 * all the way up, D-PHY lanes in HS, MAC in video mode, tgen running, but
 * the only thing that ever feeds the display controller is the vendor
 * middleware's VO layer, which is userspace we do not have on NixOS.
 *
 * Rather than re-transcribe the register sequence (which is what
 * lt8912b-bringup does, and where a wrong PAT_EN bit hid for a long time),
 * this calls cv181x_vpss's own exported sclr_disp_* functions. Same code the
 * vendor kernel runs, so the shadow-bank dance, the CSC setup and the burst /
 * out_bit encodings are all theirs.
 *
 * Controls (all under /sys/kernel/debug/soph_dispsrc):
 *   pattern  "<type> <color>"  sclr_disp_set_pattern (type 0 full, 1 HGRAD,
 *                              2 VGRAD, 3 AUTO, 4 SNOW, 5 off; color 0 white
 *                              .. 6 yellow, 7 bar)
 *   bgcolor  "<r> <g> <b>"     10-bit frame + window background, and turn the
 *                              window background on (hides everything else)
 *   fb       "1"               scan out our coherent framebuffer instead
 *   tgen     "0"|"1"           sclr_disp_tgen_enable
 *   status               (ro)  live disp debug status + checksum
 *
 * /dev/sophfb mmaps the framebuffer so userspace can draw into it.
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/platform_device.h>
#include <linux/dma-mapping.h>
#include <linux/debugfs.h>
#include <linux/miscdevice.h>
#include <linux/uaccess.h>
#include <linux/mm.h>
#include <linux/io.h>

#include "scaler.h"

#define FB_W	1280
#define FB_H	720
#define FB_BPP	3
#define FB_PITCH (FB_W * FB_BPP)
/* Sized for the widest consumer: the GOP path is ARGB8888 at 4 bytes/pixel,
 * where FB_PITCH (3 bytes/pixel, for the DISP RGB_PACKED path) is too small.
 * NV21 needs only 1.5 bytes/pixel, so this covers every mode. */
#define FB_SIZE	 (FB_W * FB_H * 4)

static struct platform_device *pdev;
static void *fb_cpu;
static dma_addr_t fb_dma;
static phys_addr_t fb_phys;
static struct dentry *dbg;

static int width = FB_W;
module_param(width, int, 0444);
static int height = FB_H;
module_param(height, int, 0444);

/* Eight vertical bars, RGB packed, R in the low byte (SCL_FMT_RGB_PACKED). */
/*
 * DISP registers are shadowed, and DISP_CFG bit18 (SHRD_SEL) picks which bank
 * a CPU *read* sees: 0 = the shadow, 1 = the working bank. Every vendor
 * sclr_disp_* helper is a read-modify-write, so with bit18 clear they read a
 * just-consumed shadow (zeros) and write it back, sclr_disp_set_cfg silently
 * lands fmt = 0 and sclr_disp_set_mem lands pitch_y = 0. The vendor kernel never
 * hits this because its own bring-up leaves bit18 set (the golden Debian dump
 * has DISP_CFG = 0x000490E0); on mainline nothing does, so set it ourselves
 * before touching anything.
 */
static void read_working_bank(void)
{
	sclr_disp_reg_shadow_sel(false);
}

static void fill_colorbar(u8 *fb)
{
	static const u8 bars[8][3] = {
		{255, 255, 255}, {255, 255, 0}, {0, 255, 255}, {0, 255, 0},
		{255, 0, 255},   {255, 0, 0},   {0, 0, 255},   {0, 0, 0},
	};
	int x, y;

	for (y = 0; y < height; y++) {
		u8 *row = fb + (size_t)y * FB_PITCH;

		for (x = 0; x < width; x++) {
			const u8 *c = bars[(x * 8) / width];

			row[x * 3 + 0] = c[0];
			row[x * 3 + 1] = c[1];
			row[x * 3 + 2] = c[2];
		}
	}
}

static ssize_t pattern_write(struct file *f, const char __user *u,
			     size_t len, loff_t *ppos)
{
	char buf[32];
	int type = SCL_PAT_TYPE_FULL, color = SCL_PAT_COLOR_BAR;

	if (len >= sizeof(buf))
		return -EINVAL;
	if (copy_from_user(buf, u, len))
		return -EFAULT;
	buf[len] = '\0';
	if (sscanf(buf, "%d %d", &type, &color) < 1)
		return -EINVAL;

	read_working_bank();
	sclr_disp_set_pattern(type, color, NULL);
	sclr_disp_reg_force_up();
	pr_info("soph_dispsrc: pattern type=%d color=%d\n", type, color);
	return len;
}
static const struct file_operations pattern_fops = {
	.owner = THIS_MODULE, .write = pattern_write, .llseek = noop_llseek,
};

static ssize_t bgcolor_write(struct file *f, const char __user *u,
			     size_t len, loff_t *ppos)
{
	char buf[48];
	unsigned int r = 0x3ff, g = 0x3ff, b = 0x3ff;

	if (len >= sizeof(buf))
		return -EINVAL;
	if (copy_from_user(buf, u, len))
		return -EFAULT;
	buf[len] = '\0';
	if (sscanf(buf, "%u %u %u", &r, &g, &b) < 1)
		return -EINVAL;

	read_working_bank();
	sclr_disp_set_frame_bgcolor(r, g, b);
	sclr_disp_set_window_bgcolor(r, g, b);
	sclr_disp_enable_window_bgcolor(true);
	sclr_disp_reg_force_up();
	pr_info("soph_dispsrc: bgcolor %u %u %u\n", r, g, b);
	return len;
}
static const struct file_operations bgcolor_fops = {
	.owner = THIS_MODULE, .write = bgcolor_write, .llseek = noop_llseek,
};

static ssize_t fb_write(struct file *f, const char __user *u,
			size_t len, loff_t *ppos)
{
	struct sclr_disp_cfg *cfg;
	int v;

	if (kstrtoint_from_user(u, len, 0, &v))
		return -EINVAL;
	if (!fb_cpu)
		return -ENODEV;

	read_working_bank();
	cfg = sclr_disp_get_cfg();
	cfg->disp_from_sc = false;
	cfg->sync_ext = false;
	cfg->tgen_en = true;
	cfg->fmt = SCL_FMT_RGB_PACKED;
	cfg->in_csc = SCL_CSC_NONE;
	cfg->out_csc = SCL_CSC_NONE;
	cfg->burst = 7;
	cfg->out_bit = 8;
	cfg->drop_mode = SCL_DISP_DROP_MODE_DITHER;
	cfg->mem.addr0 = fb_dma;
	cfg->mem.addr1 = 0;
	cfg->mem.addr2 = 0;
	cfg->mem.pitch_y = FB_PITCH;
	cfg->mem.pitch_c = 0;
	cfg->mem.start_x = 0;
	cfg->mem.start_y = 0;
	cfg->mem.width = width;
	cfg->mem.height = height;

	/* the pattern generator and the window background both sit in front of
	 * the scanout, turn them off or the framebuffer never shows. */
	sclr_disp_set_pattern(SCL_PAT_TYPE_OFF, SCL_PAT_COLOR_WHITE, NULL);
	sclr_disp_enable_window_bgcolor(false);
	sclr_disp_set_cfg(cfg);
	sclr_disp_tgen_enable(true);
	sclr_disp_reg_force_up();

	pr_info("soph_dispsrc: scanout %dx%d pitch %d @ %pad (v=%d)\n",
		width, height, FB_PITCH, &fb_dma, v);
	return len;
}
static const struct file_operations fb_fops = {
	.owner = THIS_MODULE, .write = fb_write, .llseek = noop_llseek,
};


/*
 * NV21 colorbar: Y plane then an interleaved V,U plane at half resolution.
 *
 * This exists because NV21 is the one thing the known-good Debian run did that
 * an RGB framebuffer does not: its golden DISP dump is FMT_SEL = 9 (NV21) with
 * in_csc = 0x80000400 (601-limited YUV->RGB), because the source was H.264
 * frames straight out of the vendor VDEC. Everything else about the DISP
 * config now matches byte for byte, so the format is what is left to rule out.
 */
static void fill_nv21(u8 *fb)
{
	static const u8 bars[8][3] = {
		{255, 255, 255}, {255, 255, 0}, {0, 255, 255}, {0, 255, 0},
		{255, 0, 255},   {255, 0, 0},   {0, 0, 255},   {0, 0, 0},
	};
	u8 *y_plane = fb;
	u8 *vu_plane = fb + (size_t)width * height;
	int x, y;

	for (y = 0; y < height; y++) {
		for (x = 0; x < width; x++) {
			const u8 *c = bars[(x * 8) / width];
			/* BT.601 limited range */
			int Y = (66 * c[0] + 129 * c[1] + 25 * c[2] + 128) / 256 + 16;

			y_plane[(size_t)y * width + x] = clamp(Y, 16, 235);
		}
	}
	for (y = 0; y < height / 2; y++) {
		for (x = 0; x < width / 2; x++) {
			const u8 *c = bars[(2 * x * 8) / width];
			int U = (-38 * c[0] - 74 * c[1] + 112 * c[2] + 128) / 256 + 128;
			int V = (112 * c[0] - 94 * c[1] - 18 * c[2] + 128) / 256 + 128;

			/* NV21 = V first, then U */
			vu_plane[(size_t)y * width + 2 * x + 0] = clamp(V, 16, 240);
			vu_plane[(size_t)y * width + 2 * x + 1] = clamp(U, 16, 240);
		}
	}
}

static ssize_t nv21_write(struct file *f, const char __user *u,
			  size_t len, loff_t *ppos)
{
	struct sclr_disp_cfg *cfg;
	int v;

	if (kstrtoint_from_user(u, len, 0, &v))
		return -EINVAL;
	if (!fb_cpu)
		return -ENODEV;

	fill_nv21(fb_cpu);
	read_working_bank();
	cfg = sclr_disp_get_cfg();
	cfg->disp_from_sc = false;
	cfg->sync_ext = false;
	cfg->tgen_en = true;
	cfg->fmt = SCL_FMT_NV21;
	cfg->in_csc = SCL_CSC_601_LIMIT_YUV2RGB;
	cfg->out_csc = SCL_CSC_NONE;
	cfg->burst = 7;
	cfg->out_bit = 8;
	cfg->drop_mode = SCL_DISP_DROP_MODE_DITHER;
	cfg->mem.addr0 = fb_dma;
	cfg->mem.addr1 = fb_dma + (u32)width * height;
	cfg->mem.addr2 = 0;
	cfg->mem.pitch_y = width;
	cfg->mem.pitch_c = width;
	cfg->mem.start_x = 0;
	cfg->mem.start_y = 0;
	cfg->mem.width = width;
	cfg->mem.height = height;

	sclr_disp_set_pattern(SCL_PAT_TYPE_OFF, SCL_PAT_COLOR_WHITE, NULL);
	sclr_disp_enable_window_bgcolor(false);
	sclr_disp_set_cfg(cfg);
	sclr_disp_tgen_enable(true);
	sclr_disp_reg_force_up();

	pr_info("soph_dispsrc: NV21 %dx%d y@%pad vu@+%u (v=%d)\n",
		width, height, &fb_dma, (unsigned int)(width * height), v);
	return len;
}
static const struct file_operations nv21_fops = {
	.owner = THIS_MODULE, .write = nv21_write, .llseek = noop_llseek,
};

/*
 * GOP (OSD) overlay, the other pixel path.
 *
 * The DISP video layer composites what the AXI DMA fetches; the GOP is a
 * separate overlay engine that the display controller blends on top. The
 * vendor's own framebuffer driver (interdrv/fb/cvifb.c) puts pixels on screen
 * purely through the GOP, never through the video layer, so if the video path
 * is the broken one this still paints.
 *
 * cvifb drives SCL_GOP_DISP layer 1, overlay window 0, which is what is
 * mirrored here.
 */
static void fill_argb(u8 *fb)
{
	static const u8 bars[8][3] = {
		{255, 255, 255}, {255, 255, 0}, {0, 255, 255}, {0, 255, 0},
		{255, 0, 255},   {255, 0, 0},   {0, 0, 255},   {0, 0, 0},
	};
	u32 *px = (u32 *)fb;
	int x, y;

	for (y = 0; y < height; y++)
		for (x = 0; x < width; x++) {
			const u8 *c = bars[(x * 8) / width];

			/* ARGB8888, opaque */
			px[(size_t)y * width + x] = 0xff000000u |
				((u32)c[0] << 16) | ((u32)c[1] << 8) | c[2];
		}
}

static ssize_t gop_write(struct file *f, const char __user *u,
			 size_t len, loff_t *ppos)
{
	struct sclr_gop_cfg *cfg;
	struct sclr_gop_ow_cfg ow = {};
	int v;
	u8 layer = 1;

	if (kstrtoint_from_user(u, len, 0, &v))
		return -EINVAL;
	if (!fb_cpu)
		return -ENODEV;

	fill_argb(fb_cpu);
	read_working_bank();

	cfg = sclr_gop_get_cfg(SCL_GOP_DISP, layer);
	cfg->gop_ctrl.b.hscl_en = 0;
	cfg->gop_ctrl.b.vscl_en = 0;

	ow.fmt = SCL_GOP_FMT_ARGB8888;
	ow.img_size.w = width;
	ow.img_size.h = height;
	ow.mem_size.w = width * 4;
	ow.mem_size.h = height;
	ow.pitch = ow.mem_size.w;
	ow.start.x = 0;
	ow.start.y = 0;
	ow.crop_pixels = 0;
	ow.end.x = width;
	ow.end.y = height;
	ow.addr = fb_dma;
	sclr_gop_ow_set_cfg(SCL_GOP_DISP, layer, 0, &ow, true);

	cfg->gop_ctrl.raw &= ~0xffu;
	cfg->gop_ctrl.b.ow0_en = !!v;
	sclr_gop_set_cfg(SCL_GOP_DISP, layer, cfg, true);
	sclr_disp_reg_force_up();

	pr_info("soph_dispsrc: GOP layer %u ow0 %s, ARGB8888 %dx%d pitch %u @%pad\n",
		layer, v ? "on" : "off", width, height, ow.pitch, &fb_dma);
	return len;
}
static const struct file_operations gop_fops = {
	.owner = THIS_MODULE, .write = gop_write, .llseek = noop_llseek,
};

/*
 * Shrink the image window so the frame background is actually visible.
 *
 * `bgcolor` on its own proves nothing: sclr_disp_enable_window_bgcolor() fills
 * the area outside the image rect, and sclr_disp_set_timing() leaves MDE equal
 * to FDE, the image window covers the whole active area, so there is no
 * background region to see. (That the vendor's own vo_start_streaming() turns
 * window bgcolor ON while streaming is the tell: if it hid everything, the VO
 * would never show a picture.)
 *
 * This sets a frame background and then shrinks MDE via sclr_disp_set_rect(),
 * so a border should appear in the background colour. A visible border means
 * the DISP output stage and the DSI path are carrying real pixel values and the
 * fault is in the image source; a black screen means the output stage itself is
 * emitting zeros. Either way it splits the remaining search space in half.
 */
static ssize_t rect_write(struct file *f, const char __user *u,
			  size_t len, loff_t *ppos)
{
	char buf[64];
	struct sclr_rect r;
	unsigned int x = 320, y = 180, w = 640, h = 360, cr = 1023, cg = 1023, cb = 1023;
	int n, ret;

	if (len >= sizeof(buf))
		return -EINVAL;
	if (copy_from_user(buf, u, len))
		return -EFAULT;
	buf[len] = '\0';
	n = sscanf(buf, "%u %u %u %u %u %u %u", &x, &y, &w, &h, &cr, &cg, &cb);
	if (n < 4)
		return -EINVAL;

	read_working_bank();
	sclr_disp_set_frame_bgcolor(cr, cg, cb);
	sclr_disp_set_window_bgcolor(cr, cg, cb);
	sclr_disp_enable_window_bgcolor(true);

	r.x = x; r.y = y; r.w = w; r.h = h;
	ret = sclr_disp_set_rect(r);
	sclr_disp_reg_force_up();

	pr_info("soph_dispsrc: rect (%u,%u) %ux%u bg(%u,%u,%u) rc=%d\n",
		x, y, w, h, cr, cg, cb, ret);
	return len;
}
static const struct file_operations rect_fops = {
	.owner = THIS_MODULE, .write = rect_write, .llseek = noop_llseek,
};
static ssize_t tgen_write(struct file *f, const char __user *u,
			  size_t len, loff_t *ppos)
{
	int v;

	if (kstrtoint_from_user(u, len, 0, &v))
		return -EINVAL;
	sclr_disp_tgen_enable(!!v);
	return len;
}
static const struct file_operations tgen_fops = {
	.owner = THIS_MODULE, .write = tgen_write, .llseek = noop_llseek,
};

static int status_show(struct seq_file *s, void *p)
{
	union sclr_disp_dbg_status st = sclr_disp_get_dbg_status(true);
	struct sclr_disp_cfg *cfg = sclr_disp_get_cfg();
	struct sclr_disp_timing *t = sclr_disp_get_timing();

	seq_printf(s, "tgen_en(%d) from_sc(%d) fmt(%d) burst(%d) out_bit(%d)\n",
		   cfg->tgen_en, cfg->disp_from_sc, cfg->fmt, cfg->burst,
		   cfg->out_bit);
	seq_printf(s, "mem %ux%u @%llx pitch_y(%u) pitch_c(%u)\n",
		   cfg->mem.width, cfg->mem.height, cfg->mem.addr0,
		   cfg->mem.pitch_y, cfg->mem.pitch_c);
	seq_printf(s, "timing h(%u) v(%u) hde(%u..%u) vde(%u..%u) pol(v%d h%d)\n",
		   t->htotal, t->vtotal, t->hfde_start, t->hfde_end,
		   t->vfde_start, t->vfde_end, t->vsync_pol, t->hsync_pol);
	seq_printf(s, "err_fwr(%d%d%d) err_erd(%d%d%d) lb_full(%d%d%d) lb_empty(%d%d%d) bw_fail(%d)\n",
		   st.b.err_fwr_y, st.b.err_fwr_u, st.b.err_fwr_v,
		   st.b.err_erd_y, st.b.err_erd_u, st.b.err_erd_v,
		   st.b.lb_full_y, st.b.lb_full_u, st.b.lb_full_v,
		   st.b.lb_empty_y, st.b.lb_empty_u, st.b.lb_empty_v,
		   st.b.bw_fail);
	seq_printf(s, "axi_status(%d) fb %pad %u bytes\n",
		   sclr_disp_get_axi_status(), &fb_dma, (unsigned int)FB_SIZE);
	/* Does the DMA handle actually alias the CPU mapping? If the
	 * platform put an offset between them, the display controller
	 * would be scanning somebody else's memory, which looks exactly
	 * like a correctly configured all-black screen. */
	if (fb_cpu) {
		const u32 *w = fb_cpu;

		seq_printf(s, "fb_cpu %p phys %pa dma %pad%s\n",
			   fb_cpu, &fb_phys, &fb_dma,
			   (fb_phys == (phys_addr_t)fb_dma) ? "" : "  *** DMA != PHYS ***");
		seq_printf(s, "fb[0..3] %08x %08x %08x %08x\n",
			   w[0], w[1], w[2], w[3]);
		seq_printf(s, "fb[+0x200] %08x  fb[+0xE1000] %08x\n",
			   w[0x200 / 4], w[0xE1000 / 4]);
	}
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(status);

static int fbmap_mmap(struct file *f, struct vm_area_struct *vma)
{
	unsigned long sz = vma->vm_end - vma->vm_start;

	if (!fb_cpu || vma->vm_pgoff || sz > FB_SIZE)
		return -EINVAL;
	return dma_mmap_coherent(&pdev->dev, vma, fb_cpu, fb_dma, sz);
}
static const struct file_operations fbmap_fops = {
	.owner = THIS_MODULE, .mmap = fbmap_mmap, .llseek = noop_llseek,
};
static struct miscdevice fbmap_misc = {
	.minor = MISC_DYNAMIC_MINOR, .name = "sophfb", .fops = &fbmap_fops,
	.mode = 0600,
};

/*
 * Give the display real-time priority on the VIP AXI fabric.
 *
 * Without this the DISP DMA loses arbitration and starves, and the failure is
 * immediate and total rather than a gradual tear:
 *
 *   vo_irq_handler:2394():  disp bw failed at frame#1
 *
 * the picture freezes on the very first frame while the bridge stays
 * locked at DT=0x3e, so it reads like a decode or a link problem and is
 * neither. Measured on badge #1: VIP_AXI_FAB_PRI (0x0A0C8070) reads
 * 0x0000AA0F with the vendor stack up, against the 0x1032AA0F the vendor's
 * own helper writes, the whole real-time priority field is zero.
 *
 * vip_axi_realtime_fab_priority() is EXPORT_SYMBOL_GPL'd by cv181x_vpss and
 * does exactly that one write, but nothing in the vendor tree calls it: it is
 * a patch routine the BSP is expected to invoke, and our forward-port never
 * did. Calling it here is idempotent, so it is safe that both this and
 * soph_drm do.
 */
static void soph_dispsrc_fab_priority(void)
{
	vip_axi_realtime_fab_priority();
	pr_info("soph_dispsrc: VIP AXI real-time fabric priority applied\n");
}

static int __init dispsrc_init(void)
{
	pdev = platform_device_register_simple("soph-dispsrc", -1, NULL, 0);
	if (IS_ERR(pdev))
		return PTR_ERR(pdev);

	if (dma_coerce_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(32)))
		pr_warn("soph_dispsrc: no 32-bit DMA mask\n");

	fb_cpu = dma_alloc_coherent(&pdev->dev, FB_SIZE, &fb_dma, GFP_KERNEL);
	if (!fb_cpu) {
		pr_warn("soph_dispsrc: framebuffer alloc failed (need cma=)\n");
	} else {
		fb_phys = virt_to_phys(fb_cpu);
		fill_colorbar(fb_cpu);
		pr_info("soph_dispsrc: framebuffer %d bytes @ %pad (colorbar)\n",
			FB_SIZE, &fb_dma);
	}

	soph_dispsrc_fab_priority();

	dbg = debugfs_create_dir("soph_dispsrc", NULL);
	debugfs_create_file("pattern", 0200, dbg, NULL, &pattern_fops);
	debugfs_create_file("bgcolor", 0200, dbg, NULL, &bgcolor_fops);
	debugfs_create_file("fb", 0200, dbg, NULL, &fb_fops);
	debugfs_create_file("tgen", 0200, dbg, NULL, &tgen_fops);
	debugfs_create_file("nv21", 0200, dbg, NULL, &nv21_fops);
	debugfs_create_file("gop", 0200, dbg, NULL, &gop_fops);
	debugfs_create_file("rect", 0200, dbg, NULL, &rect_fops);
	debugfs_create_file("status", 0400, dbg, NULL, &status_fops);
	if (misc_register(&fbmap_misc))
		pr_warn("soph_dispsrc: misc_register failed; no /dev/sophfb\n");
	return 0;
}

static void __exit dispsrc_exit(void)
{
	misc_deregister(&fbmap_misc);
	debugfs_remove_recursive(dbg);
	if (fb_cpu)
		dma_free_coherent(&pdev->dev, FB_SIZE, fb_cpu, fb_dma);
	platform_device_unregister(pdev);
}

module_init(dispsrc_init);
module_exit(dispsrc_exit);
MODULE_AUTHOR("badgeos");
MODULE_DESCRIPTION("Feed the cvitek DISP block from a coherent framebuffer");
MODULE_LICENSE("GPL");
