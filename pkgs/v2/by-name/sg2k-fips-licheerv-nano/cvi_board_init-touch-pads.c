/* The Nano's board init, then the RTC pad controls of PWR_SEQ1/2 (PWR_GPIO3/4) released
 * from the power sequencer, for the touchscreen's IRQ and reset. */
#define cvi_board_init licheerv_nano_board_init
#include "licheerv-nano-board-init.c"
#undef cvi_board_init

static void cvi_board_init(void)
{
	licheerv_nano_board_init();
	mmio_write_32(0x05027078, 0x11); /* PWR_GPIO3: touch IRQ */
	mmio_write_32(0x0502707c, 0x11); /* PWR_GPIO4: touch reset */
}
