// pixman_nv12_to_xrgb8888_c, pixman_nv12_to_xrgb8888 (NEON on aarch64) and
// pixman_nv12_to_xrgb8888_staged (render/pixman/nv12.c in the patched wlroots)
// against a floating-point BT.601 limited-range reference, and the last two
// against pixman_nv12_to_xrgb8888_c byte for byte.
//
// Each case converts frames of one size with each converter, with Y, UV and
// destination strides larger than the row, and checks:
//   - every channel is within 1 of the rounded, clamped reference;
//   - with U = V = 128 the output is grey (R = G = B);
//   - the X byte is 0xff;
//   - no word outside the destination rectangle changes (row padding, and
//     guard words before and after the buffer).
// The patterns: every Y from 0 to 255 with U = V = 128; a 16-step U x V grid
// at Y = 16, 128 and 235; random noise frames, also at every width 1-40 and
// height 1-4 for the tails of the vector kernel.

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "render/pixman/nv12.h"

#define GUARD 0xdeadbeefu
#define GUARD_WORDS 64

struct frame {
	int width, height;
	size_t y_stride, uv_stride, dst_stride; // bytes
	uint8_t *y, *uv;
	uint32_t *dst_words; // GUARD_WORDS + rows + GUARD_WORDS
	uint32_t *ref_words; // pixman_nv12_to_xrgb8888_c()'s output, laid out alike
	size_t dst_len; // words in dst_words and ref_words
	uint32_t *dst;
};

typedef bool (*convert_fn)(const uint8_t *y, size_t y_stride,
	const uint8_t *uv, size_t uv_stride, uint32_t *dst, size_t dst_stride,
	int width, int height);

static bool convert_c(const uint8_t *y, size_t y_stride,
		const uint8_t *uv, size_t uv_stride, uint32_t *dst, size_t dst_stride,
		int width, int height) {
	pixman_nv12_to_xrgb8888_c(y, y_stride, uv, uv_stride, dst, dst_stride,
		width, height);
	return true;
}

static bool convert_kernel(const uint8_t *y, size_t y_stride,
		const uint8_t *uv, size_t uv_stride, uint32_t *dst, size_t dst_stride,
		int width, int height) {
	pixman_nv12_to_xrgb8888(y, y_stride, uv, uv_stride, dst, dst_stride,
		width, height);
	return true;
}

static const struct {
	const char *name;
	convert_fn convert;
} converters[] = {
	{ "c", convert_c },
	{ "kernel", convert_kernel },
	{ "staged", pixman_nv12_to_xrgb8888_staged },
};

struct stats {
	int max_err[3];
	long pixels;
	long differing; // words unlike pixman_nv12_to_xrgb8888_c()'s
	long failures;
};

static uint32_t rng_state = 0x12345678u;

static uint32_t rng(void) {
	rng_state = rng_state * 1664525u + 1013904223u;
	return rng_state >> 8;
}

static int ref_channel(double v) {
	long r = lround(v);
	return r < 0 ? 0 : r > 255 ? 255 : (int)r;
}

// BT.601 (Kr = 0.299, Kb = 0.114), limited range: Y 16..235, U and V 16..240.
static void reference(int y, int u, int v, int rgb[3]) {
	const double kr = 0.299, kb = 0.114, kg = 1.0 - kr - kb;
	double l = (y - 16) * 255.0 / 219.0;
	double cb = (u - 128) * 255.0 / 224.0;
	double cr = (v - 128) * 255.0 / 224.0;
	rgb[0] = ref_channel(l + 2.0 * (1.0 - kr) * cr);
	rgb[1] = ref_channel(l - 2.0 * kb * (1.0 - kb) / kg * cb -
		2.0 * kr * (1.0 - kr) / kg * cr);
	rgb[2] = ref_channel(l + 2.0 * (1.0 - kb) * cb);
}

static uint8_t *y_at(struct frame *f, int col, int row) {
	return &f->y[(size_t)row * f->y_stride + col];
}

static uint8_t *uv_at(struct frame *f, int col, int row) {
	return &f->uv[(size_t)(row / 2) * f->uv_stride + (size_t)(col / 2) * 2];
}

