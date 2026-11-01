// btnwait: block until one USER-button press completes, then print how long
// it was held: "short" or "long". Exit 0 on a press, 2 on setup failure.
//
// Uses the GPIO v2 uAPI directly rather than libgpiod, for the same reason
// nix-badge does: the line is found by the device tree's gpio-line-names, so
// nothing depends on chip numbering (which is not stable across boots), and
// there is no libgpiod major-version CLI churn to track.
//
// The badge's USER button (PWR_GPIO1) is a momentary, active-low line: it idles
// reading 1 and reads 0 while held.
//
//      $CC -O2 -Wall -Wextra btnwait.c -o btnwait
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/ioctl.h>
#include <linux/gpio.h>

static long now_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

/* Find a named line across /dev/gpiochip0..15. Returns the chip fd, or -1. */
static int find_line(const char *name, unsigned int *offset)
{
	for (int c = 0; c < 16; c++) {
		char path[64];
		struct gpiochip_info ci;
		int fd;

		snprintf(path, sizeof path, "/dev/gpiochip%d", c);
		fd = open(path, O_RDWR);
		if (fd < 0)
			continue;

		memset(&ci, 0, sizeof ci);
		if (ioctl(fd, GPIO_GET_CHIPINFO_IOCTL, &ci) == 0) {
			for (unsigned int l = 0; l < ci.lines; l++) {
				struct gpio_v2_line_info li;

				memset(&li, 0, sizeof li);
				li.offset = l;
				if (ioctl(fd, GPIO_V2_GET_LINEINFO_IOCTL, &li) == 0 &&
				    strcmp(li.name, name) == 0) {
					*offset = l;
					return fd;
				}
			}
		}
		close(fd);
	}
	return -1;
}

int main(int argc, char **argv)
{
	const char *name = argc > 1 ? argv[1] : "user-btn";
	long long_ms = argc > 2 ? atol(argv[2]) : 600;
	struct gpio_v2_line_request req;
	unsigned int offset = 0;
	int chip, prev = 1;
	long pressed_at = 0;

	chip = find_line(name, &offset);
	if (chip < 0) {
		fprintf(stderr, "btnwait: no gpio line named '%s'\n", name);
		return 2;
	}

	memset(&req, 0, sizeof req);
	req.offsets[0] = offset;
	req.num_lines = 1;
	snprintf(req.consumer, sizeof req.consumer, "nix-badge-video");
	req.config.flags = GPIO_V2_LINE_FLAG_INPUT;
	if (ioctl(chip, GPIO_V2_GET_LINE_IOCTL, &req) < 0) {
		perror("btnwait: GPIO_V2_GET_LINE");
		return 2;
	}

	for (;;) {
		struct gpio_v2_line_values v;
		int cur;

		memset(&v, 0, sizeof v);
		v.mask = 1;
		if (ioctl(req.fd, GPIO_V2_LINE_GET_VALUES_IOCTL, &v) < 0) {
			perror("btnwait: GET_VALUES");
			return 2;
		}
		cur = (v.bits & 1) ? 1 : 0;

		if (prev == 1 && cur == 0) {
			pressed_at = now_ms();
		} else if (prev == 0 && cur == 1 && pressed_at) {
			long held = now_ms() - pressed_at;

			/* Contact bounce: anything this brief is not a press. */
			if (held >= 30) {
				puts(held >= long_ms ? "long" : "short");
				fflush(stdout);
				return 0;
			}
			pressed_at = 0;
		}
		prev = cur;
		usleep(10000);
	}
}
