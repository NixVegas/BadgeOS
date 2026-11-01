// SPDX-License-Identifier: GPL-2.0
/*
 * soph_ion_compat -- the ION allocator the Cvitek 5.10 display stack expects,
 * re-implemented on the modern DMA API.
 *
 * Mainline deleted Android ION in 5.11. The vendor's sys/base/vpss/vo modules
 * only use a seven-call slice of it (alloc/free, with and without a dma-buf fd,
 * a memory-state query, and begin/end CPU access), so this provides exactly
 * that slice backed by dma_alloc_coherent -- CMA here, which is what the ION
 * carveout heap was doing anyway.
 *
 * On top of that, /dev/soph-ion exports a live allocation as a dma-buf (see
 * uapi/soph_ion.h), which is how a decoder frame reaches the display without
 * a copy.
 */
#include <linux/module.h>
#include <linux/capability.h>
#include <linux/slab.h>
#include <linux/list.h>
#include <linux/mutex.h>
#include <linux/dma-mapping.h>
#include <linux/dma-map-ops.h>
#include <linux/dma-buf.h>
#include <linux/file.h>
#include <linux/fs.h>
#include <linux/miscdevice.h>
#include <linux/mm.h>
#include <linux/platform_device.h>
#include <linux/security.h>
#include <linux/uaccess.h>

#include "ion/ion.h"
#include "ion/cvitek/cvitek_ion_alloc.h"
#include "uapi/soph_ion.h"	/* pkgs/by-name/soph-ion-uapi, copied in by package.nix */

static struct platform_device *ion_pdev;
static DEFINE_MUTEX(ion_lock);
static LIST_HEAD(ion_bufs);
static size_t ion_in_use;

/* CMA is a shared resource; cap what this stack can take so a runaway
 * allocation cannot starve the rest of the system. */
#define ION_BUDGET	(96u << 20)

static int used_bytes_get(char *buf, const struct kernel_param *kp)
{
	size_t used;

	mutex_lock(&ion_lock);
	used = ion_in_use;
	mutex_unlock(&ion_lock);
	return sysfs_emit(buf, "%zu\n", used);
}

static int used_bytes_set(const char *val, const struct kernel_param *kp)
{
	return -EPERM;
}

static const struct kernel_param_ops used_bytes_ops = {
	.set = used_bytes_set,
	.get = used_bytes_get,
};

module_param_cb(used_bytes, &used_bytes_ops, NULL, 0444);
MODULE_PARM_DESC(used_bytes,
		 "Bytes of the budget in use, freed allocations a dma-buf still holds included");

/*
 * What a dma-buf mmap is, on a non-coherent device configuration (arm64).
 *
 * A writable mmap is write-combined (Normal non-cacheable on this SoC). It
 * needs no cache maintenance, but every CPU read goes to DRAM; a cached one
 * could land a dirty line on a frame the device has written since.
 *
 * With cached_mmap (the default on arm64), a read-only mmap is cacheable
 * instead, and the reader must bracket each access with DMA_BUF_IOCTL_SYNC
 * (START before, END after), as wlroots does. The mmap and every START drop
 * the buffer's stale lines; a reader that does not bracket sees stale data.
 * Off, every mmap is write-combined. Applies to mmaps made after the change.
 *
 * On riscv the shim's device reads DMA-coherent: it has no DT node, so the
 * SoC's dma-noncoherent bus never configures it. Then every mapping is
 * cacheable and SYNC maintains nothing (inferred from the DMA code, not seen
 * on the C906), a known gap; cached_mmap is refused.
 */
static bool cached_mmap = IS_ENABLED(CONFIG_ARM64);
static bool ion_coherent;	/* the shim's device, as the DMA API sees it */

static void cached_mmap_refuse(void)
{
	pr_warn_once("soph_ion: cached_mmap refused: the device reads DMA-coherent, so SYNC would not maintain a cached map\n");
}

