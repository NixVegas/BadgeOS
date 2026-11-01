/*
 * vofeed, push NV21 frames straight into the vendor VO layer.
 *
 * badge_landscape_vo goes VDEC(H.264) -> VO, which needs cvi_vc_driver; that
 * module loads but registers no device node here, so CVI_VDEC_* has nothing to
 * open. The VO layer itself comes up fine (VB pool live, layer + channel
 * configured at 1280x720 NV21), so skip the decoder entirely: grab a VB block,
 * draw into it, and CVI_VO_SendFrame it.
 *
 * That is also the shape the badge demo wants, a framebuffer it renders into,
 * not a video file.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>

#include "cvi_buffer.h"
#include "cvi_sys.h"
#include "cvi_vb.h"
#include "cvi_vo.h"

#define W 1280
#define H 720
#define VO_DEV 0
#define VO_LAYER 0
#define VO_CHN 0

static volatile int stop_now;
static void on_sig(int s) { (void)s; stop_now = 1; }

#define TRY(x) do { CVI_S32 _r = (x); \
	printf("  %-46s -> %d%s\n", #x, _r, _r ? "  <-- FAILED" : ""); } while (0)

/* BT.601 limited-range NV21 colour bars, scrolled by `phase` pixels. */
static void draw(unsigned char *y, unsigned char *vu, int stride, int phase)
{
	static const unsigned char bar[8][3] = {
		{255,255,255},{255,255,0},{0,255,255},{0,255,0},
		{255,0,255},{255,0,0},{0,0,255},{0,0,0},
	};
	int x, r;

	for (r = 0; r < H; r++) {
		for (x = 0; x < W; x++) {
			const unsigned char *c = bar[(((x + phase) % W) * 8) / W];
			int Y = (66*c[0] + 129*c[1] + 25*c[2] + 128) / 256 + 16;

			y[r * stride + x] = Y < 16 ? 16 : (Y > 235 ? 235 : Y);
		}
	}
	for (r = 0; r < H / 2; r++) {
		for (x = 0; x < W / 2; x++) {
			const unsigned char *c = bar[((((2*x + phase) % W)) * 8) / W];
			int U = (-38*c[0] - 74*c[1] + 112*c[2] + 128) / 256 + 128;
			int V = (112*c[0] - 94*c[1] - 18*c[2] + 128) / 256 + 128;

			vu[r * stride + 2*x + 0] = V < 16 ? 16 : (V > 240 ? 240 : V);
			vu[r * stride + 2*x + 1] = U < 16 ? 16 : (U > 240 ? 240 : U);
		}
	}
}

int main(void)
{
	VB_CONFIG_S vb;
	VO_PUB_ATTR_S pub;
	VO_VIDEO_LAYER_ATTR_S layer;
	VO_CHN_ATTR_S chn;
	VIDEO_FRAME_INFO_S f;
	VB_BLK blk;
	CVI_U64 phys;
	CVI_U32 sz = W * H * 3 / 2;
	unsigned char *va;
	int phase = 0, n = 0;

	signal(SIGINT, on_sig);
	signal(SIGTERM, on_sig);

	printf("== sys/vb ==\n");
	CVI_SYS_Exit(); CVI_VB_Exit();
	memset(&vb, 0, sizeof(vb));
	vb.u32MaxPoolCnt = 1;
	vb.astCommPool[0].u32BlkSize = sz;
	vb.astCommPool[0].u32BlkCnt = 4;
	vb.astCommPool[0].enRemapMode = VB_REMAP_MODE_CACHED;
	TRY(CVI_VB_SetConfig(&vb));
	TRY(CVI_VB_Init());
	TRY(CVI_SYS_Init());

	printf("== vo ==\n");
	memset(&pub, 0, sizeof(pub));
	pub.u32BgColor = 0x000003ff;
	pub.enIntfType = VO_INTF_MIPI;
	pub.enIntfSync = VO_OUTPUT_720P60;
	TRY(CVI_VO_SetPubAttr(VO_DEV, &pub));
	TRY(CVI_VO_Enable(VO_DEV));

	memset(&layer, 0, sizeof(layer));
	layer.stDispRect.u32Width = W;
	layer.stDispRect.u32Height = H;
	layer.stImageSize.u32Width = W;
	layer.stImageSize.u32Height = H;
	layer.u32DispFrmRt = 60;
	layer.enPixFormat = PIXEL_FORMAT_NV21;
	TRY(CVI_VO_SetVideoLayerAttr(VO_LAYER, &layer));
	TRY(CVI_VO_EnableVideoLayer(VO_LAYER));

	memset(&chn, 0, sizeof(chn));
	chn.stRect.u32Width = W;
	chn.stRect.u32Height = H;
	TRY(CVI_VO_SetChnAttr(VO_LAYER, VO_CHN, &chn));
	TRY(CVI_VO_EnableChn(VO_LAYER, VO_CHN));

	printf("== frames ==\n");
	while (!stop_now) {
		blk = CVI_VB_GetBlock(VB_INVALID_POOLID, sz);
		if (blk == VB_INVALID_HANDLE) {
			fprintf(stderr, "CVI_VB_GetBlock failed\n");
			break;
		}
		phys = CVI_VB_Handle2PhysAddr(blk);
		va = CVI_SYS_Mmap(phys, sz);
		if (!va) { fprintf(stderr, "CVI_SYS_Mmap failed\n"); CVI_VB_ReleaseBlock(blk); break; }

		draw(va, va + (size_t)W * H, W, phase);
		CVI_SYS_IonFlushCache(phys, va, sz);
		CVI_SYS_Munmap(va, sz);

		memset(&f, 0, sizeof(f));
		f.stVFrame.enPixelFormat = PIXEL_FORMAT_NV21;
		f.stVFrame.u32Width = W;
		f.stVFrame.u32Height = H;
		f.stVFrame.u32Stride[0] = W;
		f.stVFrame.u32Stride[1] = W;
		f.stVFrame.u64PhyAddr[0] = phys;
		f.stVFrame.u64PhyAddr[1] = phys + (CVI_U64)W * H;
		f.stVFrame.u32Length[0] = W * H;
		f.stVFrame.u32Length[1] = W * H / 2;
		f.u32PoolId = CVI_VB_Handle2PoolId(blk);

		if (CVI_VO_SendFrame(VO_LAYER, VO_CHN, &f, -1) != CVI_SUCCESS)
			fprintf(stderr, "CVI_VO_SendFrame failed (frame %d)\n", n);
		CVI_VB_ReleaseBlock(blk);

		if (n == 0) printf("  first frame sent\n");
		if (++n % 60 == 0) { printf("  %d frames\n", n); fflush(stdout); }
		phase = (phase + 4) % W;
		usleep(16000);
	}

	printf("== down (%d frames) ==\n", n);
	CVI_VO_DisableChn(VO_LAYER, VO_CHN);
	CVI_VO_DisableVideoLayer(VO_LAYER);
	CVI_VO_Disable(VO_DEV);
	CVI_SYS_Exit();
	CVI_VB_Exit();
	return 0;
}
