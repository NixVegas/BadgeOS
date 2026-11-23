/* GC4653 capture through CSI0 and VI/ISP to NV21, using the vendor sample call
 * order and sensor configuration. Open only base, sys and vi: CVI_SYS_Init()
 * opens VPSS/VO, disrupting the shared display; closing VO disables its clocks.
 * Sensor: address 0x29, MIPI device 0, lanes 4/3/2 with clock pad 4, no PN swap, MCLK1. */
#include "pipeline.h"

#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "cvi_buffer.h"
#include "cvi_comm_3a.h"
#include "cvi_comm_isp.h"
#include "cvi_comm_sns.h"
#include "cvi_comm_vb.h"
#include "cvi_sns_ctrl.h"
#include "cvi_sys.h"
#include "cvi_sys_base.h"
#include "cvi_vb.h"
#include "cvi_vi.h"
#include "cvi_isp.h"
#include "cvi_ae.h"
#include "cvi_awb.h"

#include <sys/ioctl.h>

#include "linux/vi_isp.h"
#include "linux/vi_uapi.h"

/* Where the log levels sit in base's shared memory (linux/cvi_base_ctx.h). */
#ifndef BASE_LOG_LEVEL_OFFSET
#define BASE_LOG_LEVEL_OFFSET 0x10
#endif

/* Exported by libsys, which CVI_SYS_Init() calls them from; no header declares them. */
CVI_S32 CVI_SYS_DevMem_Open(void);
CVI_S32 CVI_SYS_DevMem_Close(void);
/*
 * The vi driver starts in scaler-online mode, in which the first complete frame is
 * handed to the VPSS scaler through a kernel callback. That block belongs to the
 * running display here, and the handoff takes the board down. The mode set through
 * CVI_SYS_SetVIVPSSMode() below never reaches the driver without the full system
 * init, so it is also set on the device itself; the driver logs
 * "set is_offline_scaler:1" when it takes.
 */
static int vi_set_scaler_offline(int fd)
{
	struct cvi_isp_sc_online sc;
	struct vi_ext_control c;

	memset(&sc, 0, sizeof(sc));
	sc.raw_num = 0;
	sc.is_sc_online = 0;

	memset(&c, 0, sizeof(c));
	c.id = VI_IOCTL_SC_ONLINE;
	c.ptr = &sc;

	return ioctl(fd, VI_IOC_S_CTRL, &c);
}

/* libvi's VI_IOCTL_3DNR wrapper; the driver starts with temporal noise reduction on
 * and the pipe attribute's bNrEn never reaches it. */
int vi_set_3dnr(int fd, CVI_BOOL is_3dnr_on);

#define PIPE 0
#define DEV 0
#define CHN 0
#define MIPI_DEV 0

extern CVI_S32 *log_levels;

static ISP_SNS_OBJ_S *const sns = &stSnsGc4653_Obj;

static struct {
	bool base, sys, vi, devmem, shm, vb, sensor_cb, ae, awb, dev, mipi_clk, pipe, isp, chn;
	pthread_t isp_thread;
	bool isp_running;
	struct map {
		CVI_U64 phys;
		void *virt;
		CVI_U32 size;
	} maps[8];
	unsigned nmaps;
} st;

static void fail(const char *what, CVI_S32 ret)
{
	fprintf(stderr, "badge-camera: %s failed (%#x)\n", what, (unsigned)ret);
}

