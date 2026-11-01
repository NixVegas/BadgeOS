/* cv180x_efuse.h -- stub for the vendor eFuse API.
 *
 * base.c exports a few sysfs attributes that read and write the SoC eFuse
 * shadow. That lives in the vendor's patched kernel, not in osdrv, and the
 * display pipeline never touches it -- so the attributes stay present (removing
 * them would mean editing base.c) but report "not supported" rather than
 * silently returning junk that looks like real fuse contents.
 *
 * If eFuse access is ever wanted on this kernel, drive it through the upstream
 * sophgo_efuse nvmem provider instead of reviving this.
 */
#ifndef _SOPH_COMPAT_CV180X_EFUSE_H
#define _SOPH_COMPAT_CV180X_EFUSE_H

#include <linux/types.h>
#include <linux/errno.h>

static inline int cvi_efuse_read_buf(u32 addr, void *buf, size_t size)
{
	return -EOPNOTSUPP;
}

static inline int cvi_efuse_write(u32 addr, u32 value)
{
	return -EOPNOTSUPP;
}

static inline u32 cvi_efuse_read_from_shadow(u32 addr)
{
	return 0;
}

#endif
