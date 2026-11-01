obj-m += soph_ion_compat.o
ccflags-y += -I$(PWD)
all:
	$(MAKE) ARCH=$(ARCH) -C $(KERNEL_DIR) M=$(PWD) modules
clean:
	@rm -f *.o *.ko *.mod* .*.cmd modules.order Module.symvers
