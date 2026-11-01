/* streamline_annotate.h -- stub for the ARM Streamline profiling annotations.
 *
 * Not a mainline header at all, then or now: it ships with ARM's gator/DS-5
 * Streamline agent, which the vendor dropped into their kernel tree. vo.h and
 * vcodec/cvi_vcodec.c include it. We are not profiling, so every annotation
 * compiles away.
 *
 * The macros are variadic and drop their arguments, so the *colour* tokens
 * (ANNOTATE_GREEN and friends) are never expanded and deliberately have no
 * definition here -- inventing plausible-looking constants for a feature we do
 * not implement would be worse than leaving them undefined.
 */
#ifndef _SOPH_COMPAT_STREAMLINE_ANNOTATE_H
#define _SOPH_COMPAT_STREAMLINE_ANNOTATE_H
#define ANNOTATE_DEFINE
#define ANNOTATE_SETUP			do { } while (0)
#define ANNOTATE_CHANNEL(...)		do { } while (0)
#define ANNOTATE_CHANNEL_COLOR(...)	do { } while (0)
#define ANNOTATE_CHANNEL_END(...)	do { } while (0)
#define ANNOTATE_NAME_CHANNEL(...)	do { } while (0)
#define ANNOTATE_MARKER(...)		do { } while (0)
#define ANNOTATE(...)			do { } while (0)
#endif
