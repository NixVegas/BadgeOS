/* NV21 camera frames to the window's XRGB8888, scaled to cover it. */
#ifndef BADGE_CAMERA_CONVERT_H
#define BADGE_CAMERA_CONVERT_H

#include <stdint.h>

/* Scales the source (sw x sh, BT.601 limited range) to cover dw x dh, cropping the
 * longer axis evenly, with nearest sampling. dst_pitch is in pixels. */
void nv21_cover_xrgb(const uint8_t *y, const uint8_t *vu, unsigned stride, unsigned sw, unsigned sh,
		     uint32_t *dst, unsigned dst_pitch, unsigned dw, unsigned dh);

/* As above, but averaging every source pixel that falls inside an output one. It reads
 * the whole source, so run it on a copy in ordinary memory, not on the frame as mapped.
 * yscale says how many original rows each source row stands for, for a source whose rows
 * were thinned on the way in; 1 for an untouched frame. */
void nv21_cover_box(const uint8_t *y, const uint8_t *vu, unsigned stride, unsigned sw, unsigned sh,
		    unsigned yscale, uint32_t *dst, unsigned dst_pitch, unsigned dw, unsigned dh);

/* The whole source averaged down into a qw x qh gray image, with no crop. */
void nv21_luma_box(const uint8_t *y, unsigned stride, unsigned sw, unsigned sh, uint8_t *dst,
		   unsigned qw, unsigned qh);

#endif
