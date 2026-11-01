/* gpio-compat.h -- neutralise the vendor's panel GPIO poking.
 *
 * vo.c drives panel reset/power/backlight pins through the legacy integer GPIO
 * API (of_gpio_flags, GPIOF_*, devm_gpio_request_one), most of which mainline
 * has retired. On this badge we do not want that code to run at all: those are
 * the PWR_GPIO lines, and the vendor grabbing them is exactly what re-muxes the
 * IIC2 pads away from I2C -- the wall that made the LT8912B stop ACKing under
 * the vendor stack on Debian. Panel/bridge control here is ours (DT + the
 * lt8912b driver), so every pin is reported invalid and nothing is claimed.
 */
#ifndef _SOPH_COMPAT_GPIO_H
#define _SOPH_COMPAT_GPIO_H

#include <linux/device.h>
#include <linux/types.h>

enum of_gpio_flags {
	OF_GPIO_ACTIVE_LOW = 0x1,
};

#define GPIOF_DIR_OUT		0
#define GPIOF_DIR_IN		1
#define GPIOF_INIT_LOW		0
#define GPIOF_INIT_HIGH		2

/* Always invalid: the request/set helpers below are then never reached. */
static inline bool soph_gpio_is_valid(int gpio) { return false; }
#define gpio_is_valid(g)	soph_gpio_is_valid(g)

static inline int devm_gpio_request_one(struct device *dev, unsigned int gpio,
					unsigned long flags, const char *label)
{
	return -ENODEV;
}

static inline void gpio_set_value(unsigned int gpio, int value) { }
static inline int  gpio_get_value(unsigned int gpio) { return 0; }
static inline int  gpio_direction_output(unsigned int gpio, int v) { return -ENODEV; }
static inline int  gpio_request(unsigned int gpio, const char *label) { return -ENODEV; }
static inline void gpio_free(unsigned int gpio) { }

/* of_get_named_gpio_flags() is gone; report "no such gpio" so the vendor
 * probe paths skip their panel pin handling entirely. */
struct device_node;
static inline int of_get_named_gpio_flags(struct device_node *np, const char *name,
					  int index, enum of_gpio_flags *flags)
{
	if (flags)
		*flags = 0;
	return -ENODEV;
}

#endif
