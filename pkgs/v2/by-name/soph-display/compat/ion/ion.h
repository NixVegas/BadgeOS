/* ion.h -- compatibility shim for the Sophgo/Cvitek 5.10 display stack.
 *
 * Android ION was removed from mainline in 5.11 (superseded by DMA-BUF heaps),
 * but the vendor drivers are built on it. Fortunately the surface they actually
 * touch is tiny -- a three-field buffer descriptor and a pair of cache-
 * maintenance calls -- so rather than forward-port ION itself we re-implement
 * that surface on top of the DMA API.
 *
 * Allocations come from dma_alloc_coherent, i.e. CMA on this platform, which is
 * what the ION carveout heap was doing underneath anyway.
 */
#ifndef _SOPH_COMPAT_ION_H
#define _SOPH_COMPAT_ION_H

#include <linux/types.h>
#include <linux/dma-mapping.h>
#include <linux/atomic.h>
#include <linux/kref.h>

/* The vendor only ever asks for the carveout heap. */
enum ion_heap_type {
	ION_HEAP_TYPE_SYSTEM = 0,
	ION_HEAP_TYPE_DMA,
	ION_HEAP_TYPE_CARVEOUT,
	ION_HEAP_TYPE_CUSTOM,
};

struct ion_buffer {
	const char	*name;		/* owner tag, for the proc dump   */
	phys_addr_t	paddr;		/* what the VIP DMA engines want  */
	void		*vaddr;		/* kernel mapping                 */
	size_t		size;
	dma_addr_t	dma;		/* handle for dma_free_coherent   */
	struct list_head node;		/* on the live list until freed   */
	/* One reference for the allocation, one per dma-buf of it: the
	 * memory goes back at the last put, not at cvi_ion_free_nofd(). */
	struct kref	ref;
	atomic_t	cached_maps;	/* cached user mappings of it now */
};

/* Coherent memory needs no explicit maintenance; keep the call sites honest
 * by still validating the buffer so a NULL slips up loudly rather than
 * silently. */
static inline int ion_buf_begin_cpu_access(struct ion_buffer *b)
{
	return b ? 0 : -EINVAL;
}

static inline int ion_buf_end_cpu_access(struct ion_buffer *b)
{
	return b ? 0 : -EINVAL;
}

/* Cache maintenance by physical address.
 *
 * The vendor calls arch_sync_dma_for_device() (riscv) or __dma_map_area()
 * (arm64) directly; mainline exports neither to modules. These wrap the
 * module-visible DMA sync API instead. Declared here rather than in
 * cvitek_ion_alloc.h because tpu includes only <ion.h>.
 *
 * Buffers from this shim are dma_alloc_coherent: uncached on a non-coherent
 * device (arm64), where these maintain the cacheable linear alias. On riscv
 * the shim's device reads DMA-coherent and these do nothing, a known gap.
 */
void soph_cache_flush_phys(phys_addr_t pa, size_t len);       /* CPU -> device */
void soph_cache_invalidate_phys(phys_addr_t pa, size_t len);  /* device -> CPU */

#endif
