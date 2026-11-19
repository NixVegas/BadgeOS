/* The GC4653 capture pipeline: sensor -> MIPI CSI -> VI/ISP -> NV21 frames in memory. */
#ifndef BADGE_CAMERA_PIPELINE_H
#define BADGE_CAMERA_PIPELINE_H

#include <stdbool.h>
#include <stdint.h>

#define CAM_WIDTH 2560
#define CAM_HEIGHT 1440

struct cam_frame {
	const uint8_t *y;   /* luma, stride bytes per row */
	const uint8_t *vu;  /* interleaved V/U at half resolution, same stride */
	unsigned stride;
	unsigned width, height;
	void *handle;       /* for cam_release */
};

struct cam_options {
	int i2c_bus;        /* /dev/i2c-N of the sensor; -1 finds the controller below */
	const char *i2c_controller; /* sysfs device name of the sensor's I2C controller */
	bool mirror, flip;
	bool tnr;           /* temporal noise reduction: a reference frame, 5.5 MB more */
};

/* Brings the pipeline up. Needs root for the vendor devices; afterwards everything
 * runs on the descriptors it opened. Returns 0 or -1 with a message on stderr. */
int cam_open(const struct cam_options *opt);
/* Waits up to timeout_ms for the next frame. 0 on success. */
int cam_get(struct cam_frame *f, int timeout_ms);
void cam_release(struct cam_frame *f);
/* Tears the pipeline down in reverse; safe after a partial cam_open. */
void cam_close(void);
/* Frees a buffer pool a killed instance left behind (run as root, camera idle). */
int cam_cleanup(void);

#endif
