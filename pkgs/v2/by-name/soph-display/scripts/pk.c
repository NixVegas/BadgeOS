/* pk - /dev/mem peek/poke. usage: pk <addr> [value] [count]  (32-bit words) */
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <sys/mman.h>
#include <stdint.h>

int main(int argc, char **argv)
{
	unsigned long addr, page, off;
	unsigned long val = 0, n = 1, i;
	int fd, poke = 0;
	volatile uint32_t *p;
	void *m;

	if (argc < 2) { fprintf(stderr, "usage: pk <addr> [val] [count]\n"); return 2; }
	addr = strtoul(argv[1], NULL, 0);
	if (argc > 2 && strcmp(argv[2], "-")) { val = strtoul(argv[2], NULL, 0); poke = 1; }
	if (argc > 3) n = strtoul(argv[3], NULL, 0);

	fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) { fprintf(stderr, "open /dev/mem: %s\n", strerror(errno)); return 1; }
	page = addr & ~0xfffUL;
	off = addr & 0xfff;
	m = mmap(NULL, 0x2000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, page);
	if (m == MAP_FAILED) {
		int e = errno;

		/* EPERM: RAM, or a register a driver claimed (IO_STRICT_DEVMEM) */
		fprintf(stderr, "mmap %#lx: %s%s\n", page, strerror(e),
			e == EPERM ?" (a claimed register needs iomem=relaxed on the kernel command line; RAM is never mapped)" : "");
		return 1;
	}
	p = (volatile uint32_t *)((char *)m + off);
	if (poke) {
		p[0] = (uint32_t)val;
		printf("%#010lx <= %#010lx (now %#010x)\n", addr, val, p[0]);
	} else {
		for (i = 0; i < n; i++)
			printf("%#010lx = %#010x\n", addr + 4 * i, p[i]);
	}
	munmap(m, 0x2000);
	close(fd);
	return 0;
}