static int cached_mmap_set(const char *val, const struct kernel_param *kp)
{
	bool on;
	int ret = kstrtobool(val ? val : "1", &on);

	if (ret)
		return ret;
	if (on && READ_ONCE(ion_coherent)) {
		cached_mmap_refuse();
		return -EINVAL;
	}
	WRITE_ONCE(cached_mmap, on);
	return 0;
}

static const struct kernel_param_ops cached_mmap_ops = {
	.flags = KERNEL_PARAM_OPS_FL_NOARG,
	.set = cached_mmap_set,
	.get = param_get_bool,
};

module_param_cb(cached_mmap, &cached_mmap_ops, &cached_mmap, 0644);
MODULE_PARM_DESC(cached_mmap,
		 "Map read-only dma-buf mmaps cacheable, for readers that bracket access with DMA_BUF_IOCTL_SYNC (default on arm64; refused on a DMA-coherent device)");

struct ion_buffer *cvi_ion_alloc_nofd(enum ion_heap_type type, size_t len,
				      bool cached)
{
	struct ion_buffer *b;

	if (!ion_pdev || !len)
		return ERR_PTR(-EINVAL);

	b = kzalloc(sizeof(*b), GFP_KERNEL);
	if (!b)
		return ERR_PTR(-ENOMEM);

	len = PAGE_ALIGN(len);

	mutex_lock(&ion_lock);
	if (ion_in_use + len > ION_BUDGET) {
		mutex_unlock(&ion_lock);
		kfree(b);
		pr_err("soph_ion: %zu bytes would exceed the %u byte budget\n",
		       len, ION_BUDGET);
		return ERR_PTR(-ENOMEM);
	}
	mutex_unlock(&ion_lock);

	b->vaddr = dma_alloc_coherent(&ion_pdev->dev, len, &b->dma, GFP_KERNEL);
	if (!b->vaddr) {
		kfree(b);
		pr_err("soph_ion: dma_alloc_coherent(%zu) failed (raise cma=)\n",
		       len);
		return ERR_PTR(-ENOMEM);
	}
	b->paddr = (phys_addr_t)b->dma;
	b->size  = len;
	b->name  = "soph";
	kref_init(&b->ref);

	mutex_lock(&ion_lock);
	list_add(&b->node, &ion_bufs);
	ion_in_use += len;
	mutex_unlock(&ion_lock);

	(void)type; (void)cached;	/* coherent: cached/uncached is moot */
	return b;
}
EXPORT_SYMBOL_GPL(cvi_ion_alloc_nofd);

/* The last reference is gone: the allocation is freed and no dma-buf is open. */
static void ion_buf_release(struct kref *ref)
{
	struct ion_buffer *b = container_of(ref, struct ion_buffer, ref);

	dma_free_coherent(&ion_pdev->dev, b->size, b->vaddr, b->dma);

	mutex_lock(&ion_lock);
	ion_in_use -= b->size;
	mutex_unlock(&ion_lock);

	kfree(b);
}

int cvi_ion_free_nofd(struct ion_buffer *b)
{
	if (IS_ERR_OR_NULL(b))
		return -EINVAL;

	/* Off the list, so it can no longer be exported; an open dma-buf of it
	 * keeps the memory, and the budget it takes, until that is closed. */
	mutex_lock(&ion_lock);
	list_del(&b->node);
	mutex_unlock(&ion_lock);

	kref_put(&b->ref, ion_buf_release);
	return 0;
}
EXPORT_SYMBOL_GPL(cvi_ion_free_nofd);

/*
 * The fd variants exist for the MPI ioctl path, which allocates on behalf of
 * userspace and hands it a dma-buf. The display pipeline we care about never
 * takes that route, so these fail loudly: a clear -ENOSYS beats a buffer
 * whose lifetime nobody owns. Userspace that wants a dma-buf of an existing
 * allocation exports it through /dev/soph-ion below.
 */
int cvi_ion_alloc(enum ion_heap_type type, size_t len, bool cached)
{
	pr_warn_once("soph_ion: fd-based cvi_ion_alloc is not implemented in the compat shim\n");
	return -ENOSYS;
}
EXPORT_SYMBOL_GPL(cvi_ion_alloc);

