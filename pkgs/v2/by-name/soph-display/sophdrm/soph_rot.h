/* SPDX-License-Identifier: GPL-2.0 */
#ifndef SOPH_ROT_H
#define SOPH_ROT_H
#include <linux/types.h>
#include <linux/err.h>
struct platform_device;
struct drm_plane_state;
struct sclr_mem;
struct soph_rot;
struct soph_rot *soph_rot_create(struct platform_device *pdev, unsigned int w,
				 unsigned int h, unsigned int angle);
int soph_rot_check(struct soph_rot *rot, struct drm_plane_state *state);
int soph_rot_run(struct soph_rot *rot, struct drm_plane_state *state);
bool soph_rot_mem(struct soph_rot *rot, struct sclr_mem *mem);
void soph_rot_stage(struct soph_rot *rot);
void soph_rot_latched(struct soph_rot *rot);
void soph_rot_retain(struct soph_rot *rot);
#endif
