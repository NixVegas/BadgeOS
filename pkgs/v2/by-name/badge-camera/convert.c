#include "convert.h"

#include <string.h>

/* The widest output, and the widest source, the averaging path keeps arrays for. */
#define MAX_OUT 2048
#define MAX_SRC 4096

static inline uint8_t clamp8(int v)
{
	return v < 0 ? 0 : v > 255 ? 255 : (uint8_t)v;
}

void nv21_cover_xrgb(const uint8_t *y, const uint8_t *vu, unsigned stride, unsigned sw, unsigned sh,
		     uint32_t *dst, unsigned dst_pitch, unsigned dw, unsigned dh)
{
	/* Source window with the destination's aspect, centered. */
	unsigned cw = sw, ch = sh, x0 = 0, y0 = 0;

	if (!dw || !dh)
		return;
	if ((uint64_t)sw * dh > (uint64_t)sh * dw) {
		cw = (unsigned)((uint64_t)sh * dw / dh);
		x0 = (sw - cw) / 2;
	} else {
		ch = (unsigned)((uint64_t)sw * dh / dw);
		y0 = (sh - ch) / 2;
	}
	/* 16.16 steps through the window, sampling pixel centers. */
	uint32_t xs = (uint32_t)(((uint64_t)cw << 16) / dw), ys = (uint32_t)(((uint64_t)ch << 16) / dh);
	uint32_t fy = ys / 2;

	for (unsigned oy = 0; oy < dh; oy++, fy += ys) {
		unsigned sy = y0 + (fy >> 16);
		const uint8_t *yr = y + (size_t)sy * stride;
		const uint8_t *cr = vu + (size_t)(sy / 2) * stride;
		uint32_t *out = dst + (size_t)oy * dst_pitch;
		uint32_t fx = xs / 2;

		for (unsigned ox = 0; ox < dw; ox++, fx += xs) {
			unsigned sx = x0 + (fx >> 16);
			int c = (yr[sx] - 16) * 298;
			const uint8_t *p = cr + (sx & ~1u);
			int v = p[0] - 128, u = p[1] - 128;
			uint8_t r = clamp8((c + 409 * v + 128) >> 8);
			uint8_t g = clamp8((c - 100 * u - 208 * v + 128) >> 8);
			uint8_t b = clamp8((c + 516 * u + 128) >> 8);

			out[ox] = 0xff000000u | (uint32_t)r << 16 | (uint32_t)g << 8 | b;
		}
	}
}

/* Box-average source pixels to reduce downsampling aliasing and noise. Use a
 * cached copy: this reads every source pixel and is expensive on the
 * write-combined capture mapping. */