int cvi_ion_free(pid_t pid, int fd)
{
	pr_warn_once("soph_ion: fd-based cvi_ion_free is not implemented in the compat shim\n");
	return -ENOSYS;
}
EXPORT_SYMBOL_GPL(cvi_ion_free);

int cvi_ion_get_memory_state(u64 *total, u64 *free, u64 *max_avail)
{
	mutex_lock(&ion_lock);
	if (total)	*total	   = ION_BUDGET;
	if (free)	*free	   = ION_BUDGET - ion_in_use;
	if (max_avail)	*max_avail = ION_BUDGET - ion_in_use;
	mutex_unlock(&ion_lock);
	return 0;
}
EXPORT_SYMBOL_GPL(cvi_ion_get_memory_state);

/* dma-buf exporter */

static struct sg_table *soph_ion_map_dma_buf(struct dma_buf_attachment *at,
					     enum dma_data_direction dir)
{
	struct ion_buffer *b = at->dmabuf->priv;
	struct sg_table *sgt;
	int ret;

	sgt = kzalloc(sizeof(*sgt), GFP_KERNEL);
	if (!sgt)
		return ERR_PTR(-ENOMEM);

	/* One entry: the allocation is physically contiguous. */
	ret = dma_get_sgtable(&ion_pdev->dev, sgt, b->vaddr, b->dma, b->size);
	if (ret)
		goto err_free;

	/* Nothing to clean: on a non-coherent device the CPU writes these
	 * buffers only through uncached mappings, and cached maps are
	 * read-only. */
	ret = dma_map_sgtable(at->dev, sgt, dir, DMA_ATTR_SKIP_CPU_SYNC);
	if (ret)
		goto err_table;
	return sgt;

err_table:
	sg_free_table(sgt);
err_free:
	kfree(sgt);
	return ERR_PTR(ret);
}

static void soph_ion_unmap_dma_buf(struct dma_buf_attachment *at,
				   struct sg_table *sgt,
				   enum dma_data_direction dir)
{
	dma_unmap_sgtable(at->dev, sgt, dir, DMA_ATTR_SKIP_CPU_SYNC);
	sg_free_table(sgt);
	kfree(sgt);
}

/* The cached mappings of a buffer, counted so SYNC maintenance stops with the
 * last one. A VMA pins the dma-buf file, and with it the buffer. */
static void soph_ion_vm_open(struct vm_area_struct *vma)
{
	struct ion_buffer *b = vma->vm_private_data;

	atomic_inc(&b->cached_maps);
}

static void soph_ion_vm_close(struct vm_area_struct *vma)
{
	struct ion_buffer *b = vma->vm_private_data;

	atomic_dec(&b->cached_maps);
}

static const struct vm_operations_struct soph_ion_cached_vm_ops = {
	.open = soph_ion_vm_open,
	.close = soph_ion_vm_close,
};

static int soph_ion_mmap(struct dma_buf *db, struct vm_area_struct *vma)
{
	struct ion_buffer *b = db->priv;
	int ret;

	/* The dma-buf core has checked the range against the buffer's size. */
	if (READ_ONCE(cached_mmap) && !(vma->vm_flags & VM_WRITE)) {
		/* and no mprotect() can make it writable later */
		vm_flags_clear(vma, VM_MAYWRITE);
		ret = remap_pfn_range(vma, vma->vm_start,
				      PHYS_PFN(b->paddr) + vma->vm_pgoff,
				      vma->vm_end - vma->vm_start,
				      vma->vm_page_prot);
		if (ret)
			return ret;
		vma->vm_private_data = b;
		vma->vm_ops = &soph_ion_cached_vm_ops;
		atomic_inc(&b->cached_maps);
		/* A SYNC START before this mmap had no cached map to maintain:
		 * drop what an earlier map or the linear alias left behind. */
		dma_sync_single_for_cpu(&ion_pdev->dev, b->dma, b->size,
					DMA_FROM_DEVICE);
		return 0;
	}

	/* On a non-coherent device, Normal non-cacheable (pgprot_dmacoherent),
	 * never Device memory, so unaligned and wide loads are fine. */
	return dma_mmap_coherent(&ion_pdev->dev, vma, b->vaddr, b->dma, b->size);
}

