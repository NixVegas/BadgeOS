/* pinctrl-cv181x.h -- stand-in for the vendor kernel's own pinctrl header.
 *
 * WHAT CHANGED UPSTREAM: nothing in the pinctrl *API*. The real header is not
 * part of osdrv at all -- it lives in the vendor kernel tree at
 * drivers/pinctrl/cvitek/pinctrl-cv181x.h, which vo/Makefile and cif/Makefile
 * reach with `-I$(srctree)/drivers/pinctrl/cvitek/`. Mainline has no such
 * directory, so both vo.c and cif.c lose PINMUX_CONFIG(), PINMUX_BASE and
 * mmio_clrsetbits_32() at once.
 *
 * Two of those three we provide for real; one we deliberately do not.
 *
 * 1. PINMUX_BASE / mmio_clrsetbits_32(): provided, matching the vendor
 *    definitions (base 0x03001000, read-modify-write one 32-bit pinmux
 *    register). cif.c's cif_config_pinmux() calls them directly with values
 *    out of its vi_pin[][] table, so a stub would silently turn the DVP
 *    (parallel-camera) pin setup into a no-op. That path is only reached from
 *    CVI_MIPI_SET_DEV_ATTR with a TTL/DVP sensor -- never at probe -- so
 *    making it genuinely work costs nothing and breaks nothing here.
 *
 * 2. PINMUX_CONFIG(pad, func): still a deliberate no-op, and it must stay one.
 *    vo.c's _disp_sel_remux() is a switch of PINMUX_CONFIG() calls; on this
 *    badge the vendor grabbing those pads is exactly what re-muxes the IIC2
 *    pads away from I2C and stops the LT8912B ACKing. We mux from DT instead.
 *    Note the macro ignores both parameters, so it never expands them -- which
 *    is why the per-pad *function value* constants (PIN_NAME__FUNC_NAME, from
 *    the vendor's cv181x_pinlist_swconfig.h) are not needed and not imported.
 *    Only the register addr/offset/mask triples are, via the fmux header.
 */
#ifndef _SOPH_COMPAT_PINCTRL_CV181X_H
#define _SOPH_COMPAT_PINCTRL_CV181X_H

#include <linux/io.h>
#include <linux/printk.h>
#include <linux/types.h>

/* Verbatim vendor register map; supplies FMUX_GPIO_FUNCSEL_<PAD>{,_OFFSET,_MASK}. */
#include "cv181x_reg_fmux_gpio.h"

#define PINMUX_BASE 0x03001000

#define PINMUX_CONFIG(pad, func)	do { } while (0)

/* Same read-modify-write the vendor header does, with one correction: ioremap()
 * reports failure by returning NULL, not an ERR_PTR, so IS_ERR() (what the
 * vendor wrote) would happily dereference NULL. */
static inline void mmio_clrsetbits_32(uintptr_t addr, uint32_t clear, uint32_t set)
{
	void __iomem *tpreg;

	tpreg = ioremap(addr, 0x4);
	if (!tpreg) {
		pr_err("soph: ioremap %p failed\n", (void *)addr);
		return;
	}

	iowrite32((ioread32(tpreg) & ~clear) | set, tpreg);

	iounmap(tpreg);
}

#endif
