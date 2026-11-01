include $(PWD)/../Makefile.interdrv.param

obj-m += soph_dispsrc.o
soph_dispsrc-y += dispsrc.o

# Same include set as interdrv/vpss; Makefile.interdrv.param supplies -D__CV181X__.
ccflags-y += -I$(PWD)/../vpss/chip/$(CVIARCH_L)/ -I$(PWD)/../vpss/common/
ccflags-y += -I$(PWD)/../include/common/uapi/ -I$(PWD)/../include/chip/$(CVIARCH_L)/uapi/
ccflags-y += -I$(PWD)/../include/common/kapi/
ccflags-y += -I$(PWD)/../include/
ccflags-y += -I$(PWD)/../base/
ccflags-y += -I$(PWD)/../base/chip/$(CVIARCH_L)
ccflags-y += -I$(PWD)/../sys/common/ -I$(PWD)/../sys/common/uapi

KBUILD_EXTRA_SYMBOLS += $(PWD)/../vpss/Module.symvers

all:
	$(MAKE) ARCH=${ARCH} -C $(KERNEL_DIR) M=$(PWD) modules

clean:
	rm -f *.o .*.cmd modules.order Module.symvers *.ko *.mod.c
	rm -rf .tmp_versions