// Separate Y and UV allocations, unless uv_offset is non-zero: then UV sits
// uv_offset bytes into the Y allocation, as in the decoder's frames.
static void frame_init(struct frame *f, int width, int height,
		size_t y_stride, size_t uv_stride, size_t dst_stride, size_t uv_offset) {
	int uv_rows = (height + 1) / 2;
	*f = (struct frame){
		.width = width,
		.height = height,
		.y_stride = y_stride,
		.uv_stride = uv_stride,
		.dst_stride = dst_stride,
	};
	if (uv_offset != 0) {
		f->y = malloc(uv_offset + uv_stride * uv_rows);
		f->uv = f->y + uv_offset;
	} else {
		f->y = malloc(y_stride * height);
		f->uv = malloc(uv_stride * uv_rows);
	}
	f->dst_len = 2 * GUARD_WORDS + dst_stride / 4 * height;
	f->dst_words = malloc(f->dst_len * sizeof(uint32_t));
	f->ref_words = malloc(f->dst_len * sizeof(uint32_t));
	if (f->y == NULL || f->uv == NULL || f->dst_words == NULL ||
			f->ref_words == NULL) {
		fprintf(stderr, "out of memory\n");
		exit(2);
	}
	f->dst = f->dst_words + GUARD_WORDS;

	// Padding bytes hold noise, so a converter that reads them shows it.
	for (size_t i = 0; i < y_stride * height; i++) {
		f->y[i] = rng();
	}
	for (size_t i = 0; i < uv_stride * uv_rows; i++) {
		f->uv[i] = rng();
	}
}

static void frame_finish(struct frame *f, size_t uv_offset) {
	if (uv_offset == 0) {
		free(f->uv);
	}
	free(f->y);
	free(f->dst_words);
	free(f->ref_words);
}

// Converts the frame and checks every destination word, and that it matches
// pixman_nv12_to_xrgb8888_c() byte for byte.
static void frame_check(struct frame *f, convert_fn convert, bool grey,
		struct stats *st) {
	for (size_t i = 0; i < f->dst_len; i++) {
		f->dst_words[i] = GUARD;
		f->ref_words[i] = GUARD;
	}
	pixman_nv12_to_xrgb8888_c(f->y, f->y_stride, f->uv, f->uv_stride,
		f->ref_words + GUARD_WORDS, f->dst_stride, f->width, f->height);

	if (!convert(f->y, f->y_stride, f->uv, f->uv_stride, f->dst, f->dst_stride,
			f->width, f->height)) {
		fprintf(stderr, "%dx%d: conversion failed\n", f->width, f->height);
		st->failures++;
		return;
	}

	size_t row_words = f->dst_stride / 4;
	for (size_t i = 0; i < f->dst_len; i++) {
		long w = (long)i - GUARD_WORDS;
		long row = w >= 0 ? w / (long)row_words : -1;
		long col = w >= 0 ? w % (long)row_words : -1;
		bool inside = w >= 0 && row < f->height && col < f->width;
		uint32_t px = f->dst_words[i];
		if (!inside) {
			if (px != GUARD) {
				if (st->failures++ < 10) {
					fprintf(stderr, "%dx%d: word %ld outside the rectangle changed to 0x%08x\n",
						f->width, f->height, w, px);
				}
			}
			continue;
		}

		int y = *y_at(f, col, row);
		const uint8_t *uv = uv_at(f, col, row);
		int want[3];
		reference(y, uv[0], uv[1], want);
		int got[3] = { (px >> 16) & 0xff, (px >> 8) & 0xff, px & 0xff };
		bool bad = (px >> 24) != 0xff;
		for (int c = 0; c < 3; c++) {
			int err = abs(got[c] - want[c]);
			if (err > st->max_err[c]) {
				st->max_err[c] = err;
			}
			bad = bad || err > 1;
		}
		bad = bad || (grey && (got[0] != got[1] || got[1] != got[2]));
		if (bad && st->failures++ < 10) {
			fprintf(stderr, "%dx%d (%ld,%ld): Y %d U %d V %d -> 0x%08x, want RGB %d %d %d\n",
				f->width, f->height, col, row, y, uv[0], uv[1], px,
				want[0], want[1], want[2]);
		}
		st->pixels++;
	}

	long differing = 0;
	for (size_t i = 0; i < f->dst_len; i++) {
		differing += f->dst_words[i] != f->ref_words[i];
	}
	if (differing != 0 && st->failures++ < 10) {
		fprintf(stderr, "%dx%d: %ld words differ from pixman_nv12_to_xrgb8888_c\n",
			f->width, f->height, differing);
	}
	st->differing += differing;
}

// Every Y from 0 to 255 with U = V = 128, starting at Y = start.
static void fill_grey(struct frame *f, int start) {
	for (int row = 0; row < f->height; row++) {
		for (int col = 0; col < f->width; col++) {
			*y_at(f, col, row) = (start + row * f->width + col) & 0xff;
			uint8_t *uv = uv_at(f, col, row);
			uv[0] = uv[1] = 128;
		}
	}
}

