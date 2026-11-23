// SPDX-License-Identifier: GPL-2.0
/*
 * Rotate RGB bytes as Y400; DISP reads the result as three interleaved planes.
 *
 * The LDC cannot scale along the byte axis without mixing channels, so the
 * half-size mode is doubled by the CPU into a full-size frame first and the
 * rotation itself is the same either way; see soph_rot_double().
 */
#include <linux/clk.h>
#include <linux/completion.h>
#include <linux/dma-mapping.h>
#include <linux/iopoll.h>
#include <linux/module.h>
#include <linux/platform_device.h>
#include <drm/drm_plane.h>
#include <drm/drm_fb_dma_helper.h>
#include <drm/drm_fourcc.h>
#include <drm/drm_framebuffer.h>
#include <drm/drm_gem_dma_helper.h>
#include "scaler.h"
#include "soph_rot.h"

#define LDC_DATA_FORMAT  0x00
#define LDC_RAS_MODE     0x04
#define LDC_RAS_XSIZE    0x08
#define LDC_RAS_YSIZE    0x0c
#define LDC_MAP_BASE     0x10
#define LDC_MAP_BYPASS   0x14
#define LDC_SRC_BASE_Y   0x20
#define LDC_SRC_BASE_C   0x24
#define LDC_SRC_XSIZE    0x28
#define LDC_SRC_YSIZE    0x2c
#define LDC_SRC_XSTART   0x30
#define LDC_SRC_XEND     0x34
#define LDC_SRC_BG       0x38
#define LDC_DST_BASE_Y   0x40
#define LDC_DST_BASE_C   0x44
#define LDC_DST_MODE     0x48
#define LDC_IRQEN        0x50
#define LDC_START        0x54
#define LDC_IRQSTAT      0x58
#define LDC_IRQCLR       0x5c
#define LDC_SB_MODE      0x60
#define LDC_SB_SET_STR   0x6c
#define LDC_SB_SW_CLR    0x74
#define LDC_DIR          0x8c
#define LDC_INT_SEL      0x90

struct soph_rot {
	struct device *dev;
	struct resource *region;
	void __iomem *regs;
	struct clk_bulk_data *clks;
	int nclks;
	bool clocks_on, failed, ready;
	unsigned int width, height, pitch, rows, angle, front;
	unsigned int front_pitch, front_cpp, front_width, front_height, front_rows;
	size_t size;
	void *buf[2];
	dma_addr_t dma[2];
	/* A half-size frame doubled into a full-size packed RGB888 one, and
	 * the two cached lines soph_rot_double() builds it through. */
	unsigned int wide_pitch;
	void *wide;
	dma_addr_t wide_dma;
	u8 *line, *pair;
	struct completion latched;
};

static void soph_rot_destroy(void *data)
{
	struct soph_rot *r = data;
	unsigned int i;

	/* No reset: a timed-out LDC keeps its buffers, clocks and registers. */
	if (r->failed)
		return;
	if (r->regs) {
		writel(0, r->regs + LDC_IRQEN);
		iounmap(r->regs);
	}
	for (i = 0; i < 2; i++)
		if (r->buf[i])
			dma_free_coherent(r->dev, r->size, r->buf[i], r->dma[i]);
	if (r->wide)
		dma_free_coherent(r->dev, r->wide_pitch * r->rows, r->wide,
				  r->wide_dma);
	kfree(r->pair);
	kfree(r->line);
	if (r->clocks_on)
		clk_bulk_disable_unprepare(r->nclks, r->clks);
	if (r->nclks > 0)
		clk_bulk_put_all(r->nclks, r->clks);
	if (r->region)
		release_mem_region(r->region->start, resource_size(r->region));
	put_device(r->dev);
	kfree(r);
}

