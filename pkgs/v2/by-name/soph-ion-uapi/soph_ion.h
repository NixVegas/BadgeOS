/* SPDX-License-Identifier: GPL-2.0 WITH Linux-syscall-note */
/*
 * soph_ion.h -- /dev/soph-ion, the ION compat shim's dma-buf exporter.
 *
 * SOPH_ION_IOC_EXPORT wraps the live ION allocation that contains phys in a
 * new dma-buf, so a buffer the vendor drivers allocated (a decoder frame,
 * say) can be handed to another device, or a compositor, by fd. Only memory
 * the shim allocated can be exported: any other address fails with EINVAL.
 * The dma-buf keeps the allocation alive after its owner frees it.
 *
 * Opening the device takes what opening /dev/mem takes: CAP_SYS_RAWIO, and
 * a kernel that is not locked down.
 *
 * mmap of the dma-buf, on a non-coherent device configuration (arm64): a
 * writable map is write-combined; a read-only one is cacheable while the
 * shim's cached_mmap parameter is on (the default on arm64), and the reader
 * must bracket each access with DMA_BUF_IOCTL_SYNC START and END. On riscv
 * the shim's device reads DMA-coherent, every map is cacheable and nothing
 * is maintained: a known gap.
 */
#ifndef _UAPI_SOPH_ION_H
#define _UAPI_SOPH_ION_H

#include <linux/ioctl.h>
#include <linux/types.h>

struct soph_ion_export {
	__u64 phys;	/* in: an address inside a live ION allocation */
	__u32 flags;	/* in: any of O_CLOEXEC (for the fd), SOPH_ION_EXPORT_RDONLY */
	__s32 fd;	/* out: a dma-buf of the whole allocation, O_RDWR or O_RDONLY */
	__u64 offset;	/* out: phys minus the allocation's start */
	__u64 size;	/* out: the allocation's size */
};

/*
 * Export read-only: the dma-buf's file is O_RDONLY, so it maps PROT_READ only.
 * Without it the dma-buf is O_RDWR. The bit is outside every O_* flag.
 */
#define SOPH_ION_EXPORT_RDONLY	(1u << 31)

/* 0xB9 is unassigned in Documentation/userspace-api/ioctl/ioctl-number.rst. */
#define SOPH_ION_IOC_MAGIC	0xB9

#define SOPH_ION_IOC_EXPORT	_IOWR(SOPH_ION_IOC_MAGIC, 0x01, struct soph_ion_export)

#endif
