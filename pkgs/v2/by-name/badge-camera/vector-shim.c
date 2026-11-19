/* Scalar replacements for libisp_algo.so helpers while the kernel disables
 * T-Head vector 0.7.1. -rdynamic exports these executable symbols to override
 * the vendor PLT calls. rvv_memcpy and rvv_memset use libc signatures and
 * return the destination. Vendor memset executes a vector instruction even
 * when the length is zero. */
#include <string.h>

/*
 * Only RISC-V needs any of this. The ARM core's NEON is never gated, so the vendor's own
 * versions of these functions run there, and a definition here would quietly take their
 * place: the executable is searched before the libraries it links.
 */
#ifdef __riscv

void *rvv_memcpy(void *dst, const void *src, size_t n);
void *rvv_memset(void *s, int c, size_t n);

void *rvv_memcpy(void *dst, const void *src, size_t n)
{
	return memcpy(dst, src, n);
}

void *rvv_memset(void *s, int c, size_t n)
{
	return memset(s, c, n);
}

/* IIR helpers smooth successive curves using 32-bit history and 8-bit (U8) or
 * 16-bit (U10) input/output. Vendor ABI offsets are checked below. Weights clamp
 * to 1024; values <=1 disable smoothing. disMain and isp_algo_motion_main are
 * success-returning no-op overrides for stabilization and motion estimation. */
#include <stddef.h>
#include <stdint.h>

struct iir_ctx {
	void *in;		/* +0  */
	uint32_t *history;	/* +8  */
	void *out;		/* +16 */
	uint16_t len;		/* +24 */
	uint16_t weight;	/* +26 */
};

_Static_assert(offsetof(struct iir_ctx, history) == 8, "history must sit at +8");
_Static_assert(offsetof(struct iir_ctx, out) == 16, "out must sit at +16");
_Static_assert(offsetof(struct iir_ctx, len) == 24, "len must sit at +24");
_Static_assert(offsetof(struct iir_ctx, weight) == 26, "weight must sit at +26");

int IIR_U8_Once(struct iir_ctx *c);
int IIR_U10_Once(struct iir_ctx *c);
int disMain(void *a, void *b, void *c, void *d);
int isp_algo_motion_main(void *a, void *b, void *c, void *d);

/* history[i] = ((in[i] << 10) + w * history[i]) / (w + 1), out[i] = (history[i] + 512) >> 10 */
static inline uint32_t iir_step(struct iir_ctx *c, unsigned w, unsigned i, uint32_t in)
{
	if (w <= 1) {
		c->history[i] = in << 10;
		return in;
	}
	c->history[i] = ((in << 10) + w * c->history[i]) / (w + 1);
	return (c->history[i] + 512) >> 10;
}

int IIR_U8_Once(struct iir_ctx *c)
{
	unsigned w = c->weight > 1024 ? 1024 : c->weight;
	const uint8_t *in = c->in;
	uint8_t *out = c->out;

	for (unsigned i = 0; i < c->len; i++)
		out[i] = (uint8_t)iir_step(c, w, i, in[i]);
	return 0;
}

int IIR_U10_Once(struct iir_ctx *c)
{
	unsigned w = c->weight > 1024 ? 1024 : c->weight;
	const uint16_t *in = c->in;
	uint16_t *out = c->out;

	for (unsigned i = 0; i < c->len; i++)
		out[i] = (uint16_t)iir_step(c, w, i, in[i]);
	return 0;
}

int disMain(void *a, void *b, void *c, void *d)
{
	(void)a; (void)b; (void)c; (void)d;
	return 0;
}

int isp_algo_motion_main(void *a, void *b, void *c, void *d)
{
	(void)a; (void)b; (void)c; (void)d;
	return 0;
}

#endif /* __riscv */