// One grid point per 2x2 block, all four Y equal: point = (block + start) %
// 768 picks Y from {16, 128, 235} and U, V from 16 steps over 0..255.
static void fill_grid(struct frame *f, int start) {
	static const int grid_y[] = { 16, 128, 235 };
	int blocks_per_row = (f->width + 1) / 2;
	for (int row = 0; row < f->height; row++) {
		for (int col = 0; col < f->width; col++) {
			int block = (row / 2) * blocks_per_row + col / 2;
			int point = (block + start) % 768;
			*y_at(f, col, row) = grid_y[point / 256];
			uint8_t *uv = uv_at(f, col, row);
			uv[0] = (point % 256) / 16 * 17;
			uv[1] = point % 16 * 17;
		}
	}
}

static void fill_random(struct frame *f) {
	for (int row = 0; row < f->height; row++) {
		for (int col = 0; col < f->width; col++) {
			*y_at(f, col, row) = rng();
			uint8_t *uv = uv_at(f, col, row);
			uv[0] = rng();
			uv[1] = rng();
		}
	}
}

#define NOISE_FRAMES 4
#define N_CONVERTERS (sizeof(converters) / sizeof(converters[0]))

static void print_stats(const char *name, const char *converter,
		const struct stats *st) {
	printf("%-50s %-6s %9ld pixels, max error R %d G %d B %d, "
		"%ld words differ from c, %ld failures\n",
		name, converter, st->pixels, st->max_err[0], st->max_err[1],
		st->max_err[2], st->differing, st->failures);
}

static bool run_case(const char *name, int width, int height, size_t y_stride,
		size_t uv_stride, size_t dst_stride, size_t uv_offset) {
	struct frame f;
	frame_init(&f, width, height, y_stride, uv_stride, dst_stride, uv_offset);
	int pixels = width * height;
	int blocks = (width + 1) / 2 * ((height + 1) / 2);
	bool ok = true;

	char label[64];
	snprintf(label, sizeof(label), "%s (Y %zu UV %zu dst %zu)", name,
		y_stride, uv_stride, dst_stride);
	for (size_t c = 0; c < N_CONVERTERS; c++) {
		convert_fn convert = converters[c].convert;
		struct stats st = {0};
		for (int start = 0; start < 256; start += pixels) {
			fill_grey(&f, start);
			frame_check(&f, convert, true, &st);
		}
		for (int start = 0; start < 768; start += blocks) {
			fill_grid(&f, start);
			frame_check(&f, convert, false, &st);
		}
		for (int i = 0; i < NOISE_FRAMES; i++) {
			fill_random(&f);
			frame_check(&f, convert, false, &st);
		}
		print_stats(label, converters[c].name, &st);
		ok = ok && st.failures == 0;
	}

	frame_finish(&f, uv_offset);
	return ok;
}

// Noise frames at every width from 1 to 40 and height from 1 to 4, which
// covers the tails of a vector kernel.
static bool noise_sweep(void) {
	bool ok = true;
	for (size_t c = 0; c < N_CONVERTERS; c++) {
		struct stats st = {0};
		for (int width = 1; width <= 40; width++) {
			for (int height = 1; height <= 4; height++) {
				size_t uv_row = ((size_t)width + 1) / 2 * 2;
				struct frame f;
				frame_init(&f, width, height, width + 3, uv_row + 5,
					((size_t)width + 2) * 4, 0);
				for (int i = 0; i < NOISE_FRAMES; i++) {
					fill_random(&f);
					frame_check(&f, converters[c].convert, false, &st);
				}
				frame_finish(&f, 0);
			}
		}
		print_stats("noise, widths 1-40, heights 1-4", converters[c].name, &st);
		ok = ok && st.failures == 0;
	}
	return ok;
}

int main(void) {
#if defined(__aarch64__) && defined(__ARM_NEON) && !defined(__AARCH64EB__)
	printf("kernel: pixman_nv12_to_xrgb8888 with NEON\n");
#else
	printf("kernel: pixman_nv12_to_xrgb8888 without a vector path\n");
#endif
	bool ok = true;
	ok &= run_case("2x2", 2, 2, 5, 6, 16, 0);
	ok &= run_case("18x6", 18, 6, 21, 23, 80, 0);
	ok &= run_case("odd 7x5", 7, 5, 9, 11, 36, 0);
	ok &= run_case("1280x720", 1280, 720, 1344, 1312, 5248, 0);
	// The decoder's layout: stride 1280, UV 942080 bytes into the buffer.
	ok &= run_case("1280x720 decoder layout", 1280, 720, 1280, 1280, 5120, 942080);
	ok &= noise_sweep();
	printf("%s\n", ok ? "PASS" : "FAIL");
	return ok ? 0 : 1;
}