/* soph_drm's PRIME import (the DMA GEM helpers' _VMAP variant) needs this. */
static int soph_ion_vmap(struct dma_buf *db, struct iosys_map *map)
{
	struct ion_buffer *b = db->priv;

	iosys_map_set_vaddr(map, b->vaddr);
	return 0;
}

/*
 * Write-combined mappings need nothing. While a cached mapping of the buffer
 * exists, drop its stale lines before any CPU access, whatever the
 * direction: the device writes these buffers. Cached mappings are read-only,
 * so no dirty line needs cleaning at the end, and end_cpu_access is not
 * needed.
 *
 * The DMA API means dma_sync_single_*() for streaming mappings, not for a
 * dma_alloc_coherent() handle. On dma-direct, which this device uses (no
 * IOMMU), it is plain maintenance of the linear alias by physical address,
 * which is what a cached alias of the buffer needs, and nothing at all on a
 * DMA-coherent device. soph_cache_*_phys() below use it the same way.
 */
static int soph_ion_begin_cpu_access(struct dma_buf *db,
				     enum dma_data_direction dir)
{
	struct ion_buffer *b = db->priv;

	if (atomic_read(&b->cached_maps))
		dma_sync_single_for_cpu(&ion_pdev->dev, b->dma, b->size,
					DMA_FROM_DEVICE);
	return 0;
}

static void soph_ion_dmabuf_release(struct dma_buf *db)
{
	struct ion_buffer *b = db->priv;

	kref_put(&b->ref, ion_buf_release);
}

static const struct dma_buf_ops soph_ion_dmabuf_ops = {
	.map_dma_buf = soph_ion_map_dma_buf,
	.unmap_dma_buf = soph_ion_unmap_dma_buf,
	.release = soph_ion_dmabuf_release,
	.begin_cpu_access = soph_ion_begin_cpu_access,
	.mmap = soph_ion_mmap,
	.vmap = soph_ion_vmap,
};

/* The live allocation that contains pa, with a reference taken, or NULL. */
static struct ion_buffer *ion_buf_get(u64 pa)
{
	struct ion_buffer *b;

	mutex_lock(&ion_lock);
	list_for_each_entry(b, &ion_bufs, node) {
		if (pa >= b->paddr && pa - b->paddr < b->size) {
			kref_get(&b->ref);
			mutex_unlock(&ion_lock);
			return b;
		}
	}
	mutex_unlock(&ion_lock);
	return NULL;
}

static long soph_ion_export(struct soph_ion_export __user *uarg)
{
	DEFINE_DMA_BUF_EXPORT_INFO(exp);
	struct soph_ion_export arg;
	struct ion_buffer *b;
	struct dma_buf *db;
	int fd;

	if (copy_from_user(&arg, uarg, sizeof(arg)))
		return -EFAULT;
	if (arg.flags & ~(O_CLOEXEC | SOPH_ION_EXPORT_RDONLY))
		return -EINVAL;

	/* Only ION memory, never an arbitrary physical address. */
	b = ion_buf_get(arg.phys);
	if (!b)
		return -EINVAL;

	exp.ops = &soph_ion_dmabuf_ops;
	exp.size = b->size;
	exp.flags = (arg.flags & SOPH_ION_EXPORT_RDONLY) ? O_RDONLY : O_RDWR;
	exp.priv = b;
	db = dma_buf_export(&exp);
	if (IS_ERR(db)) {
		kref_put(&b->ref, ion_buf_release);
		return PTR_ERR(db);
	}

	/* From here, the dma-buf owns the reference: dma_buf_put() drops it. */
	fd = get_unused_fd_flags(arg.flags & O_CLOEXEC);
	if (fd < 0) {
		dma_buf_put(db);
		return fd;
	}

	arg.fd = fd;
	arg.offset = arg.phys - b->paddr;
	arg.size = b->size;
	if (copy_to_user(uarg, &arg, sizeof(arg))) {
		put_unused_fd(fd);
		dma_buf_put(db);
		return -EFAULT;
	}

	dma_buf_fd_install(db, fd);
	return 0;
}

