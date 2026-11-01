/* effects.h: the visual parts.
 *
 * Everything renders into a 32-bit XRGB buffer at INTERNAL_W x INTERNAL_H and is
 * scaled up on blit, so the per-pixel cost stays sane on a 1 GHz A53. Each part
 * takes normalised part-local time (0..1) plus a beat phase so it can punch on
 * the kick without knowing anything about the song.
 */
#ifndef BADGE_EFFECTS_H
#define BADGE_EFFECTS_H

#include <stdint.h>
#include <math.h>

#define IW 640
#define IH 360

/* shared cheap math */
static float g_sin[1024];
static void  trig_init(void) { for (int i = 0; i < 1024; i++) g_sin[i] = sinf((float)i * 6.2831853f / 1024.0f); }
static inline float fsin(float t) { int i = (int)(t * 162.9747f) & 1023; return g_sin[i]; }
static inline float fcos(float t) { int i = (int)(t * 162.9747f + 256.0f) & 1023; return g_sin[i]; }

static inline uint32_t rgb(int r, int g, int b)
{
	r = r < 0 ? 0 : r > 255 ? 255 : r;
	g = g < 0 ? 0 : g > 255 ? 255 : g;
	b = b < 0 ? 0 : b > 255 ? 255 : b;
	return ((uint32_t)r << 16) | ((uint32_t)g << 8) | (uint32_t)b;
}

/* palette: deep blue -> cyan -> white, with a warm kicker. Demoscene staple. */
static uint32_t g_pal[256];
static void pal_init(void)
{
	for (int i = 0; i < 256; i++) {
		float t = (float)i / 255.0f;
		int r = (int)(255.0f * (t < 0.55f ? t * 0.35f : (t - 0.55f) * 2.2f + 0.19f));
		int g = (int)(255.0f * (t < 0.30f ? t * 1.10f : 0.33f + (t - 0.30f) * 0.95f));
		int b = (int)(255.0f * (t < 0.65f ? 0.25f + t * 1.05f : 0.93f));
		g_pal[i] = rgb(r, g, b);
	}
}

/* part 1: plasma */
/* The radial term is constant per pixel, so it is tabulated once: that removes
 * a sqrtf from the inner loop, which matters a lot on a single 1 GHz A53. */
static float *plasma_r;
static void plasma_init(void)
{
	static float r[IW * IH];

	plasma_r = r;
	for (int y = 0; y < IH; y++)
		for (int x = 0; x < IW; x++) {
			float fx = (float)x * 0.017f, fy = (float)y * 0.021f;

			r[y * IW + x] = sqrtf(fx * fx + fy * fy) * 1.3f;
		}
}
static void fx_plasma(uint32_t *fb, float t, float punch)
{
	float a = t * 1.7f, b = t * 2.3f;
	float amp = 31.0f + punch * 12.0f;

	for (int y = 0; y < IH; y++) {
		float fy = (float)y * 0.021f;
		float sy = fsin(fy + b);
		uint32_t *row = fb + (size_t)y * IW;
		const float *rr = plasma_r + (size_t)y * IW;

		for (int x = 0; x < IW; x++) {
			float fx = (float)x * 0.017f;
			float v = fsin(fx + a) + sy
				+ fsin((fx + fy + a) * 0.7f)
				+ fsin(rr[x] - b);
			int i = (int)((v + 4.0f) * amp) & 255;

			row[x] = g_pal[i];
		}
	}
}

/* part 2: tunnel */
static int16_t *tun_d, *tun_a;
static void tunnel_init(void)
{
	static int16_t d[IW * IH], a[IW * IH];

	tun_d = d; tun_a = a;
	for (int y = 0; y < IH; y++)
		for (int x = 0; x < IW; x++) {
			float dx = (float)(x - IW / 2), dy = (float)(y - IH / 2);
			float r  = sqrtf(dx * dx + dy * dy) + 0.0001f;

			d[y * IW + x] = (int16_t)(2600.0f / r);
			a[y * IW + x] = (int16_t)((atan2f(dy, dx) / 6.2831853f + 0.5f) * 255.0f);
		}
}
static void fx_tunnel(uint32_t *fb, float t, float punch)
{
	int sh = (int)(t * 150.0f), ro = (int)(t * 60.0f);

	for (int y = 0; y < IH; y++) {
		uint32_t *row = fb + (size_t)y * IW;
		const int16_t *dd = tun_d + (size_t)y * IW, *aa = tun_a + (size_t)y * IW;

		for (int x = 0; x < IW; x++) {
			int u = (dd[x] + sh) & 63, v = (aa[x] + ro) & 63;
			int c = ((u ^ v) & 32) ? 210 : 70;      /* checker */
			int fade = dd[x] > 255 ? 255 : dd[x];

			c = c * (255 - fade) / 255 + (int)(punch * 45.0f);
			row[x] = g_pal[c < 0 ? 0 : c > 255 ? 255 : c];
		}
	}
}

