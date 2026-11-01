/* synth.h: tiny tracker-ish softsynth for the badge demo.
 *
 * Fixed 48 kHz stereo S16LE. No allocation, no libm in the hot path: everything
 * is integer or float-on-stack, so it runs happily on the A53 alongside the
 * renderer. One oscillator bank + a 4-track pattern sequencer, which is enough
 * for a demo soundtrack and small enough to read in one sitting.
 */
#ifndef BADGE_SYNTH_H
#define BADGE_SYNTH_H

#include <stdint.h>
#include <string.h>

#define SR          48000
#define NCHAN       5           /* bass, lead, arp, pad, drums */
#define ROWS        16          /* rows per pattern */

enum wave { W_SQUARE, W_SAW, W_TRI, W_NOISE, W_SINE };

struct voice {
	float   phase, step;        /* oscillator */
	float   env, env_d;         /* linear-decay envelope */
	float   vol;
	enum wave wave;
	float   duty;               /* square only */
	float   lp, lp_k;           /* one-pole low-pass */
	uint32_t rng;
};

struct song {
	int   bpm, rows_per_beat;
	int   npat;                 /* patterns in the order list */
	const uint8_t *order;       /* npat entries -> pattern index */
	const uint8_t (*pat)[NCHAN][ROWS];  /* note numbers, 0 = rest */
};

struct synth {
	struct voice v[NCHAN];
	const struct song *s;
	int      row, ord;
	uint32_t samples_to_row, row_len;
	uint32_t t;                 /* samples since start */
};

static inline float note_hz(int n)      /* n = semitones above A1 (55 Hz) */
{
	/* 2^(n/12) via exp2 approximation good enough for music */
	float x = (float)n / 12.0f;
	int   i = (int)x;
	float f = x - (float)i;
	/* cubic fit of 2^f on [0,1) */
	float p = 1.0f + f * (0.6931472f + f * (0.2402265f + f * 0.0555041f));
	return 55.0f * p * (float)(1u << (i < 0 ? 0 : (i > 12 ? 12 : i)));
}

static inline float osc(struct voice *v)
{
	float o;

	switch (v->wave) {
	case W_SQUARE: o = (v->phase < v->duty) ? 1.0f : -1.0f; break;
	case W_SAW:    o = 2.0f * v->phase - 1.0f;              break;
	case W_TRI:    o = 4.0f * (v->phase < 0.5f ? v->phase : 1.0f - v->phase) - 1.0f; break;
	case W_SINE: {
		/* parabolic sine, plenty clean for a chip tune */
		float p = v->phase * 2.0f - 1.0f;
		o = 4.0f * p * (1.0f - (p < 0 ? -p : p));
		break;
	}
	default:
		v->rng = v->rng * 1664525u + 1013904223u;
		o = (float)((int32_t)(v->rng >> 8) & 0xffff) / 32768.0f - 1.0f;
		break;
	}
	v->phase += v->step;
	if (v->phase >= 1.0f)
		v->phase -= 1.0f;

	v->lp += v->lp_k * (o - v->lp);         /* tame the aliasing */
	o = v->lp;

	o *= v->env * v->vol;
	v->env -= v->env_d;
	if (v->env < 0.0f)
		v->env = 0.0f;
	return o;
}

static void synth_init(struct synth *sy, const struct song *s)
{
	static const struct { enum wave w; float vol, duty, lpk, dec; } cfg[NCHAN] = {
		{ W_SQUARE, 0.32f, 0.50f, 0.35f, 0.000018f },  /* bass   */
		{ W_SAW,    0.22f, 0.50f, 0.22f, 0.000011f },  /* lead   */
		{ W_SQUARE, 0.15f, 0.25f, 0.45f, 0.000075f },  /* arp    */
		{ W_TRI,    0.18f, 0.50f, 0.10f, 0.0000045f }, /* pad    */
		{ W_NOISE,  0.30f, 0.50f, 0.70f, 0.000130f },  /* drums  */
	};
	int i;

	memset(sy, 0, sizeof(*sy));
	sy->s = s;
	for (i = 0; i < NCHAN; i++) {
		sy->v[i].wave = cfg[i].w;
		sy->v[i].vol  = cfg[i].vol;
		sy->v[i].duty = cfg[i].duty;
		sy->v[i].lp_k = cfg[i].lpk;
		sy->v[i].env_d = cfg[i].dec;
		sy->v[i].rng  = 0x1234567u + (uint32_t)i * 7919u;
	}
	sy->row_len = (uint32_t)((60.0 * SR) / (s->bpm * s->rows_per_beat));
	sy->samples_to_row = 0;
	sy->row = -1;
	sy->ord = 0;
}

static void synth_row(struct synth *sy)
{
	const struct song *s = sy->s;
	int c;

	if (++sy->row >= ROWS) {
		sy->row = 0;
		if (++sy->ord >= s->npat)
			sy->ord = 0;        /* loop forever; it's a demo */
	}
	for (c = 0; c < NCHAN; c++) {
		uint8_t n = s->pat[s->order[sy->ord]][c][sy->row];

		if (!n)
			continue;
		sy->v[c].step  = note_hz((int)n - 24) / (float)SR;
		sy->v[c].phase = 0.0f;
		sy->v[c].env   = 1.0f;
	}
}

/* Render `n` stereo frames. Returns the current row so visuals can sync. */
static int synth_render(struct synth *sy, int16_t *out, int n)
{
	int i, c;

	for (i = 0; i < n; i++) {
		float l = 0.0f, r = 0.0f;

		if (sy->samples_to_row == 0) {
			synth_row(sy);
			sy->samples_to_row = sy->row_len;
		}
		sy->samples_to_row--;

		for (c = 0; c < NCHAN; c++) {
			float o = osc(&sy->v[c]);
			/* cheap stereo spread: arp left, lead right */
			float pan = (c == 2) ? 0.30f : (c == 1) ? 0.70f : 0.5f;

			l += o * (1.0f - pan);
			r += o * pan;
		}
		l *= 1.7f; r *= 1.7f;
		if (l >  1.0f) l =  1.0f;
		if (l < -1.0f) l = -1.0f;
		if (r >  1.0f) r =  1.0f;
		if (r < -1.0f) r = -1.0f;
		out[2 * i]     = (int16_t)(l * 32000.0f);
		out[2 * i + 1] = (int16_t)(r * 32000.0f);
		sy->t++;
	}
	return sy->row;
}

#endif