/* What opening /dev/mem takes: CAP_SYS_RAWIO, and a kernel not locked down. */
static int soph_ion_open(struct inode *inode, struct file *file)
{
	if (!capable(CAP_SYS_RAWIO))
		return -EPERM;
	return security_locked_down(LOCKDOWN_DEV_MEM);
}

static long soph_ion_ioctl(struct file *file, unsigned int cmd,
			   unsigned long arg)
{
	switch (cmd) {
	case SOPH_ION_IOC_EXPORT:
		return soph_ion_export((struct soph_ion_export __user *)arg);
	default:
		return -ENOTTY;
	}
}

static const struct file_operations soph_ion_fops = {
	.owner = THIS_MODULE,
	.open = soph_ion_open,
	.unlocked_ioctl = soph_ion_ioctl,
	.compat_ioctl = compat_ptr_ioctl,
};

/* Root only, like /dev/cvi-base; with the open gate, narrower than /dev/mem in
 * every way: the same callers, and only ION memory. */
static struct miscdevice soph_ion_misc = {
	.minor = MISC_DYNAMIC_MINOR,
	.name = "soph-ion",
	.fops = &soph_ion_fops,
	.mode = 0600,
};

static int __init soph_ion_init(void)
{
	int ret;

	ion_pdev = platform_device_register_simple("soph_ion", -1, NULL, 0);
	if (IS_ERR(ion_pdev))
		return PTR_ERR(ion_pdev);

	ret = dma_coerce_mask_and_coherent(&ion_pdev->dev, DMA_BIT_MASK(32));
	if (ret)
		goto err_pdev;

	WRITE_ONCE(ion_coherent, dev_is_dma_coherent(&ion_pdev->dev));
	if (ion_coherent && cached_mmap) {
		cached_mmap_refuse();
		WRITE_ONCE(cached_mmap, false);
	}

	ret = misc_register(&soph_ion_misc);
	if (ret)
		goto err_pdev;

	pr_info("soph_ion: ION compat shim up (dma_alloc_coherent, %u byte budget); the device is %sDMA-coherent, cached_mmap %s\n",
		ION_BUDGET, ion_coherent ? "" : "not ",
		cached_mmap ? "on" : "off");
	return 0;

err_pdev:
	platform_device_unregister(ion_pdev);
	ion_pdev = NULL;
	return ret;
}

static void __exit soph_ion_exit(void)
{
	struct ion_buffer *b, *t;

	misc_deregister(&soph_ion_misc);

	/* An open dma-buf pins this module, so what is left holds only the
	 * allocation's reference. */
	mutex_lock(&ion_lock);
	list_for_each_entry_safe(b, t, &ion_bufs, node) {
		pr_warn("soph_ion: leaking %zu bytes at %pa\n", b->size, &b->paddr);
		list_del(&b->node);
		dma_free_coherent(&ion_pdev->dev, b->size, b->vaddr, b->dma);
		kfree(b);
	}
	mutex_unlock(&ion_lock);

	if (ion_pdev)
		platform_device_unregister(ion_pdev);
}

module_init(soph_ion_init);
module_exit(soph_ion_exit);
MODULE_DESCRIPTION("ION compatibility shim for the Cvitek display stack");
MODULE_LICENSE("GPL");
MODULE_IMPORT_NS("DMA_BUF");

void soph_cache_flush_phys(phys_addr_t pa, size_t len)
{
	if (ion_pdev)
		dma_sync_single_for_device(&ion_pdev->dev, (dma_addr_t)pa, len,
					   DMA_TO_DEVICE);
}
EXPORT_SYMBOL_GPL(soph_cache_flush_phys);

void soph_cache_invalidate_phys(phys_addr_t pa, size_t len)
{
	if (ion_pdev)
		dma_sync_single_for_cpu(&ion_pdev->dev, (dma_addr_t)pa, len,
					DMA_FROM_DEVICE);
}
EXPORT_SYMBOL_GPL(soph_cache_invalidate_phys);
