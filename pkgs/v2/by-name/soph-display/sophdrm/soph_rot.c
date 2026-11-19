// SPDX-License-Identifier: GPL-2.0
/* Rotate RGB bytes as Y400; DISP reads the result as three interleaved planes. */
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
	unsigned int front_pitch, front_cpp;
	size_t size;
	void *buf[2];
	dma_addr_t dma[2];
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
	ret = devm_add_action_or_reset(r->dev, soph_rot_destroy, r);
	return ret ? ERR_PTR(ret) : r;
fail:
	soph_rot_destroy(r);
	return ERR_PTR(ret);
}

int soph_rot_check(struct soph_rot *r, struct drm_plane_state *state)
{
	struct drm_framebuffer *fb = state->fb;
	struct drm_gem_dma_object *gem = drm_fb_dma_get_gem_obj(fb, 0);

	unsigned int cpp = fb->format->cpp[0];
	unsigned int pitch = fb->pitches[0];
	size_t size = (size_t)pitch * r->rows;

	/* LDC reads the padding; reject unpadded buffers. */
	if ((fb->format->format != DRM_FORMAT_RGB888 &&
	     fb->format->format != DRM_FORMAT_XRGB8888 &&
	     fb->format->format != DRM_FORMAT_ARGB8888) ||
	    fb->width != r->width || fb->height != r->height ||
	    !IS_ALIGNED(pitch, 64) || pitch < r->width * cpp ||
	    pitch > r->pitch || fb->offsets[0] ||
	    !gem || gem->base.size < size ||
	    !IS_ALIGNED(gem->dma_addr, 64) ||
	    (u64)gem->dma_addr + size > BIT_ULL(32))
		return -EINVAL;
	return 0;
}

int soph_rot_run(struct soph_rot *r, struct drm_plane_state *state)
{
	struct drm_gem_dma_object *gem = drm_fb_dma_get_gem_obj(state->fb, 0);
	unsigned int next = !r->front;
	unsigned int pitch = state->fb->pitches[0];
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
	wmb();
	writel(0, b + LDC_IRQEN); /* Poll raw status without asserting an IRQ. */
	writel(1, b + LDC_IRQCLR);
	writel(0, b + LDC_DATA_FORMAT); /* Y400, bypass the mesh/interpolator. */
	writel(1, b + LDC_RAS_MODE);
	writel(pitch, b + LDC_RAS_XSIZE);
	writel(r->rows, b + LDC_RAS_YSIZE);
	writel(0, b + LDC_MAP_BASE);
	writel(1, b + LDC_MAP_BYPASS);
	writel(gem->dma_addr >> 6, b + LDC_SRC_BASE_Y);
	writel(0, b + LDC_SRC_BASE_C);
	writel(pitch, b + LDC_SRC_XSIZE);
	writel(r->rows, b + LDC_SRC_YSIZE);
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
	r->front_cpp = state->fb->format->cpp[0];
	r->ready = true;
	return 0;
}

bool soph_rot_mem(struct soph_rot *r, struct sclr_mem *mem)
{
	dma_addr_t base = r->dma[r->front];
	unsigned int row = r->rows;

	if (!r->ready)
		return false;
	memset(mem, 0, sizeof(*mem));
	if (r->angle == 90) {
		mem->addr0 = base + 2 * row;
		mem->addr1 = base + row;
		mem->addr2 = base;
		mem->start_x = row - r->height;
	} else {
		/* Reverse byte order puts X/A before R in four-byte pixels. */
		base += (r->front_pitch - r->front_cpp * r->width +
			 r->front_cpp - 3) * row;
		mem->addr0 = base;
		mem->addr1 = base + row;
		mem->addr2 = base + 2 * row;
	}
	mem->pitch_y = mem->pitch_c = r->front_cpp * row;
	mem->width = r->height;
	mem->height = r->width;
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