void nv21_cover_box(const uint8_t *y, const uint8_t *vu, unsigned stride, unsigned sw, unsigned sh,
		    unsigned yscale, uint32_t *dst, unsigned dst_pitch, unsigned dw, unsigned dh)
{
	/* One set of column bounds and accumulators, reused down the picture. */
	static unsigned bound[MAX_OUT + 1];
	static uint32_t accy[MAX_OUT], accu[MAX_OUT], accv[MAX_OUT];
	static uint16_t colof[MAX_SRC];
	unsigned cw = sw, ch = sh, x0 = 0, y0 = 0, ox, oy;
	/* The rows may have been thinned, so the picture is this much taller than it is. */
	unsigned eh = sh * (yscale ? yscale : 1);

	if (!dw || !dh)
		return;
	if (dw > MAX_OUT || sw > MAX_SRC) {
		/* Wider than the accumulators: no averaging, but still a picture. */
		nv21_cover_xrgb(y, vu, stride, sw, sh, dst, dst_pitch, dw, dh);
		return;
	}
	if ((uint64_t)sw * dh > (uint64_t)eh * dw) {
		cw = (unsigned)((uint64_t)eh * dw / dh);
		x0 = (sw - cw) / 2;
	} else {
		ch = (unsigned)((uint64_t)sw * dh / dw / (eh / sh));
		if (ch > sh)
			ch = sh;
		y0 = (sh - ch) / 2;
	}
	/* Chroma is one sample per two pixels each way, so keep the bounds even. */
	for (ox = 0; ox <= dw; ox++) {
		unsigned b = x0 + (unsigned)((uint64_t)ox * cw / dw);

		bound[ox] = b & ~1u;
	}
	if (bound[dw] > sw)
		bound[dw] = sw & ~1u;
	/* Precompute source-to-output columns for sequential row accumulation. */
	x0 = bound[0];
	cw = bound[dw] - x0;
	for (ox = 0; ox < dw; ox++) {
		unsigned sx;

		for (sx = bound[ox]; sx < bound[ox + 1]; sx++)
			colof[sx - x0] = (uint16_t)ox;
	}

	for (oy = 0; oy < dh; oy++) {
		unsigned sy0 = y0 + (unsigned)((uint64_t)oy * ch / dh);
		unsigned sy1 = y0 + (unsigned)((uint64_t)(oy + 1) * ch / dh);
		uint32_t *out = dst + (size_t)oy * dst_pitch;
		unsigned sy, i, nrows, n, cn;

		sy0 &= ~1u;
		sy1 &= ~1u;
		if (sy1 <= sy0)
			sy1 = sy0 + 2;
		if (sy1 > sh)
			sy1 = sh & ~1u;
		nrows = sy1 - sy0;
		memset(accy, 0, dw * sizeof(*accy));
		memset(accu, 0, dw * sizeof(*accu));
		memset(accv, 0, dw * sizeof(*accv));

		for (sy = sy0; sy < sy1; sy++) {
			const uint8_t *yr = y + (size_t)sy * stride + x0;

			for (i = 0; i < cw; i++)
				accy[colof[i]] += yr[i];
			/* One chroma pair per two columns, on even rows only. */
			if (sy & 1)
				continue;
			{
				const uint8_t *cr = vu + (size_t)(sy / 2) * stride + x0;

				for (i = 0; i + 1 < cw; i += 2) {
					accv[colof[i]] += cr[i];
					accu[colof[i]] += cr[i + 1];
				}
			}
		}

		for (ox = 0; ox < dw; ox++) {
			unsigned lo = bound[ox], hi = bound[ox + 1];
			int c, u, v;
			uint8_t r, g, b;

			if (hi <= lo)
				continue;
			n = (hi - lo) * nrows;
			cn = ((hi - lo) / 2) * (nrows / 2);
			if (!n || !cn)
				continue;
			c = ((int)(accy[ox] / n) - 16) * 298;
			v = (int)(accv[ox] / cn) - 128;
			u = (int)(accu[ox] / cn) - 128;
			r = clamp8((c + 409 * v + 128) >> 8);
			g = clamp8((c - 100 * u - 208 * v + 128) >> 8);
			b = clamp8((c + 516 * u + 128) >> 8);
			out[ox] = 0xff000000u | (uint32_t)r << 16 | (uint32_t)g << 8 | b;
		}
	}
}

/* Likewise for the QR reader's gray copy: averaging the block rather than picking a
 * pixel out of it, which also takes the noise off the thresholding. */
void nv21_luma_box(const uint8_t *y, unsigned stride, unsigned sw, unsigned sh, uint8_t *dst,
		   unsigned qw, unsigned qh)
{
	unsigned ox, oy;

	for (oy = 0; oy < qh; oy++) {
		unsigned sy0 = (unsigned)((uint64_t)oy * sh / qh);
		unsigned sy1 = (unsigned)((uint64_t)(oy + 1) * sh / qh);
		uint8_t *out = dst + (size_t)oy * qw;

		if (sy1 <= sy0)
			sy1 = sy0 + 1;
		for (ox = 0; ox < qw; ox++) {
			unsigned sx0 = (unsigned)((uint64_t)ox * sw / qw);
			unsigned sx1 = (unsigned)((uint64_t)(ox + 1) * sw / qw);
			uint32_t acc = 0;
			unsigned sx, sy, n;

			if (sx1 <= sx0)
				sx1 = sx0 + 1;
			for (sy = sy0; sy < sy1; sy++) {
				const uint8_t *row = y + (size_t)sy * stride;

				for (sx = sx0; sx < sx1; sx++)
					acc += row[sx];
			}
			n = (sx1 - sx0) * (sy1 - sy0);
			out[ox] = (uint8_t)(acc / n);
		}
	}
}