struct soph_rot *soph_rot_create(struct platform_device *pdev, unsigned int w,
				 unsigned int h, unsigned int angle)
{
	struct resource *res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
	struct soph_rot *r;
	unsigned int i;
	int ret = -ENOMEM;

	/* LDC dimensions are 12-bit, in bytes, with 64-byte/tall padding. */
	if ((angle != 90 && angle != 270) || !w || !h ||
	    w > 4032 / 4 || h > 4032 || !res)
		return ERR_PTR(-EINVAL);
	ret = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(32));
	if (ret)
		return ERR_PTR(ret);
	ret = -ENOMEM;
	r = kzalloc(sizeof(*r), GFP_KERNEL);
	if (!r)
		return ERR_PTR(-ENOMEM);
	r->dev = get_device(&pdev->dev);
	r->width = w;
	r->height = h;
	r->angle = angle;
	/* Reserve the supported pitch range before any frame is committed. */
	r->pitch = 4032;
	r->rows = ALIGN(h, 64);
	r->size = r->pitch * r->rows;
	r->wide_pitch = ALIGN(w * 3, 64);
	init_completion(&r->latched);
	complete_all(&r->latched);
	r->region = request_mem_region(res->start, resource_size(res), "soph-rot");
	if (!r->region) {
		ret = -EBUSY;
		goto fail;
	}
	r->nclks = clk_bulk_get_all(r->dev, &r->clks);
	if (r->nclks <= 0) {
		ret = r->nclks ?: -ENODEV;
		goto fail;
	}
	ret = clk_bulk_prepare_enable(r->nclks, r->clks);
	if (ret)
		goto fail;
	r->clocks_on = true;
	r->regs = ioremap(res->start, resource_size(res));
	ret = -ENOMEM;
	if (!r->regs)
		goto fail;
	for (i = 0; i < 2; i++) {
		r->buf[i] = dma_alloc_coherent(r->dev, r->size, &r->dma[i], GFP_KERNEL);
		if (!r->buf[i])
			goto fail;
	}
	/*
	 * Where a half-size frame is doubled to full size. dma_alloc_coherent()
	 * zeroes it, which is all the padding ever needs: soph_rot_double()
	 * writes the active pixels only, and the LDC reads the rest.
	 */
	r->wide = dma_alloc_coherent(r->dev, r->wide_pitch * r->rows,
				     &r->wide_dma, GFP_KERNEL);
	/* One source line, and one doubled line; cached, unlike either frame. */
	r->line = kmalloc(w / 2 * 4, GFP_KERNEL);
	r->pair = kmalloc(w * 3, GFP_KERNEL);
	if (!r->wide || !r->line || !r->pair)
		goto fail;
	ret = devm_add_action_or_reset(r->dev, soph_rot_destroy, r);
	return ret ? ERR_PTR(ret) : r;
fail:
	soph_rot_destroy(r);
	return ERR_PTR(ret);
}

/* The half-size framebuffer soph_rot_double() doubles before the rotation. */
static bool soph_rot_is_half(const struct soph_rot *r,
			     const struct drm_framebuffer *fb)
{
	return fb->width * 2 == r->width && fb->height * 2 == r->height;
}

int soph_rot_check(struct soph_rot *r, struct drm_plane_state *state)
{
	struct drm_framebuffer *fb = state->fb;
	struct drm_gem_dma_object *gem = drm_fb_dma_get_gem_obj(fb, 0);

	unsigned int cpp = fb->format->cpp[0];
	unsigned int pitch = fb->pitches[0];
	size_t size = (size_t)pitch * ALIGN(fb->height, 64);

	if ((fb->format->format != DRM_FORMAT_RGB888 &&
	     fb->format->format != DRM_FORMAT_XRGB8888 &&
	     fb->format->format != DRM_FORMAT_ARGB8888) ||
	    !gem || pitch < fb->width * cpp || pitch > r->pitch ||
	    fb->offsets[0])
		return -EINVAL;
	/*
	 * The CPU reads a half-size frame and the LDC never does, so the LDC's
	 * alignment, padding and 32-bit address do not apply to it. What does
	 * apply is that it has to be one of our own buffers: those come from
	 * dma_alloc_wc() and can be read straight through gem->vaddr, where an
	 * imported one may be cached and would need the dma-buf CPU-access
	 * calls around every read. Refused, it is composited into one of the
	 * compositor's own buffers instead, which is what this path wants.
	 */
	if (soph_rot_is_half(r, fb)) {
		if (drm_gem_is_imported(&gem->base) || !gem->vaddr ||
		    gem->base.size < (size_t)pitch * fb->height)
			return -EINVAL;
		return 0;
	}
	/* LDC reads the padding; reject unpadded buffers. */
	if (fb->width != r->width || fb->height != r->height ||
	    !IS_ALIGNED(pitch, 64) || gem->base.size < size ||
	    !IS_ALIGNED(gem->dma_addr, 64) ||
	    (u64)gem->dma_addr + size > BIT_ULL(32))
		return -EINVAL;
	return 0;
}

/*
 * Double a half-size frame 2x2 into the wide buffer.
 *
 * Plain pixel repetition, in front of the LDC, into a buffer shaped exactly
 * like a full-size packed RGB888 framebuffer: 0.15 MB read and 0.6 MB written
 * buys the whole rest of the path unchanged, where scaling the rotated planes
 * afterwards needs hardware this driver does not own.
 *
 * A framebuffer is write-combined, where a byte-at-a-time read is very slow
 * and a run of sequential writes is fast, so each source row is copied into a
 * cached line, doubled into a second cached line, and that line written to
 * both of its destination rows. Four-byte formats keep their first three
 * bytes, which is the B, G, R order the rest of this file already expects.
 */
static void soph_rot_double(struct soph_rot *r, struct drm_framebuffer *fb,
			    const void *vaddr)
{
	unsigned int cpp = fb->format->cpp[0];
	unsigned int len = r->width * 3;
	unsigned int x, y;

	for (y = 0; y < fb->height; y++) {
		const u8 *s = r->line;
		u8 *d = r->pair;

		memcpy(r->line, (const u8 *)vaddr + (size_t)y * fb->pitches[0],
		       (size_t)fb->width * cpp);
		for (x = 0; x < fb->width; x++, s += cpp, d += 6) {
			d[0] = d[3] = s[0];
			d[1] = d[4] = s[1];
			d[2] = d[5] = s[2];
		}
		memcpy((u8 *)r->wide + (size_t)2 * y * r->wide_pitch,
		       r->pair, len);
		memcpy((u8 *)r->wide + ((size_t)2 * y + 1) * r->wide_pitch,
		       r->pair, len);
	}
}

