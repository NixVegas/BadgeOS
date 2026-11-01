/*
 * kernel 7.2 dropped strncpy, which the vendor driver still calls and relies on
 * (copy up to n, then NUL-pad; strscpy does not pad). A local strncpy with the
 * real semantics, force-included into every driver TU.
 */
#ifndef _AIC8800_STRNCPY_COMPAT_H
#define _AIC8800_STRNCPY_COMPAT_H

#include <linux/string.h>
#include <linux/types.h>

#ifdef strncpy
#undef strncpy
#endif

static inline char *strncpy(char *dest, const char *src, size_t n)
{
	size_t i;

	for (i = 0; i < n && src[i] != '\0'; i++)
		dest[i] = src[i];
	for (; i < n; i++)
		dest[i] = '\0';

	return dest;
}

#endif /* _AIC8800_STRNCPY_COMPAT_H */