/* part 3: rotozoomer */
static void fx_roto(uint32_t *fb, float t, float punch)
{
	float z = 1.4f + fsin(t * 0.9f) * 0.8f + punch * 0.5f;
	float c = fcos(t * 0.6f) * z, s = fsin(t * 0.6f) * z;

	for (int y = 0; y < IH; y++) {
		float dy = (float)(y - IH / 2);
		float ux =  -320.0f * c - dy * s + t * 40.0f;
		float uy =   320.0f * s - dy * c;
		uint32_t *row = fb + (size_t)y * IW;

		for (int x = 0; x < IW; x++) {
			int tx = (int)ux & 127, ty = (int)uy & 127;
			int chk = ((tx ^ ty) & 64) ? 1 : 0;
			int d = (tx & 63) ^ (ty & 63);

			row[x] = chk ? g_pal[128 + (d & 127)] : g_pal[(d * 2) & 255];
			ux += c; uy -= s;
		}
	}
}

/* part 4: starfield + metaballs */
#define NSTAR 512
static struct { float x, y, z; } stars[NSTAR];
static void stars_init(void)
{
	uint32_t r = 12345;
	for (int i = 0; i < NSTAR; i++) {
		r = r * 1664525u + 1013904223u; stars[i].x = (float)((int)(r >> 9) % 2000 - 1000);
		r = r * 1664525u + 1013904223u; stars[i].y = (float)((int)(r >> 9) % 2000 - 1000);
		r = r * 1664525u + 1013904223u; stars[i].z = (float)((int)(r >> 9) % 1800 + 20);
	}
}
static void fx_stars(uint32_t *fb, float t, float punch)
{
	float speed = 260.0f + punch * 700.0f;

	for (int i = 0; i < IW * IH; i++)
		fb[i] = 0;

	for (int i = 0; i < NSTAR; i++) {
		int px, py, b;

		stars[i].z -= speed * (1.0f / 60.0f);
		if (stars[i].z < 20.0f) stars[i].z += 1800.0f;
		px = IW / 2 + (int)(stars[i].x * 320.0f / stars[i].z);
		py = IH / 2 + (int)(stars[i].y * 320.0f / stars[i].z);
		if (px < 1 || px >= IW - 1 || py < 1 || py >= IH - 1)
			continue;
		b = 255 - (int)(stars[i].z * 0.14f);
		if (b < 0) b = 0;
		fb[py * IW + px] = rgb(b, b, b > 200 ? 255 : b + 40);
		if (b > 170) {                       /* bloom the near ones */
			fb[py * IW + px + 1] = rgb(b / 3, b / 3, b / 2);
			fb[(py + 1) * IW + px] = rgb(b / 3, b / 3, b / 2);
		}
	}
	(void)t;
}

/* part 5: raymarched torus (the money shot).
 * Budget: one A53 core. The naive full-res 24-step march measured 267 ms/frame
 * (3.7 fps), so this marches at half resolution into RW x RH and point-doubles
 * on the way out, with the ray directions tabulated once; the camera is fixed
 * and only the scene rotates, so per-pixel direction is a constant.
 */
#define RW (IW / 2)
#define RH (IH / 2)
#define RSTEPS 14

static float *rm_dx, *rm_dy, *rm_dz;
static void raymarch_init(void)
{
	static float dxs[RW * RH], dys[RW * RH], dzs[RW * RH];

	rm_dx = dxs; rm_dy = dys; rm_dz = dzs;
	for (int y = 0; y < RH; y++)
		for (int x = 0; x < RW; x++) {
			float u = ((float)x / RW - 0.5f) * 3.55f;
			float v = ((float)y / RH - 0.5f) * 2.0f;
			float l = sqrtf(u * u + v * v + 1.0f);
			int   i = y * RW + x;

			dxs[i] = u / l; dys[i] = v / l; dzs[i] = 1.0f / l;
		}
}

static void fx_raymarch(uint32_t *fb, float t, float punch)
{
	static uint32_t small[RW * RH];
	float ca = fcos(t * 0.5f), sa = fsin(t * 0.5f);
	float minor = 0.34f + punch * 0.10f;

	for (int y = 0; y < RH; y++) {
		uint32_t *row = small + (size_t)y * RW;

		for (int x = 0; x < RW; x++) {
			int   i = y * RW + x;
			float dx = rm_dx[i], dy = rm_dy[i], dz = rm_dz[i];
			float d = 0.0f;
			int   s, hit = 0;

			for (s = 0; s < RSTEPS; s++) {
				float qx = dx * d, qy = dy * d, qz = -3.2f + dz * d;
				float tw = qx * ca - qz * sa, tz = qx * sa + qz * ca;
				float q  = sqrtf(tw * tw + qy * qy) - 1.0f;
				float e  = sqrtf(q * q + tz * tz) - minor;

				if (e < 0.02f) { hit = 1; break; }
				d += e;
				if (d > 9.0f) break;
			}
			if (hit) {
				int c = 255 - (int)(d * 26.0f) + (int)(punch * 40.0f);

				row[x] = g_pal[c < 0 ? 0 : c > 255 ? 255 : c];
			} else {
				int g = (int)(14.0f + 10.0f * fsin((float)y * 0.10f + t));

				row[x] = rgb(g / 3, g / 2, g);
			}
		}
	}
	/* point-double into the full canvas */
	for (int y = 0; y < RH; y++) {
		const uint32_t *s = small + (size_t)y * RW;
		uint32_t *d0 = fb + (size_t)(y * 2) * IW, *d1 = d0 + IW;

		for (int x = 0; x < RW; x++) {
			uint32_t p = s[x];

			d0[x * 2] = d0[x * 2 + 1] = p;
			d1[x * 2] = d1[x * 2 + 1] = p;
		}
	}
}

#endif