int soph_rot_run(struct soph_rot *r, struct drm_plane_state *state)
{
	struct drm_framebuffer *fb = state->fb;
	struct drm_gem_dma_object *gem = drm_fb_dma_get_gem_obj(fb, 0);
	bool half = soph_rot_is_half(r, fb);
	unsigned int next = !r->front;
	unsigned int pitch = fb->pitches[0];
	unsigned int rows = ALIGN(fb->height, 64);
	dma_addr_t src = gem->dma_addr;
	void __iomem *b = r->regs;
	u32 status;
	int ret;

	if (r->failed)
		return -EIO;
	/* Only a real frame start releases the old buffer. */
	ret = wait_for_completion_interruptible_timeout(&r->latched, msecs_to_jiffies(50));
	if (ret <= 0) {
		if (!ret)
			dev_err_ratelimited(r->dev, "rotation: no display latch; keeping front buffer\n");
		return ret ?: -ETIMEDOUT;
	}
	drm_gem_object_get(&gem->base);
	if (half) {
		/* From here on, the full-size frame's own path. */
		soph_rot_double(r, fb, gem->vaddr);
		pitch = r->wide_pitch;
		rows = r->rows;
		src = r->wide_dma;
	}
	wmb();
	writel(0, b + LDC_IRQEN); /* Poll raw status without asserting an IRQ. */
	writel(1, b + LDC_IRQCLR);
	writel(0, b + LDC_DATA_FORMAT); /* Y400, bypass the mesh/interpolator. */
	writel(1, b + LDC_RAS_MODE);
	writel(pitch, b + LDC_RAS_XSIZE);
	writel(rows, b + LDC_RAS_YSIZE);
	writel(0, b + LDC_MAP_BASE);
	writel(1, b + LDC_MAP_BYPASS);
	writel(src >> 6, b + LDC_SRC_BASE_Y);
	writel(0, b + LDC_SRC_BASE_C);
	writel(pitch, b + LDC_SRC_XSIZE);
	writel(rows, b + LDC_SRC_YSIZE);
	writel(0, b + LDC_SRC_XSTART);
	writel(pitch - 1, b + LDC_SRC_XEND); /* Rotate the padded grid. */
	writel(0, b + LDC_SRC_BG);
	writel(r->dma[next] >> 6, b + LDC_DST_BASE_Y);
	writel(0, b + LDC_DST_BASE_C);
	writel(r->angle == 90 ? 3 : 2, b + LDC_DST_MODE);
	writel(0, b + LDC_SB_MODE);
	writel(0, b + LDC_SB_SET_STR);
	writel(1, b + LDC_SB_SW_CLR);
	writel(0, b + LDC_DIR);
	writel(0, b + LDC_INT_SEL);
	writel(1, b + LDC_START);
	ret = readl_poll_timeout(b + LDC_IRQSTAT, status, status & 1, 20, 50000);
	if (ret) {
		r->failed = true;
		dev_err(r->dev, "rotation timed out: DMA memory and clocks retained until reboot\n");
		return ret;
	}
	writel(1, b + LDC_IRQCLR);
	dma_rmb();
	drm_gem_object_put(&gem->base);
	r->front = next;
	r->front_pitch = pitch;
	r->front_width = half ? r->width : fb->width;
	r->front_height = half ? r->height : fb->height;
	r->front_rows = rows;
	r->front_cpp = half ? 3 : fb->format->cpp[0];
	r->ready = true;
	return 0;
}

bool soph_rot_mem(struct soph_rot *r, struct sclr_mem *mem)
{
	dma_addr_t base = r->dma[r->front];
	unsigned int row = r->front_rows;

	if (!r->ready)
		return false;
	memset(mem, 0, sizeof(*mem));
	if (r->angle == 90) {
		mem->addr0 = base + 2 * row;
		mem->addr1 = base + row;
		mem->addr2 = base;
		mem->start_x = row - r->front_height;
	} else {
		/* Reverse byte order puts X/A before R in four-byte pixels. */
		base += (r->front_pitch - r->front_cpp * r->front_width +
			 r->front_cpp - 3) * row;
		mem->addr0 = base;
		mem->addr1 = base + row;
		mem->addr2 = base + 2 * row;
	}
	mem->pitch_y = mem->pitch_c = r->front_cpp * row;
	mem->width = r->front_height;
	mem->height = r->front_width;
	return true;
}

void soph_rot_stage(struct soph_rot *r)
{
	if (!r)
		return;
	reinit_completion(&r->latched);
}

void soph_rot_latched(struct soph_rot *r)
{
	if (!r)
		return;
	complete_all(&r->latched);
}

void soph_rot_retain(struct soph_rot *r)
{
	r->failed = true;
}