#define TRY(call, flag)                                       \
	do {                                                  \
		CVI_S32 r_ = (call);                          \
		if (r_ != CVI_SUCCESS) {                      \
			fail(#call, r_);                      \
			return -1;                            \
		}                                             \
		flag;                                         \
	} while (0)


/* The /dev/i2c-N whose adapter is the named controller (e.g. "4040000.i2c"). */
static int find_i2c_bus(const char *controller)
{
	DIR *d = opendir("/sys/class/i2c-dev");
	struct dirent *e;
	int bus = -1;

	if (!d)
		return -1;
	while (bus < 0 && (e = readdir(d))) {
		char link[PATH_MAX], target[PATH_MAX];
		ssize_t n;

		if (strncmp(e->d_name, "i2c-", 4))
			continue;
		snprintf(link, sizeof(link), "/sys/class/i2c-dev/%s/device/..", e->d_name);
		if (!realpath(link, target))
			continue;
		n = strlen(target);
		if (n >= (ssize_t)strlen(controller) &&
		    !strcmp(target + n - strlen(controller), controller))
			bus = atoi(e->d_name + 4);
	}
	closedir(d);
	return bus;
}

static void *isp_run(void *arg)
{
	(void)arg;
	CVI_S32 r = CVI_ISP_Run(PIPE);
	if (r != CVI_SUCCESS)
		fail("CVI_ISP_Run", r);
	return NULL;
}

/* base, sys and vi only; see the comment at the top. */
static int sys_open(void)
{
	VI_VPSS_MODE_S mode;
	char *shm;

	TRY(base_dev_open(), st.base = true);
	TRY(sys_dev_open(), st.sys = true);
	TRY(CVI_SYS_DevMem_Open(), st.devmem = true);
	shm = base_get_shm();
	if (!shm) {
		fprintf(stderr, "badge-camera: base shared memory not mapped\n");
		return -1;
	}
	st.shm = true;
	log_levels = (CVI_S32 *)(shm + BASE_LOG_LEVEL_OFFSET);
	TRY(vi_dev_open(), st.vi = true);
	/* VI writes frames to memory; nothing runs online into VPSS. */
	memset(&mode, 0, sizeof(mode));
	for (int i = 0; i < VI_MAX_PIPE_NUM; i++)
		mode.aenMode[i] = VI_OFFLINE_VPSS_OFFLINE;
	TRY(CVI_SYS_SetVIVPSSMode(&mode), (void)0);
	TRY(vi_set_scaler_offline(get_vi_fd()), (void)0);
	return 0;
}

static int vb_open(unsigned buffers)
{
	VB_CONFIG_S c;

	memset(&c, 0, sizeof(c));
	c.u32MaxPoolCnt = 1;
	c.astCommPool[0].u32BlkSize = COMMON_GetPicBufferSize(CAM_WIDTH, CAM_HEIGHT, PIXEL_FORMAT_NV21,
		DATA_BITWIDTH_8, COMPRESS_MODE_NONE, DEFAULT_ALIGN);
	c.astCommPool[0].u32BlkCnt = buffers;
	c.astCommPool[0].enRemapMode = VB_REMAP_MODE_CACHED;
	TRY(CVI_VB_SetConfig(&c), (void)0);
	TRY(CVI_VB_Init(), st.vb = true);
	return 0;
}

static int sensor_open(const struct cam_options *opt)
{
	ISP_INIT_ATTR_S init;
	RX_INIT_ATTR_S rx;
	ISP_SNS_COMMBUS_U bus;
	ISP_SENSOR_EXP_FUNC_S exp;
	ISP_CMOS_SENSOR_IMAGE_MODE_S mode;
	ALG_LIB_S ae, awb;
	const CVI_S16 lanes[5] = { 4, 3, 2, -1, -1 };
	int busno = opt->i2c_bus;

	if (busno < 0)
		busno = find_i2c_bus(opt->i2c_controller);
	if (busno < 0) {
		fprintf(stderr, "badge-camera: no /dev/i2c-N for %s\n", opt->i2c_controller);
		return -1;
	}

	memset(&rx, 0, sizeof(rx));
	rx.MipiDev = MIPI_DEV;
	for (int i = 0; i < 5; i++) {
		rx.as16LaneId[i] = lanes[i];
		rx.as8PNSwap[i] = 0;
	}
	rx.stMclkAttr.bMclkEn = CVI_TRUE;
	rx.stMclkAttr.u8Mclk = 1;
	TRY(sns->pfnPatchRxAttr(&rx), (void)0);

	memset(&init, 0, sizeof(init));
	init.enGainMode = SNS_GAIN_MODE_SHARE;
	init.enSnsBdgMuxMode = SNS_BDG_MUX_NONE;
	if (sns->pfnSetInit)
		TRY(sns->pfnSetInit(PIPE, &init), (void)0);
	memset(&bus, 0, sizeof(bus));
	bus.s8I2cDev = (CVI_S8)busno;
	TRY(sns->pfnSetBusInfo(PIPE, bus), (void)0);
	if (sns->pfnPatchI2cAddr)
		sns->pfnPatchI2cAddr(0x29);

	memset(&ae, 0, sizeof(ae));
	memset(&awb, 0, sizeof(awb));
	ae.s32Id = PIPE;
	awb.s32Id = PIPE;
	snprintf(ae.acLibName, sizeof(ae.acLibName), "%s", CVI_AE_LIB_NAME);
	snprintf(awb.acLibName, sizeof(awb.acLibName), "%s", CVI_AWB_LIB_NAME);
	TRY(sns->pfnRegisterCallback(PIPE, &ae, &awb), st.sensor_cb = true);

	memset(&exp, 0, sizeof(exp));
	TRY(sns->pfnExpSensorCb(&exp), (void)0);
	memset(&mode, 0, sizeof(mode));
	mode.u16Width = CAM_WIDTH;
	mode.u16Height = CAM_HEIGHT;
	mode.f32Fps = 30;
	if (exp.pfn_cmos_set_image_mode)
		TRY(exp.pfn_cmos_set_image_mode(PIPE, &mode), (void)0);
	if (exp.pfn_cmos_set_wdr_mode)
		TRY(exp.pfn_cmos_set_wdr_mode(PIPE, WDR_MODE_NONE), (void)0);
	return 0;
}

/* The GC4653 reads the red pixel first; VI and ISP use the same Bayer order. */
static int dev_open(void)
{
	VI_DEV_ATTR_S a;

	memset(&a, 0, sizeof(a));
	a.enIntfMode = VI_MODE_MIPI;
	a.enWorkMode = VI_WORK_MODE_1Multiplex;
	a.enScanMode = VI_SCAN_PROGRESSIVE;
	for (int i = 0; i < 4; i++)
		a.as32AdChnId[i] = -1;
	a.enDataSeq = VI_DATA_SEQ_YUYV;
	a.stSynCfg.enVsync = VI_VSYNC_PULSE;
	a.stSynCfg.enVsyncNeg = VI_VSYNC_NEG_LOW;
	a.stSynCfg.enHsync = VI_HSYNC_VALID_SINGNAL;
	a.stSynCfg.enHsyncNeg = VI_HSYNC_NEG_HIGH;
	a.stSynCfg.enVsyncValid = VI_VSYNC_VALID_SIGNAL;
	a.stSynCfg.enVsyncValidNeg = VI_VSYNC_VALID_NEG_HIGH;
	a.stSynCfg.stTimingBlank.u32HsyncAct = CAM_WIDTH;
	a.stSynCfg.stTimingBlank.u32VsyncVact = CAM_HEIGHT;
	a.enInputDataType = VI_DATA_TYPE_RGB;
	a.stSize.u32Width = CAM_WIDTH;
	a.stSize.u32Height = CAM_HEIGHT;
	a.stWDRAttr.enWDRMode = WDR_MODE_NONE;
	a.stWDRAttr.u32CacheLine = CAM_HEIGHT;
	a.enBayerFormat = (BAYER_FORMAT_E)BAYER_FORMAT_RG;
	/* Full raw-frame mode can wedge the sensor pipeline; use slice buffers. */
	a.disEnableSbm = false;
	a.snrFps = 30;
	TRY(CVI_VI_SetDevAttr(DEV, &a), (void)0);
	TRY(CVI_VI_EnableDev(DEV), st.dev = true);
	return 0;
}

static int mipi_open(void)
{
	SNS_COMBO_DEV_ATTR_S rx;
	int devno;

	memset(&rx, 0, sizeof(rx));
	TRY(sns->pfnGetRxAttr(PIPE, &rx), (void)0);
	devno = rx.devno;
	TRY(CVI_MIPI_SetSensorReset(devno, 1), (void)0);
	TRY(CVI_MIPI_SetMipiReset(devno, 1), (void)0);
	TRY(CVI_MIPI_SetMipiAttr(PIPE, &rx), (void)0);
	TRY(CVI_MIPI_SetSensorClock(devno, 1), st.mipi_clk = true);
	usleep(20);
	TRY(CVI_MIPI_SetSensorReset(devno, 0), (void)0);
	if (sns->pfnSnsProbe)
		TRY(sns->pfnSnsProbe(PIPE), (void)0);
	return 0;
}

static int pipe_open(const struct cam_options *opt)
{
	VI_PIPE_ATTR_S p;

	TRY(vi_set_3dnr(get_vi_fd(), opt->tnr ? CVI_TRUE : CVI_FALSE), (void)0);

	memset(&p, 0, sizeof(p));
	p.bYuvSkip = CVI_FALSE;
	p.u32MaxW = CAM_WIDTH;
	p.u32MaxH = CAM_HEIGHT;
	/* 12 bits, although the sensor sends RAW10: the ISP left-aligns the data, which is
	 * why the GC4653's own black level calibration in the sensor driver is 256, i.e.
	 * 64 << 2. */
	p.enPixFmt = PIXEL_FORMAT_RGB_BAYER_12BPP;
	p.enBitWidth = DATA_BITWIDTH_12;
	p.stFrameRate.s32SrcFrameRate = -1;
	p.stFrameRate.s32DstFrameRate = -1;
	p.bNrEn = opt->tnr;
	p.bYuvBypassPath = CVI_FALSE;
	p.enCompressMode = COMPRESS_MODE_NONE;
	TRY(CVI_VI_CreatePipe(PIPE, &p), st.pipe = true);
	TRY(CVI_VI_StartPipe(PIPE), (void)0);
	return 0;
}

/* These vendor stages require vector instructions unavailable to this process. */
#if CAMERA_GRAYSCALE
static int isp_disable_vector_stages(void)
{
	ISP_MESH_SHADING_ATTR_S mlsc;
	ISP_CLUT_ATTR_S clut;

	TRY(CVI_ISP_GetMeshShadingAttr(PIPE, &mlsc), (void)0);
	mlsc.Enable = CVI_FALSE;
	TRY(CVI_ISP_SetMeshShadingAttr(PIPE, &mlsc), (void)0);

	TRY(CVI_ISP_GetClutAttr(PIPE, &clut), (void)0);
	clut.Enable = CVI_FALSE;
	TRY(CVI_ISP_SetClutAttr(PIPE, &clut), (void)0);

	return 0;
}
#endif

static int isp_open(void)
{
	ALG_LIB_S ae, awb;
	ISP_BIND_ATTR_S bind;
	ISP_PUB_ATTR_S pub;

	memset(&ae, 0, sizeof(ae));
	memset(&awb, 0, sizeof(awb));
	ae.s32Id = PIPE;
	awb.s32Id = PIPE;
	snprintf(ae.acLibName, sizeof(ae.acLibName), "%s", CVI_AE_LIB_NAME);
	snprintf(awb.acLibName, sizeof(awb.acLibName), "%s", CVI_AWB_LIB_NAME);
	TRY(CVI_AE_Register(PIPE, &ae), st.ae = true);
	TRY(CVI_AWB_Register(PIPE, &awb), st.awb = true);

	memset(&bind, 0, sizeof(bind));
	snprintf(bind.stAeLib.acLibName, sizeof(bind.stAeLib.acLibName), "%s", CVI_AE_LIB_NAME);
	bind.stAeLib.s32Id = PIPE;
	snprintf(bind.stAwbLib.acLibName, sizeof(bind.stAwbLib.acLibName), "%s", CVI_AWB_LIB_NAME);
	bind.stAwbLib.s32Id = PIPE;
	bind.sensorId = 0;
	TRY(CVI_ISP_SetBindAttr(PIPE, &bind), (void)0);
	TRY(CVI_ISP_MemInit(PIPE), (void)0);

	memset(&pub, 0, sizeof(pub));
	pub.stWndRect.u32Width = CAM_WIDTH;
	pub.stWndRect.u32Height = CAM_HEIGHT;
	pub.stSnsSize.u32Width = CAM_WIDTH;
	pub.stSnsSize.u32Height = CAM_HEIGHT;
	pub.f32FrameRate = 30;
	pub.enBayer = (ISP_BAYER_FORMAT_E)BAYER_FORMAT_RG;
	pub.enWDRMode = WDR_MODE_NONE;
	TRY(CVI_ISP_SetPubAttr(PIPE, &pub), (void)0);
	TRY(CVI_ISP_Init(PIPE), st.isp = true);
#if CAMERA_GRAYSCALE
	if (isp_disable_vector_stages())
		return -1;
	fprintf(stderr, "badge-camera: mesh shading and color table: off\n");
#endif

	/* An ordinary thread: CVI_ISP_Run sleeps on the VI's frame events, and real-time
	 * priority on one core would compete with the compositor. */
	if (pthread_create(&st.isp_thread, NULL, isp_run, NULL)) {
		fprintf(stderr, "badge-camera: ISP thread: %s\n", strerror(errno));
		return -1;
	}
	st.isp_running = true;
	return 0;
}

static int chn_open(const struct cam_options *opt)
{
	VI_CHN_ATTR_S c;
	memset(&c, 0, sizeof(c));
	/* The sensor's size: the channel cannot scale. The ISP writes full-size rows
	 * whatever is asked for here, and a smaller size only shrinks the frame's
	 * description of them. */
	c.stSize.u32Width = CAM_WIDTH;
	c.stSize.u32Height = CAM_HEIGHT;
	c.enPixelFormat = PIXEL_FORMAT_NV21;
	c.enDynamicRange = DYNAMIC_RANGE_SDR8;
	c.enVideoFormat = VIDEO_FORMAT_LINEAR;
	c.enCompressMode = COMPRESS_MODE_NONE;
	c.bMirror = opt->mirror;
	c.bFlip = opt->flip;
	c.u32Depth = 0;
	c.stFrameRate.s32SrcFrameRate = -1;
	c.stFrameRate.s32DstFrameRate = -1;
	TRY(CVI_VI_SetChnAttr(PIPE, CHN, &c), (void)0);
	TRY(CVI_VI_EnableChn(PIPE, CHN), st.chn = true);
	return 0;
}

int cam_open(const struct cam_options *opt)
{
	if (sys_open() || vb_open(2) ||
	    sensor_open(opt) || dev_open() ||
	    mipi_open() || pipe_open(opt) ||
	    isp_open() || chn_open(opt)) {
		cam_close();
		return -1;
	}
	return 0;
}

static void *map_block(CVI_U64 phys, CVI_U32 size)
{
	for (unsigned i = 0; i < st.nmaps; i++)
		if (st.maps[i].phys == phys && st.maps[i].size >= size)
			return st.maps[i].virt;
	if (st.nmaps == sizeof(st.maps) / sizeof(st.maps[0]))
		return NULL;
	void *v = CVI_SYS_MmapCache(phys, size);
	if (!v)
		return NULL;
	st.maps[st.nmaps++] = (struct map){ phys, v, size };
	return v;
}

int cam_get(struct cam_frame *f, int timeout_ms)
{
	VIDEO_FRAME_INFO_S *info = calloc(1, sizeof(*info));
	VIDEO_FRAME_S *v;
	CVI_U32 len;
	uint8_t *base;

	if (!info)
		return -1;
	CVI_S32 r = CVI_VI_GetChnFrame(PIPE, CHN, info, timeout_ms);
	if (r != CVI_SUCCESS) {
		free(info);
		return -1;
	}
	v = &info->stVFrame;
	if (!v->u64PhyAddr[0] || !v->u64PhyAddr[1] || v->u64PhyAddr[1] < v->u64PhyAddr[0] ||
	    v->u32Stride[0] < v->u32Width || v->u32Width > CAM_WIDTH || v->u32Height > CAM_HEIGHT) {
		fprintf(stderr, "badge-camera: unusable frame %ux%u stride %u\n", v->u32Width,
			v->u32Height, v->u32Stride[0]);
		CVI_VI_ReleaseChnFrame(PIPE, CHN, info);
		free(info);
		return -1;
	}
	/* NV21 in one block: luma, then the VU plane. */
	len = (CVI_U32)(v->u64PhyAddr[1] - v->u64PhyAddr[0]) + v->u32Length[1];
	base = map_block(v->u64PhyAddr[0], len);
	if (!base) {
		CVI_VI_ReleaseChnFrame(PIPE, CHN, info);
		free(info);
		return -1;
	}
	/* CVI_SYS_MmapCache and CVI_SYS_Mmap map these ION buffers write-combined
 * despite VB_REMAP_MODE_CACHED. No invalidation is needed. If the mappings
 * become cacheable, restore CVI_SYS_IonInvalidateCache(v->u64PhyAddr[0], base, len). */
	f->y = base;
	f->vu = base + (v->u64PhyAddr[1] - v->u64PhyAddr[0]);
	f->stride = v->u32Stride[0];
	f->width = v->u32Width;
	f->height = v->u32Height;
	f->handle = info;
	{
		static bool limited;

		if (!limited) {
			limited = true;
		}
	}
	return 0;
}

void cam_release(struct cam_frame *f)
{
	if (!f->handle)
		return;
	CVI_VI_ReleaseChnFrame(PIPE, CHN, f->handle);
	free(f->handle);
	f->handle = NULL;
}

void cam_close(void)
{
	ALG_LIB_S ae, awb;

	memset(&ae, 0, sizeof(ae));
	memset(&awb, 0, sizeof(awb));
	ae.s32Id = PIPE;
	awb.s32Id = PIPE;
	snprintf(ae.acLibName, sizeof(ae.acLibName), "%s", CVI_AE_LIB_NAME);
	snprintf(awb.acLibName, sizeof(awb.acLibName), "%s", CVI_AWB_LIB_NAME);

	for (unsigned i = 0; i < st.nmaps; i++)
		CVI_SYS_Munmap(st.maps[i].virt, st.maps[i].size);
	st.nmaps = 0;
	if (st.chn)
		CVI_VI_DisableChn(PIPE, CHN);
	if (st.isp_running) {
		CVI_ISP_Exit(PIPE);
		pthread_join(st.isp_thread, NULL);
	} else if (st.isp) {
		CVI_ISP_Exit(PIPE);
	}
	if (st.sensor_cb)
		sns->pfnUnRegisterCallback(PIPE, &ae, &awb);
	if (st.ae)
		CVI_AE_UnRegister(PIPE, &ae);
	if (st.awb)
		CVI_AWB_UnRegister(PIPE, &awb);
	if (st.pipe) {
		CVI_VI_StopPipe(PIPE);
		CVI_VI_DestroyPipe(PIPE);
	}
	if (st.dev)
		CVI_VI_DisableDev(DEV);
	if (st.mipi_clk) {
		if (sns->pfnStandby)
			sns->pfnStandby(PIPE);
		CVI_MIPI_SetSensorClock(MIPI_DEV, 0);
	}
	if (st.vb)
		CVI_VB_Exit();
	if (st.vi)
		vi_dev_close();
	if (st.shm) {
		log_levels = NULL;
		base_release_shm();
	}
	if (st.devmem)
		CVI_SYS_DevMem_Close();
	if (st.sys)
		sys_dev_close();
	if (st.base)
		base_dev_close();
	memset(&st, 0, sizeof(st));
}

int cam_cleanup(void)
{
	CVI_S32 r;

	if (base_dev_open() != CVI_SUCCESS)
		return -1;
	r = CVI_VB_Exit();
	base_dev_close();
	return r == CVI_SUCCESS ? 0 : -1;
}
