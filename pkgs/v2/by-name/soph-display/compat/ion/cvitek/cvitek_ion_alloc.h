/* cvitek_ion_alloc.h -- allocator half of the ION shim. See ../ion.h. */
#ifndef _SOPH_COMPAT_CVITEK_ION_ALLOC_H
#define _SOPH_COMPAT_CVITEK_ION_ALLOC_H

#include "../ion.h"

struct ion_buffer *cvi_ion_alloc_nofd(enum ion_heap_type type, size_t len,
				      bool cached);
int cvi_ion_free_nofd(struct ion_buffer *buf);

/* fd-returning variants: the MPI ioctl path hands a dma-buf fd to userspace. */
int cvi_ion_alloc(enum ion_heap_type type, size_t len, bool cached);
int cvi_ion_free(pid_t pid, int fd);

int cvi_ion_get_memory_state(u64 *total, u64 *free, u64 *max_avail);

#endif

