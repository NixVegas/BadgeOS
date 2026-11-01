/*
 * badge_landscape_vo, CVITEK/Sophgo SG2000 VDEC -> VO in landscape 1280x720.
 *
 * Equivalent of the vendor "sample_vdecvo case 0/3", but with the portrait
 * forcing removed:
 *
 *      vendor:  enIntfSync = VO_OUTPUT_720x1280_60 (21), layer 720x1280,
 *               CVI_VO_SetChnRotation(..., ROTATION_90)
 *      here:    enIntfSync = VO_OUTPUT_720P60      (6),  layer 1280x720,
 *               CVI_VO_SetChnRotation(..., ROTATION_0)
 *
 * Built against sophgo/cvi_mpi (branch sg200x-dev) headers and linked against
 * the badge's own /mnt/system/usr/lib/{libsys,libvo,libvdec}.so, copied off
 * the board.  The dynamic linker and RUNPATH have to be set for the target,
 * because the badge's vendor middleware lives outside the Nix store:
 *
 *      $CC -O2 -Wall -Wextra -D__CV181X__ -I cvi_mpi/include \
 *          -o badge_landscape_vo badge_landscape_vo.c \
 *          -Wl,--dynamic-linker=/lib/ld-linux-riscv64-lp64d.so.1 \
 *          -Wl,--enable-new-dtags \
 *          -L vendorlib -l:libvo.so -l:libvdec.so -l:libsys.so -lpthread -lm
 *      patchelf --set-rpath /mnt/system/usr/lib badge_landscape_vo
 *
 * -D__CV181X__ only matters if you use CVI_SYS_Bind (BLVO_BIND=1). The badge's
 * stock libsys.so was built -D__CV180X__, and that define does exactly two
 * things outside the ISP: it makes CVI_SYS_Bind and CVI_SYS_UnBind reject any
 * pair whose *destination* is CVI_ID_VO, on the grounds that CV180X has no VO
 * device. The default pump path touches none of that, GetFrame, SendFrame
 * and ReleaseFrame are ungated, so the stock library is fine here.
 * See site/src/hdmi.md.
 *
 * failure policy: every setup call is best-effort.  A failing call is logged
 * and counted, and setup continues, so one unsupported call cannot hide the
 * state of everything after it.  The only stage that gates the run is the VDEC
 * channel itself: with no channel there is nothing to feed, so the feeder is
 * not started (it would spin on CVI_VDEC_SendStream forever).  Everything that
 * was attempted is still torn down, and report() prints what actually stuck.
 *
 * stopping: a newline on stdin, or SIGINT/SIGTERM (so `systemctl stop` is a
 * clean stop).  Other stdin bytes are ignored.  EOF on stdin only stops the run
 * when stdin is a terminal, an inherited, closed or /dev/null stdin must not
 * end the run.  Waiting is done with poll() on stdin plus a self-pipe, so there
 * is no busy-poll and no signal race.
 *
 * The vendor stack leaks its VB pool and faults the kernel if the process is
 * SIGKILLed, so never kill -9 this.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <poll.h>
#include <pthread.h>
#include <sys/prctl.h>
#include <time.h>

#include "cvi_buffer.h"
#include "cvi_sys.h"
#include "cvi_vb.h"
#include "cvi_vo.h"
#include "cvi_vdec.h"

/* configuration */

#define VO_DEV_ID              0
#define VO_LAYER_ID            0
#define VO_CHN_ID              0
#define VDEC_CHN_ID            0

#define DEF_WIDTH              1280
#define DEF_HEIGHT             720

/* VO_OUTPUT_720P60 == 6 (cvi_comm_vo.h).  The vendor sample forces 21
 * (VO_OUTPUT_720x1280_60) which starves the 1280x720 raster.
 */
#define VO_SYNC                VO_OUTPUT_720P60
#define VO_INTF                VO_INTF_MIPI
#define VO_DISP_BUF_LEN        3
/* COLOR_10_RGB_BLUE == RGB(0,0,0x3FF); the vendor GetDefConfig default. */
#define VO_BG_COLOR            0x000003FFu
#define VO_PIX_FMT             VI_PIXEL_FORMAT        /* PIXEL_FORMAT_NV21 */

#define COMMON_POOL_BLK_CNT    8
#define VDEC_POOL_BLK_CNT      10
#define VDEC_FRAME_BUF_CNT     4
#define VDEC_DISPLAY_FRAME_NUM 2

/* stop reading a non-tty stdin that never sends a newline (e.g. < /dev/zero) */
#define STDIN_JUNK_LIMIT       (1u << 20)

static CVI_U32 g_width  = DEF_WIDTH;
static CVI_U32 g_height = DEF_HEIGHT;

/* state */

static volatile sig_atomic_t g_quit;
static int g_sigpipe[2] = { -1, -1 };

static const char *g_stream_path;
static pthread_t   g_feeder;
static volatile int g_feeder_stop;

/*
 * The VDEC -> VO pump.
 *
 * There is no in-kernel path that moves a decoded frame into VO: enum
 * VO_CB_CMD (interdrv/include/common/kapi/vo_cb.h) covers RGN, the scaler
 * IRQ and QBUF only, there is no SEND_FRAME command, so a CVI_SYS_Bind
 * from VDEC to VO registers in /proc/cvitek/sys and then moves nothing.
 * The vendor's own sample_vdecvo.c never binds either; it pumps the frames
 * across by hand.  So do we: GetFrame -> VO SendFrame -> ReleaseFrame.
 *
 * Without this the decoder stops after a couple of pictures with
 * DecodedFrame stuck and SendStreamPerSec still climbing, decode is fine,
 * nothing is draining the output.
 */
static pthread_t   g_pump;
static volatile int g_pump_stop;
static int g_do_bind;			/* BLVO_BIND=1 to bind anyway (debug) */
static int g_do_pump = 1;		/* BLVO_PUMP=0 to reproduce the hang */

static unsigned long long g_pump_got, g_pump_sent, g_pump_rel;
static unsigned long long g_pump_get_fail, g_pump_send_fail, g_pump_rel_fail;
static unsigned long long g_pump_idle;	/* "no frame yet"; the normal case */
static unsigned long long g_pump_stale;	/* fetched across a decoder reset   */

static VB_POOL g_pic_pool = VB_INVALID_POOLID;

static unsigned g_setup_fails;

static int st_sys_up;			/* CVI_SYS_Init/CVI_VB_Init attempted   */
static int st_vo_dev;			/* CVI_VO_Enable attempted              */
static int st_vo_layer;			/* CVI_VO_EnableVideoLayer attempted    */
static int st_vo_chn;			/* CVI_VO_EnableChn attempted           */
static int st_vdec_chn;			/* CVI_VDEC_CreateChn SUCCEEDED         */
static int st_attached;			/* CVI_VDEC_AttachVbPool attempted      */
static int st_bound;			/* CVI_SYS_Bind attempted               */

/*
 * soft(): best-effort setup call.  Logs and counts a failure, never aborts.
 * The state flags are set for every call we *attempted*, not only the ones
 * that returned success, for this stack it is far safer to over-clean on
 * exit than to leak a VB pool or a still-enabled layer.
 */
#define SOFT(expr) do {                                                       \
	CVI_S32 _r = (expr);                                                  \
	if (_r != CVI_SUCCESS) {                                              \
		g_setup_fails++;                                              \
		fprintf(stderr, "[badge_landscape_vo] WARN: %s -> %#x"         \
			" (continuing)\n", #expr, (unsigned)_r);              \
	}                                                                     \
} while (0)

#define WARN(expr) do {                                                       \
	CVI_S32 _r = (expr);                                                  \
	if (_r != CVI_SUCCESS)                                                \
		fprintf(stderr, "[badge_landscape_vo] (cleanup) %s -> %#x\n",   \
			#expr, (unsigned)_r);                                 \
} while (0)

/*
 * Playlist, switched live.
 *
 * Changing clips must not restart the process. This program's teardown
 * disables the VO layer, which stops the DISP timing generator (DISP_CFG bit7
 * TGEN_EN) and leaves the LT8912B with no valid DSI, so killing and
 * relaunching per track is a full re-modeset, i.e. a black re-sync on every
 * press. In front of an audience that is unusable. Instead the process stays
 * up and only the feeder's input file changes: VO, DISP and the bridge are
 * never touched, so the link never drops.
 *
 * SIGUSR1 = next, SIGUSR2 = previous. The handler only bumps a flag; the
 * feeder does the actual open/close between access units.
 */
static char **g_playlist;
static int g_playlist_n;
static int g_playlist_i;
static volatile sig_atomic_t g_switch;	/* +1 next, -1 previous, 0 idle */

/*
 * Feed rate, frames/sec (BLVO_FPS). this IS not cosmetic, without it the
 * pipeline deadlocks.
 *
 * The feeder submits access units as fast as CVI_VDEC_SendStream will take
 * them, so a 30 fps clip decodes at 85-97 fps while VO can only retire 60
 * (ChnFrt 60, BufLen 3). Frames handed to VO and not yet presented pile up,
 * measured DispPts 1621 against VoDoneframe 1193, i.e. 428 frames held by VO,
 * the VB pool drains, and the decoder then pins for want of an output buffer:
 * SendStreamPerSec keeps climbing, DecodedFrame stops dead and the picture
 * freezes. It survives a minute or so first, which is what made this look like
 * a track-change bug rather than steady-state overproduction (2026-09-20).
 *
 * Pacing the input fixes it at the source, and it also silences the
 * CVI_VO_SendFrame "send frame fail" spam, which was the same overproduction
 * showing up as backpressure.
 *
 * Default 60 = VO's own presentation rate, so feed and retire are balanced and
 * nothing accumulates. This is the ceiling, not a target to exceed: going above
 * 60 re-creates the deadlock. A clip slower than this simply has its frames
 * repeated by VO, but a 60 fps clip paced at 30 plays at half speed, which is
 * why the default is the panel's rate rather than a conservative 30. Set
 * BLVO_FPS to match the source when it differs.
 */
static long g_fps = 60;

static void on_switch(int sig)
{
	g_switch = (sig == SIGUSR2) ? -1 : 1;
}

/*
 * Stall watchdog.
 *
 * The VDEC -> VO pipeline can hang in steady state: frames handed to VO stop
 * being retired, the VB pool drains, and the feeder then blocks forever inside
 * CVI_VDEC_SendStream() waiting for an output buffer that never comes. The
 * picture freezes on the last presented frame and nothing recovers on its own.
 *
 * Pacing the feeder (see g_fps) makes this rare, but it is not deterministic,
 * 60 fps ran clean for thousands of frames in one session and deadlocked at
 * frame 909 in another, so a fixed rate cannot be trusted in front of an
 * audience. Rather than tune a magic number, recover.
 *
 * Recovery is the same reset the track change uses: only the VDEC channel is
 * stopped/reset/restarted, which unblocks the feeder. VO, DISP and the bridge
 * are untouched, so the HDMI link does not drop and there is no re-modeset,
 * the picture resumes instead of black-flashing.
 */
/*
 * Credit-based rate lock, on top of the g_fps timer.
 *
 * The timer alone paces at exactly 60.000 fps, but the DISP does not run at
 * exactly 60.000 (59.94/60.05 are normal). That difference accumulates: every
 * so often we hand VO one frame more than it can retire, VO drops it, and a
 * scrolling image visibly jumps and then carries on, with the cumulative
 * backlog creeping (measured 811 -> 813 over 3.5 min) rather than sitting still.
 *
 * So do not trust a clock: let VO set the rate. The pump posts one credit per
 * frame it successfully hands to VO, and the feeder spends one before
 * submitting the next access unit. Feed rate then equals retire rate by
 * construction and drift cannot accumulate, whatever the panel's true clock is.
 * The timer stays as an upper bound (so a fast sink cannot make us race the
 * source), and the pipeline is primed with VO_DISP_BUF_LEN credits so the
 * decoder has work before the first frame is ever presented.
 *
 * If VO stops retiring entirely, credits stop, the feeder parks here and
 * g_fed stops advancing, which is exactly what the stall watchdog watches
 * for, so a real hang is still caught and reset.
 */
static pthread_mutex_t g_credit_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  g_credit_cv   = PTHREAD_COND_INITIALIZER;

/*
 * On the size of this window, and why it is not the VO queue depth.
 *
 * It is tempting to match COMMON_POOL_BLK_CNT (8), reasoning that the feeder
 * should never be further ahead than VO can hold. That was tried and it
 * starves the pipeline: measured 14 fps against a target of 60, with the
 * feeder parked and the watchdog resetting the channel every few seconds.
 *
 * The reason is that a credit is spent per access unit but posted per frame,
 * and those are not one to one. Parameter-set and SEI submissions produce no
 * frame at all, measured 7659 access units fed against 7200 frames out, a
 * 6% shortfall. Every one of those spends a credit that never returns, so a
 * small window drains on a short run of them and the feeder blocks waiting
 * for a frame that this access unit was never going to produce.
 *
 * So the window is deliberately generous. It exists to stop the feeder
 * sprinting arbitrarily far ahead, not to meter it frame by frame; the g_fps
 * timer does the pacing and this is the backstop.
 */
#define CREDIT_MAX 32
static int g_credits = CREDIT_MAX;

static void credit_post(void)
{
	pthread_mutex_lock(&g_credit_lock);
	/* Cap the burst: a backlog of credits would let the feeder sprint and
	 * re-create the overproduction this exists to prevent. */
	if (g_credits < CREDIT_MAX)
		g_credits++;
	pthread_cond_signal(&g_credit_cv);
	pthread_mutex_unlock(&g_credit_lock);
}

static void credit_reset(void)
{
	pthread_mutex_lock(&g_credit_lock);
	g_credits = CREDIT_MAX;
	pthread_cond_broadcast(&g_credit_cv);
	pthread_mutex_unlock(&g_credit_lock);
}

/* Spend one credit. Returns 0 if spent, -1 if we gave up waiting (caller
 * re-checks stop). */
static int credit_take(void)
{
	int rc = -1;

	pthread_mutex_lock(&g_credit_lock);
	while (g_credits <= 0 && !g_feeder_stop) {
		struct timespec ts;

		clock_gettime(CLOCK_REALTIME, &ts);
		ts.tv_nsec += 100000000L;		/* 100 ms */
		if (ts.tv_nsec >= 1000000000L) {
			ts.tv_nsec -= 1000000000L;
			ts.tv_sec++;
		}
		/*
		 * advisory, and it has to stay that way. Waiting here for a
		 * credit that is not coming is what turns a momentary hiccup
		 * into a stall: access units and frames are not one to one (see
		 * CREDIT_MAX), so the feeder can legitimately owe more credits
		 * than the stream will ever repay. Time out and let the g_fps
		 * timer pace instead.
		 */
		if (pthread_cond_timedwait(&g_credit_cv, &g_credit_lock,
					   &ts) == ETIMEDOUT)
			break;
	}
	if (g_credits > 0) {
		g_credits--;
		rc = 0;
	}
	pthread_mutex_unlock(&g_credit_lock);
	return rc;
}

static pthread_t g_wdog;
static volatile int g_wdog_stop;
static volatile unsigned long long g_fed;	/* access units handed to VDEC */

/*
 * Bumped immediately before every CVI_VDEC_ResetChn. The pump samples it
 * around GetFrame; if it moved, the frame it is holding belongs to the
 * previous decoder generation and must not be handed to VO or released back.
 * Doing either produced, respectively,
 *
 *   vo_send_frame: VoLayer(0) VoChn(0) PixelFormat(0) mismatch.
 *   [ERR] CVI_VDEC_ReleaseFrame = 2104, Can't find video frame in VideoFrameArray!
 *
 * This does not close the race completely, pump and watchdog are separate
 * threads with no lock between them, but it turns the common case (reset
 * lands while the pump is between GetFrame and SendFrame) from a garbage
 * frame reaching the display into a dropped one.
 */
static volatile unsigned g_vdec_gen;
static unsigned long long g_wdog_recoveries;

static void *wdog_thread(void *arg)
{
	VDEC_CHN chn = (VDEC_CHN)(uintptr_t)arg;
	unsigned long long last = 0;
	int stuck = 0;

	prctl(PR_SET_NAME, "vdec_wdog");

	while (!g_wdog_stop) {
		unsigned long long now;

		sleep(1);
		if (g_wdog_stop)
			break;

		now = g_fed;
		if (now != last) {
			last = now;
			stuck = 0;
			continue;
		}

		/*
		 * A track change briefly pauses the feeder, so do not treat one
		 * quiet second as a stall.
		 */
		if (++stuck < 4)
			continue;

		fprintf(stderr, "[badge_landscape_vo] STALL: no frames fed for %ds"
			" at %llu -- resetting the VDEC channel\n", stuck, now);
		CVI_VDEC_StopRecvStream(chn);
		/* Tell the pump its in-flight frame is about to become invalid.
		 * Releasing a frame across a reset fails with "Can't find video
		 * frame in VideoFrameArray", and sending one to VO shows up as
		 * "PixelFormat(0) mismatch", the struct is stale by then. */
		g_vdec_gen++;
		CVI_VDEC_ResetChn(chn);
		CVI_VDEC_StartRecvStream(chn);
		/* The reset re-primes the decoder, so the feeder must be allowed
		 * through again exactly as at startup. Without this the feeder
		 * stays parked on a credit that can no longer arrive and the
		 * recovery deadlocks instead of recovering. */
		credit_reset();
		g_wdog_recoveries++;
		stuck = 0;
	}
	return NULL;
}

static FILE *open_current(void)
{
	const char *path = g_playlist_n ? g_playlist[g_playlist_i] : g_stream_path;
	FILE *f = fopen(path, "rb");

	if (!f)
		fprintf(stderr, "[badge_landscape_vo] open %s: %s\n",
			path, strerror(errno));
	else
		printf("[badge_landscape_vo] now playing [%d/%d] %s\n",
		       g_playlist_n ? g_playlist_i + 1 : 1,
		       g_playlist_n ? g_playlist_n : 1, path);
	return f;
}

/* H.264 Annex-B frame splitter (verbatim from the vendor sample) */

static void *feeder_thread(void *arg)
{
	VDEC_CHN chn = (VDEC_CHN)(uintptr_t)arg;
	FILE *fp = NULL;
	CVI_U8 *buf = NULL;
	CVI_U8 *p;			/* access unit, in place inside buf   */
	CVI_S32 bufsize = (CVI_S32)((g_width * g_height * 3) >> 1);
	CVI_S32 used = 0, rd;
	long    win_base = -1;		/* file offset of buf[0], -1 = empty  */
	CVI_S32 win_len  = 0;		/* valid bytes in buf                 */
	CVI_U64 pts = 0;
	unsigned long long frames = 0;
	struct timespec next;

	prctl(PR_SET_NAME, "vdec_feeder");

	fp = open_current();
	if (!fp)
		return NULL;
	buf = malloc(bufsize);
	if (!buf) {
		fprintf(stderr, "[badge_landscape_vo] malloc(%d) failed\n", bufsize);
		fclose(fp);
		return NULL;
	}

	printf("[badge_landscape_vo] feeder: %s, chunk %d bytes, %ld fps\n",
	       g_stream_path, bufsize, g_fps);

	clock_gettime(CLOCK_MONOTONIC, &next);

	while (!g_feeder_stop) {
		VDEC_STREAM_S stream;
		CVI_BOOL found_start = CVI_FALSE, found_end = CVI_FALSE;
		CVI_S32 i;
		CVI_S32 ret;

		memset(&stream, 0, sizeof(stream));

		/*
		 * Track change, between access units. Only the input file moves;
		 * the decoder re-syncs on the new stream's SPS/PPS and the VO /
		 * DISP / bridge are left completely alone, so there is no
		 * re-modeset and the HDMI link never drops.
		 */
		if (g_switch && g_playlist_n > 1) {
			int dir = g_switch;

			g_switch = 0;
			g_playlist_i = (g_playlist_i + dir + g_playlist_n) % g_playlist_n;
			fclose(fp);
			fp = open_current();
			if (!fp)
				break;
			used = 0;
			/* Different file: the read window describes the old one. */
			win_base = -1;
			win_len  = 0;

			/*
			 * Re-sync the decoder across the stream discontinuity.
			 * Without this the channel hangs on a track change:
			 * SendStreamPerSec keeps climbing while DecodedFrame
			 * stays pinned at whatever it had reached, because the
			 * channel is still waiting to complete the previous
			 * stream's access unit and never drains again, the
			 * picture freezes on the last decoded frame (measured
			 * 2026-09-20, on the first button press).
			 *
			 * Only the VDEC channel is reset. VO, DISP and the bridge
			 * are deliberately untouched, so the HDMI link still does
			 * not drop and the change stays gapless.
			 */
			CVI_VDEC_StopRecvStream(chn);
			g_vdec_gen++;		/* invalidate any frame the pump holds */
			CVI_VDEC_ResetChn(chn);
			CVI_VDEC_StartRecvStream(chn);
			pts = 0;
			/* Re-base the pacing clock so the new clip does not try to
			 * "catch up" on the time spent switching. */
			clock_gettime(CLOCK_MONOTONIC, &next);
			credit_reset();
		} else if (g_switch) {
			g_switch = 0;		/* single clip: nowhere to go */
		}

		/*
		 * Refill the read window only when it is actually exhausted.
		 *
		 * This used to fseek(used) + fread(bufsize) on every access unit,
		 * which meant re-reading 1280*720*3/2 = 1,382,400 bytes to extract
		 * one ~1 KB access unit. At 60 fps that is ~83 MB/s of copying out
		 * of the page cache, on a part where Linux has a single A53 core,
		 * `perf top` on the badge put __arch_copy_to_user at the top of the
		 * profile. It scales with file size, which is why the 367 KB still
		 * slides were fine and the 17.5 MB clip was not: a short file's
		 * fread returns only what is left, a long one always returns the
		 * full buffer.
		 *
		 * So keep the window: `win_base` is the file offset of buf[0] and
		 * `win_len` the bytes in it, and the access unit is extracted in
		 * place at buf + (used - win_base). Refill when the window no
		 * longer covers `used`, or when too little follows it to be sure of
		 * containing a whole access unit, but only if the last read
		 * actually filled the buffer, since a short read means EOF and
		 * there is nothing more to get.
		 */
		{
			long off = (win_base >= 0) ? (long)used - win_base : -1;

			if (off < 0 || off >= win_len ||
			    (win_len == bufsize && (win_len - off) < bufsize / 2)) {
				if (fseek(fp, used, SEEK_SET) != 0) {
					used = 0;
					fseek(fp, 0, SEEK_SET);
				}
				win_base = used;
				win_len  = (CVI_S32)fread(buf, 1, bufsize, fp);
				off = 0;
				/*
				 * NB: the vendor sample's local bEndOfStream is always
				 * CVI_FALSE on the H.264 path, so we never raise it
				 * either, raising it makes the decoder flush and stall.
				 */
				if (win_len == 0) {	/* wrap: loop the file */
					used = 0;
					win_base = 0;
					fseek(fp, 0, SEEK_SET);
					win_len = (CVI_S32)fread(buf, 1, bufsize, fp);
					if (win_len == 0)
						break;
				}
			}
			p  = buf + off;
			rd = win_len - (CVI_S32)off;
		}

		/* find one access unit: [start .. next start) */
		for (i = 0; i < rd - 8; i++) {
			int t = p[i + 3] & 0x1F;

			if (p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1 &&
			    (((t == 0x5 || t == 0x1) && ((p[i + 4] & 0x80) == 0x80)) ||
			     (t == 20 && (p[i + 7] & 0x80) == 0x80))) {
				found_start = CVI_TRUE;
				i += 8;
				break;
			}
		}
		for (; i < rd - 8; i++) {
			int t = p[i + 3] & 0x1F;

			if (p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1 &&
			    (t == 15 || t == 7 || t == 8 || t == 6 ||
			     ((t == 5 || t == 1) && ((p[i + 4] & 0x80) == 0x80)) ||
			     (t == 20 && (p[i + 7] & 0x80) == 0x80))) {
				found_end = CVI_TRUE;
				break;
			}
		}
		if (i > 0)
			rd = i;
		if (!found_end)
			rd = i + 8;
		(void)found_start;

		stream.u64PTS       = pts;
		stream.pu8Addr      = p;
		stream.u32Len       = rd;
		stream.bEndOfFrame  = CVI_TRUE;
		stream.bEndOfStream = CVI_FALSE;
		stream.bDisplay     = 1;

		/*
		 * Soft rate-lock to VO: prefer to wait for it to retire a frame,
		 * but never block indefinitely, proceed after the short timeout
		 * inside credit_take() and let the g_fps timer pace us instead.
		 *
		 * A hard gate deadlocks. An H.264 decoder needs many access units
		 * before it emits its first frame, so at startup there are no
		 * credits and none can ever appear: the feeder waits on a frame
		 * that cannot be decoded because the feeder is waiting. Measured
		 * exactly that, DispPts frozen at 670 for three minutes with the
		 * watchdog firing 62 times and never recovering (2026-09-20).
		 *
		 * As an advisory brake it still does its job: when VO falls
		 * behind, credits drain and each access unit costs a timeout, so
		 * the feed rate drops and the pool stops being over-filled.
		 *
		 * What makes the brake meaningful is that the pump retries a
		 * refused frame instead of dropping it (see CVI_VO_SendFrame
		 * there). Once VO's queue is full, admissions happen at the rate
		 * VO drains, so a credit now marks real display progress rather
		 * than free space in the queue, and this loop tracks the panel
		 * instead of free-running at g_fps.
		 */
		(void)credit_take();
		if (g_feeder_stop)
			goto out;

		for (;;) {
			ret = CVI_VDEC_SendStream(chn, &stream, -1);
			if (ret == CVI_SUCCESS)
				break;
			if (g_feeder_stop)
				goto out;
			usleep(10000);
		}

		used += rd;
		pts++;
		g_fed++;			/* watchdog liveness */
		if ((++frames % 1800) == 0)	/* ~30s at 60fps */
			printf("[badge_landscape_vo] fed %llu frames\n", frames);

		/*
		 * Pace the input. Absolute CLOCK_MONOTONIC deadlines rather than
		 * a relative sleep, so the decode time of each frame does not
		 * accumulate into drift. Without this the decoder outruns VO and
		 * the pipeline deadlocks, see g_fps.
		 */
		if (g_fps > 0) {
			struct timespec now;
			long long behind_ns;
			/*
			 * Track the panel instead of trusting g_fps.
			 *
			 * g_fps is 60.000 by definition; the DISP is not. The
			 * difference never self-corrects, so the queue trends in
			 * one direction until it is pinned at one end: measured
			 * as ~90 "vo_sdk_send_frame NG" per second in bursts,
			 * i.e. most frames refused once and accepted on retry.
			 * Nothing is dropped, the retry covers it, but there
			 * is no headroom left for a real hiccup.
			 *
			 * VO already reports which way we are wrong: a refused
			 * SendFrame means the queue is full, which means we are
			 * feeding faster than it drains. So integrate that. Each
			 * refusal stretches the frame period slightly; a clean
			 * stretch relaxes it back toward nominal. The result
			 * settles at whatever the panel's true rate is, without
			 * anyone having to know it.
			 *
			 * Deliberately slow and tightly clamped: +/-1% of nominal
			 * is far more than any real panel deviates (59.94 vs
			 * 60.00 is 0.1%), and a 1/4096 step means it takes
			 * thousands of frames to traverse the range, so it cannot
			 * oscillate visibly. If the clamp is ever hit, the fault
			 * is elsewhere and this will not mask it.
			 */
			static long trim_ns;		/* added to each period */
			static unsigned long long last_sf;
			const long nominal_ns = 1000000000L / g_fps;
			const long trim_max   = nominal_ns / 100;
			const long trim_step  = nominal_ns / 4096 + 1;
			unsigned long long sf = g_pump_send_fail;
			long frame_ns;

			if (sf != last_sf) {
				last_sf = sf;		/* we are ahead: ease off */
				if (trim_ns < trim_max)
					trim_ns += trim_step;
			} else if (trim_ns > 0) {
				trim_ns -= trim_step;	/* clean: drift back */
				if (trim_ns < 0)
					trim_ns = 0;
			}
			frame_ns = nominal_ns + trim_ns;

			next.tv_nsec += frame_ns;
			while (next.tv_nsec >= 1000000000L) {
				next.tv_nsec -= 1000000000L;
				next.tv_sec++;
			}

			/*
			 * Never try to make up lost time.
			 *
			 * An absolute deadline that has fallen into the past makes
			 * clock_nanosleep return immediately, so after any hiccup
			 * a credit timeout, SendStream backpressure, a watchdog
			 * reset, this loop stops pacing altogether and runs flat
			 * out until the backlog is repaid. That burst is what
			 * floods the decoder and then VO, and it shows up as a
			 * cluster of
			 *
			 *   vo_sdk_send_frame NG, No buffer space available
			 *   vb_qbuf: VO waitq is full. drop new one.
			 *
			 * all inside the same second, with quiet either side.
			 * Catching up is never what we want here: the frames are
			 * already late, and delivering them faster than the panel
			 * can retire them just drops them instead.
			 *
			 * So if the deadline has slipped more than two frames,
			 * abandon the backlog and re-base on now.
			 */
			clock_gettime(CLOCK_MONOTONIC, &now);
			behind_ns = (long long)(now.tv_sec - next.tv_sec) * 1000000000LL
				  + (long long)(now.tv_nsec - next.tv_nsec);
			if (behind_ns > 2LL * frame_ns) {
				next = now;
				next.tv_nsec += frame_ns;
				while (next.tv_nsec >= 1000000000L) {
					next.tv_nsec -= 1000000000L;
					next.tv_sec++;
				}
			}

			clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next, NULL);
		}
	}
out:
	free(buf);
	fclose(fp);
	printf("[badge_landscape_vo] feeder exit after %llu frames\n", frames);
	return NULL;
}

/* VDEC -> VO pump */

/*
 * Modelled on thread_send_vo() in the vendor sample_vdecvo.c, minus the VPSS
 * overlay stage: one channel at the panel's own geometry needs no compositor,
 * and VDEC's output format (NV21) already matches the VO channel's.
 *
 * Ordering is the vendor's and it matters: ReleaseFrame comes *after*
 * the frame has been handed to its consumer, never before.  CVI_VO_SendFrame
 * is synchronous with respect to the source buffer.
 *
 * Note what CVI_VDEC_GetFrame's s32MilliSec actually does: it does not wait
 * for a frame.  It only bounds the display-queue mutex acquisition
 * (cvi_vc_drv/module/src/cvi_vdec.c:1916).  With an empty queue the call
 * returns CVI_ERR_VDEC_ERR_INVALID_RET immediately, whatever the timeout.
 * So "no frame yet" arrives here as a failure return, and the usleep() in
 * that branch, not the timeout, is what paces this loop.  The finite
 * value is still worth passing so a contended mutex cannot park the thread
 * past g_pump_stop.
 */
static void *pump_thread(void *arg)
{
	VDEC_CHN chn = (VDEC_CHN)(uintptr_t)arg;
	CVI_S32 last_get_err = 0, last_send_err = 0, last_rel_err = 0;

	prctl(PR_SET_NAME, "vdec_pump");

	printf("[badge_landscape_vo] pump: VDEC %d -> VO layer %d chn %d\n",
	       (int)chn, VO_LAYER_ID, VO_CHN_ID);

	/* One frame of release lag; see the release site below. */
	VIDEO_FRAME_INFO_S prev;
	unsigned prev_gen = 0;
	int have_prev = 0;

	while (!g_pump_stop) {
		VIDEO_FRAME_INFO_S frame;
		CVI_S32 ret;
		unsigned gen;

		memset(&frame, 0, sizeof(frame));

		/* Sampled before GetFrame and re-checked after SendFrame's
		 * neighbours, so a decoder reset landing mid-iteration is
		 * detected rather than handed on. See g_vdec_gen. */
		gen = g_vdec_gen;

		ret = CVI_VDEC_GetFrame(chn, &frame, 500);
		if (ret != CVI_SUCCESS) {
			/*
			 * An empty display queue is the steady state between
			 * frames, not a fault, GetFrame does not wait, so it
			 * reports "nothing ready" as a return code.  Counting
			 * those as failures would bury the real errors under
			 * hundreds per second.
			 */
			if (ret == CVI_ERR_VDEC_ERR_INVALID_RET ||
			    ret == CVI_ERR_VDEC_BUF_EMPTY ||
			    ret == CVI_ERR_VDEC_BUSY) {
				g_pump_idle++;
			} else {
				g_pump_get_fail++;
				if (ret != last_get_err) {
					fprintf(stderr, "[badge_landscape_vo] pump:"
						" CVI_VDEC_GetFrame -> %#x\n",
						(unsigned)ret);
					last_get_err = ret;
				}
			}
			usleep(2000);
			continue;
		}
		last_get_err = 0;
		g_pump_got++;

		/*
		 * If the channel was reset while we were fetching, this frame is
		 * from the old generation: VDEC no longer tracks it and its
		 * contents are stale. Drop it without touching VO or VDEC,
		 * sending it logs "PixelFormat(0) mismatch" and releasing it
		 * logs "Can't find video frame in VideoFrameArray". One dropped
		 * frame at a reset boundary is invisible; those two are not.
		 */
		if (gen != g_vdec_gen) {
			g_pump_stale++;
			continue;
		}

		/*
		 * Hand the frame to VO, and retry rather than drop it when the
		 * queue is full. This is the backpressure the whole pipeline
		 * paces against, so it is worth being precise about why.
		 *
		 * CVI_VO_SendFrame returning success means the frame was queued,
		 * not displayed, the vendor call admits to the waitq and
		 * returns. So while that queue has room every call succeeds
		 * immediately, and if a success is treated as "VO retired one"
		 * the feeder is being told it may send another when nothing has
		 * actually been shown yet. It sprints, the waitq fills, and VO
		 * starts refusing frames:
		 *
		 *   VO_IOC_S_CTRL - vo_sdk_send_frame NG, No buffer space available
		 *   vb_qbuf:715(): VO waitq is full. drop new one.
		 *
		 * Dropping there is invisible on a still, every discarded frame
		 * is identical to its neighbours, which is why 49 slides looked
		 * clean and 219 seconds of Bad Apple stuttered. The feed rate and
		 * the panel rate only have to disagree very slightly for this to
		 * accumulate, and a free-running 60.000 fps feeder will always
		 * disagree with the real pixel clock eventually.
		 *
		 * Retrying closes the loop. Once the queue is full, admissions
		 * happen at exactly the rate VO drains it, so credits (posted
		 * below) now measure real display progress instead of queue
		 * space, and the feeder self-paces to the panel. VDEC's own
		 * buffers then back up behind the blocked pump and SendStream
		 * stalls the feeder end to end, which is what we want.
		 *
		 * Keep the retry short. Every refused call makes the kernel log
		 * another "vb_qbuf: VO waitq is full. drop new one.", so a long
		 * tight retry turns one dropped frame into a hundred log lines
		 * and buries anything useful in dmesg. Retrying at all is only a
		 * safety net for a transient; the credit gate above is what is
		 * supposed to keep the queue from filling, and if this loop is
		 * running hot that is the thing to fix, not this timeout.
		 *
		 * Four tries at 4 ms is ~16 ms, about one frame time at 60 fps.
		 */
		{
			int tries = 0;

			for (;;) {
				ret = CVI_VO_SendFrame(VO_LAYER_ID, VO_CHN_ID,
						       &frame, 1000);
				if (ret == CVI_SUCCESS || g_feeder_stop)
					break;
				if (++tries >= 4)
					break;
				usleep(4000);
			}
		}
		if (ret != CVI_SUCCESS) {
			g_pump_send_fail++;
			if (ret != last_send_err) {
				fprintf(stderr, "[badge_landscape_vo] pump:"
					" CVI_VO_SendFrame -> %#x\n", (unsigned)ret);
				last_send_err = ret;
			}
		} else {
			last_send_err = 0;
			g_pump_sent++;
			credit_post();		/* VO took one: the feeder may send one */
		}

		/*
		 * Hold a successfully sent frame for one more iteration before
		 * giving it back to the decoder.
		 *
		 * CVI_VO_SendFrame only queues; VO scans the buffer out later. If
		 * the frame is released immediately, VDEC may decode the next
		 * picture straight into memory that is still on screen, so part of
		 * a newer frame appears over an older one, which reads as a tear
		 * rather than as corruption, and is worst when the queue is deep.
		 *
		 * One frame of lag is the conservative choice. VDEC_FRAME_BUF_CNT
		 * is 4, so holding one still leaves three for the decoder to work
		 * in; holding the queue's full depth would starve it.
		 *
		 * A frame from a previous decoder generation must not be released
		 * VDEC no longer tracks it and the call logs "Can't find video
		 * frame in VideoFrameArray", so the generation is held alongside
		 * it and checked here.
		 */
		if (ret == CVI_SUCCESS) {
			VIDEO_FRAME_INFO_S to_release;
			int release_it = 0;

			if (have_prev) {
				if (prev_gen == g_vdec_gen) {
					to_release = prev;
					release_it = 1;
				} else {
					g_pump_stale++;
				}
			}
			prev      = frame;
			prev_gen  = gen;
			have_prev = 1;

			if (!release_it)
				continue;
			frame = to_release;
		}

		ret = CVI_VDEC_ReleaseFrame(chn, &frame);
		if (ret != CVI_SUCCESS) {
			g_pump_rel_fail++;
			if (ret != last_rel_err) {
				fprintf(stderr, "[badge_landscape_vo] pump:"
					" CVI_VDEC_ReleaseFrame -> %#x\n", (unsigned)ret);
				last_rel_err = ret;
			}
		} else {
			last_rel_err = 0;
			g_pump_rel++;
		}

		if ((g_pump_got % 300) == 0)
			printf("[badge_landscape_vo] pump: got %llu sent %llu"
			       " released %llu idle %llu stale %llu"
			       " (fail get/send/rel %llu/%llu/%llu)\n",
			       g_pump_got, g_pump_sent, g_pump_rel, g_pump_idle,
			       g_pump_stale,
			       g_pump_get_fail, g_pump_send_fail, g_pump_rel_fail);
	}

	/* Give back the frame held for release lag, or the decoder loses a
	 * buffer out of a pool of four every time the pump is restarted. */
	if (have_prev && prev_gen == g_vdec_gen)
		WARN(CVI_VDEC_ReleaseFrame(chn, &prev));

	printf("[badge_landscape_vo] pump exit: got %llu sent %llu released %llu"
	       " idle %llu stale %llu (fail get/send/rel %llu/%llu/%llu)\n",
	       g_pump_got, g_pump_sent, g_pump_rel, g_pump_idle, g_pump_stale,
	       g_pump_get_fail, g_pump_send_fail, g_pump_rel_fail);
	return NULL;
}

/* setup */

static void sys_up(void)
{
	VB_CONFIG_S vb;
	CVI_U32 blk;

	memset(&vb, 0, sizeof(vb));
	vb.u32MaxPoolCnt = 1;
	blk = COMMON_GetPicBufferSize(ALIGN(g_width, H264D_ALIGN_W),
				      ALIGN(g_height, H264D_ALIGN_H),
				      VO_PIX_FMT, DATA_BITWIDTH_8,
				      COMPRESS_MODE_NONE, DEFAULT_ALIGN);
	vb.astCommPool[0].u32BlkSize   = blk;
	vb.astCommPool[0].u32BlkCnt    = COMMON_POOL_BLK_CNT;
	vb.astCommPool[0].enRemapMode  = VB_REMAP_MODE_NONE;

	printf("[badge_landscape_vo] VB common pool: blksize=%u cnt=%u\n",
	       blk, (unsigned)COMMON_POOL_BLK_CNT);

	CVI_SYS_Exit();
	CVI_VB_Exit();

	if (CVI_VB_IsInited() == CVI_TRUE)
		fprintf(stderr, "[badge_landscape_vo] WARN: VB is ALREADY inited"
			" (a previous run left it up); CVI_VB_SetConfig will have"
			" no effect -- reboot for a clean pool\n");

	SOFT(CVI_VB_SetConfig(&vb));
	SOFT(CVI_VB_Init());
	SOFT(CVI_SYS_Init());
	st_sys_up = 1;
}

static void vo_up(void)
{
	VO_PUB_ATTR_S pub;
	VO_VIDEO_LAYER_ATTR_S layer;
	VO_CHN_ATTR_S chn;

	memset(&pub, 0, sizeof(pub));
	pub.u32BgColor  = VO_BG_COLOR;		/* COLOR_10_RGB_BLUE, as the vendor */
	pub.enIntfType  = VO_INTF;
	pub.enIntfSync  = VO_SYNC;		/* <-- landscape 1280x720@60 */

	SOFT(CVI_VO_SetPubAttr(VO_DEV_ID, &pub));
	SOFT(CVI_VO_Enable(VO_DEV_ID));
	st_vo_dev = 1;

	SOFT(CVI_VO_SetDisplayBufLen(VO_LAYER_ID, VO_DISP_BUF_LEN));

	memset(&layer, 0, sizeof(layer));
	layer.stDispRect.s32X        = 0;
	layer.stDispRect.s32Y        = 0;
	layer.stDispRect.u32Width    = g_width;
	layer.stDispRect.u32Height   = g_height;
	layer.stImageSize.u32Width   = g_width;
	layer.stImageSize.u32Height  = g_height;
	layer.u32DispFrmRt           = 60;
	layer.enPixFormat            = VO_PIX_FMT;

	SOFT(CVI_VO_SetVideoLayerAttr(VO_LAYER_ID, &layer));
	SOFT(CVI_VO_EnableVideoLayer(VO_LAYER_ID));
	st_vo_layer = 1;

	memset(&chn, 0, sizeof(chn));
	chn.u32Priority       = 0;
	chn.stRect.s32X       = 0;
	chn.stRect.s32Y       = 0;
	chn.stRect.u32Width   = g_width;
	chn.stRect.u32Height  = g_height;

	SOFT(CVI_VO_SetChnAttr(VO_LAYER_ID, VO_CHN_ID, &chn));
	SOFT(CVI_VO_EnableChn(VO_LAYER_ID, VO_CHN_ID));
	st_vo_chn = 1;

	/* explicit: the vendor sample sets ROTATION_90 here */
	SOFT(CVI_VO_SetChnRotation(VO_LAYER_ID, VO_CHN_ID, ROTATION_0));
}

static void vdec_up(void)
{
	VDEC_MOD_PARAM_S mod;
	VDEC_CHN_ATTR_S attr;
	VDEC_CHN_PARAM_S param;
	VDEC_CHN_POOL_S pool;
	VB_POOL_CONFIG_S pcfg;
	CVI_U32 blk;
	CVI_S32 ret;

	/*
	 * The mod param is advisory.  On this firmware CVI_VDEC_GetModParam
	 * returns CVI_FAILURE (0xffffffff); the stock sample_vdecvo ignores its
	 * return value entirely and pushes a stack-garbage struct with only
	 * enVdecVBSource set, and still works.  We do the same, but from a
	 * zeroed struct so the result is deterministic.
	 */
	memset(&mod, 0, sizeof(mod));
	SOFT(CVI_VDEC_GetModParam(&mod));
	mod.enVdecVBSource = VB_SOURCE_USER;
	SOFT(CVI_VDEC_SetModParam(&mod));

	memset(&pcfg, 0, sizeof(pcfg));
	blk = VDEC_GetPicBufferSize(PT_H264, g_width, g_height,
				    PIXEL_FORMAT_YUV_PLANAR_420,
				    DATA_BITWIDTH_8, COMPRESS_MODE_NONE);
	pcfg.u32BlkSize   = blk;
	pcfg.u32BlkCnt    = VDEC_POOL_BLK_CNT;
	pcfg.enRemapMode  = VB_REMAP_MODE_NONE;

	g_pic_pool = CVI_VB_CreatePool(&pcfg);
	if (g_pic_pool == VB_INVALID_POOLID) {
		g_setup_fails++;
		fprintf(stderr, "[badge_landscape_vo] WARN: CVI_VB_CreatePool failed"
			" -- falling back to the common pool\n");
	} else {
		printf("[badge_landscape_vo] VDEC pic pool: id=%u blksize=%u cnt=%u\n",
		       (unsigned)g_pic_pool, blk, (unsigned)VDEC_POOL_BLK_CNT);
	}

	memset(&attr, 0, sizeof(attr));
	attr.enType            = PT_H264;
	attr.enMode            = VIDEO_MODE_FRAME;
	attr.u32PicWidth       = g_width;
	attr.u32PicHeight      = g_height;
	attr.u32StreamBufSize  = g_width * g_height;
	attr.u32FrameBufCnt    = VDEC_FRAME_BUF_CNT;

	ret = CVI_VDEC_CreateChn(VDEC_CHN_ID, &attr);
	if (ret != CVI_SUCCESS) {
		g_setup_fails++;
		fprintf(stderr, "[badge_landscape_vo] WARN: CVI_VDEC_CreateChn -> %#x"
			" -- no decode channel, the feeder will not be started\n",
			(unsigned)ret);
		return;
	}
	st_vdec_chn = 1;

	/* passing VB_INVALID_POOLID here would be actively wrong, so guard it */
	if (g_pic_pool != VB_INVALID_POOLID) {
		pool.hPicVbPool = g_pic_pool;
		pool.hTmvVbPool = VB_INVALID_POOLID;
		SOFT(CVI_VDEC_AttachVbPool(VDEC_CHN_ID, &pool));
		st_attached = 1;
	}

	memset(&param, 0, sizeof(param));
	SOFT(CVI_VDEC_GetChnParam(VDEC_CHN_ID, &param));
	param.enPixelFormat       = PIXEL_FORMAT_NV21;
	param.u32DisplayFrameNum  = VDEC_DISPLAY_FRAME_NUM;
	SOFT(CVI_VDEC_SetChnParam(VDEC_CHN_ID, &param));

	SOFT(CVI_VDEC_StartRecvStream(VDEC_CHN_ID));
}

static void bind_up(void)
{
	MMF_CHN_S src, dst;

	if (!st_vdec_chn || !g_do_bind)
		return;

	src.enModId = CVI_ID_VDEC;
	src.s32DevId = 0;
	src.s32ChnId = VDEC_CHN_ID;
	dst.enModId = CVI_ID_VO;
	dst.s32DevId = VO_LAYER_ID;
	dst.s32ChnId = VO_CHN_ID;

	SOFT(CVI_SYS_Bind(&src, &dst));
	st_bound = 1;
}

/* readback / reporting */

static const char *pixfmt_name(PIXEL_FORMAT_E f)
{
	switch (f) {
	case PIXEL_FORMAT_NV12:			return "NV12";
	case PIXEL_FORMAT_NV21:			return "NV21";
	case PIXEL_FORMAT_YUV_PLANAR_420:	return "YUV_PLANAR_420";
	case PIXEL_FORMAT_YUV_PLANAR_422:	return "YUV_PLANAR_422";
	case PIXEL_FORMAT_YUV_PLANAR_444:	return "YUV_PLANAR_444";
	default:				return "?";
	}
}

static void report(void)
{
	VO_PUB_ATTR_S pub;
	VO_VIDEO_LAYER_ATTR_S layer;
	VO_CHN_ATTR_S chn;
	ROTATION_E rot = ROTATION_MAX;
	VDEC_CHN_ATTR_S vattr;
	VDEC_CHN_PARAM_S vparam;
	VB_CONFIG_S vbcfg;

	printf("\n===== applied configuration (read back from the driver) =====\n");

	memset(&vbcfg, 0, sizeof(vbcfg));
	if (CVI_VB_GetConfig(&vbcfg) == CVI_SUCCESS)
		printf("VB : inited=%d  poolcnt=%u  pool0 blksize=%u cnt=%u\n",
		       (int)CVI_VB_IsInited(), (unsigned)vbcfg.u32MaxPoolCnt,
		       (unsigned)vbcfg.astCommPool[0].u32BlkSize,
		       (unsigned)vbcfg.astCommPool[0].u32BlkCnt);
	else
		printf("VB : CVI_VB_GetConfig failed\n");

	memset(&pub, 0, sizeof(pub));
	if (CVI_VO_GetPubAttr(VO_DEV_ID, &pub) == CVI_SUCCESS)
		printf("VO dev %d : enIntfType=0x%x (VO_INTF_MIPI=0x%x)  enIntfSync=%d"
		       "  (VO_OUTPUT_720P60=%d, vendor portrait VO_OUTPUT_720x1280_60=%d)"
		       "  bg=0x%08x\n",
		       VO_DEV_ID, (unsigned)pub.enIntfType, (unsigned)VO_INTF_MIPI,
		       (int)pub.enIntfSync, (int)VO_OUTPUT_720P60,
		       (int)VO_OUTPUT_720x1280_60, (unsigned)pub.u32BgColor);
	else
		printf("VO dev %d : CVI_VO_GetPubAttr failed\n", VO_DEV_ID);

	memset(&layer, 0, sizeof(layer));
	if (CVI_VO_GetVideoLayerAttr(VO_LAYER_ID, &layer) == CVI_SUCCESS)
		printf("VO layer %d : disp rect %dx%d @ (%d,%d)  image %ux%u  fps=%u  pixfmt=%d (%s)\n",
		       VO_LAYER_ID, (int)layer.stDispRect.u32Width,
		       (int)layer.stDispRect.u32Height, (int)layer.stDispRect.s32X,
		       (int)layer.stDispRect.s32Y, (unsigned)layer.stImageSize.u32Width,
		       (unsigned)layer.stImageSize.u32Height, (unsigned)layer.u32DispFrmRt,
		       (int)layer.enPixFormat, pixfmt_name(layer.enPixFormat));
	else
		printf("VO layer %d : CVI_VO_GetVideoLayerAttr failed\n", VO_LAYER_ID);

	memset(&chn, 0, sizeof(chn));
	if (CVI_VO_GetChnAttr(VO_LAYER_ID, VO_CHN_ID, &chn) == CVI_SUCCESS)
		printf("VO chn %d : rect %ux%u @ (%d,%d)  prio=%u\n",
		       VO_CHN_ID, (unsigned)chn.stRect.u32Width,
		       (unsigned)chn.stRect.u32Height, (int)chn.stRect.s32X,
		       (int)chn.stRect.s32Y, (unsigned)chn.u32Priority);
	else
		printf("VO chn %d : CVI_VO_GetChnAttr failed\n", VO_CHN_ID);

	if (CVI_VO_GetChnRotation(VO_LAYER_ID, VO_CHN_ID, &rot) == CVI_SUCCESS)
		printf("VO chn %d : rotation=%d (ROTATION_0=%d, vendor used ROTATION_90=%d)\n",
		       VO_CHN_ID, (int)rot, (int)ROTATION_0, (int)ROTATION_90);
	else
		printf("VO chn %d : CVI_VO_GetChnRotation failed\n", VO_CHN_ID);

	memset(&vattr, 0, sizeof(vattr));
	if (CVI_VDEC_GetChnAttr(VDEC_CHN_ID, &vattr) == CVI_SUCCESS)
		printf("VDEC chn %d : type=%d (PT_H264=%d) mode=%d pic %ux%u streambuf=%u framebufcnt=%u\n",
		       VDEC_CHN_ID, (int)vattr.enType, (int)PT_H264, (int)vattr.enMode,
		       (unsigned)vattr.u32PicWidth, (unsigned)vattr.u32PicHeight,
		       (unsigned)vattr.u32StreamBufSize, (unsigned)vattr.u32FrameBufCnt);
	else
		printf("VDEC chn %d : CVI_VDEC_GetChnAttr failed\n", VDEC_CHN_ID);

	memset(&vparam, 0, sizeof(vparam));
	if (CVI_VDEC_GetChnParam(VDEC_CHN_ID, &vparam) == CVI_SUCCESS)
		printf("VDEC chn %d : outfmt=%d (%s) displayframenum=%u\n",
		       VDEC_CHN_ID, (int)vparam.enPixelFormat,
		       pixfmt_name(vparam.enPixelFormat),
		       (unsigned)vparam.u32DisplayFrameNum);
	else
		printf("VDEC chn %d : CVI_VDEC_GetChnParam failed\n", VDEC_CHN_ID);

	printf("VDEC -> VO : %s%s\n",
	       g_do_pump ? "userspace pump (GetFrame/SendFrame/ReleaseFrame)"
			 : "NO PUMP",
	       st_bound ? " + CVI_SYS_Bind (debug)" : "");
	printf("setup: %u call(s) failed and were skipped over\n", g_setup_fails);
	printf("=============================================================\n\n");
}

/* teardown */

static void teardown(void)
{
	MMF_CHN_S src, dst;

	/* Stop the watchdog before the feeder, so it cannot mistake an orderly
	 * shutdown for a stall and reset the channel on the way out. */
	if (g_wdog) {
		g_wdog_stop = 1;
		pthread_join(g_wdog, NULL);
		g_wdog = 0;
	}

	if (g_feeder) {
		g_feeder_stop = 1;
		pthread_join(g_feeder, NULL);
		g_feeder = 0;
	}

	/* the pump holds VDEC frames; it must be gone before the channel is */
	if (g_pump) {
		g_pump_stop = 1;
		pthread_join(g_pump, NULL);
		g_pump = 0;
	}

	if (st_bound) {
		src.enModId = CVI_ID_VDEC;
		src.s32DevId = 0;
		src.s32ChnId = VDEC_CHN_ID;
		dst.enModId = CVI_ID_VO;
		dst.s32DevId = VO_LAYER_ID;
		dst.s32ChnId = VO_CHN_ID;
		WARN(CVI_SYS_UnBind(&src, &dst));
		st_bound = 0;
	}

	if (st_vdec_chn) {
		WARN(CVI_VDEC_StopRecvStream(VDEC_CHN_ID));
		if (st_attached) {
			WARN(CVI_VDEC_DetachVbPool(VDEC_CHN_ID));
			st_attached = 0;
		}
		WARN(CVI_VDEC_ResetChn(VDEC_CHN_ID));
		WARN(CVI_VDEC_DestroyChn(VDEC_CHN_ID));
		st_vdec_chn = 0;
	}

	if (st_vo_chn) {
		WARN(CVI_VO_DisableChn(VO_LAYER_ID, VO_CHN_ID));
		st_vo_chn = 0;
	}
	if (st_vo_layer) {
		WARN(CVI_VO_DisableVideoLayer(VO_LAYER_ID));
		st_vo_layer = 0;
	}
	if (st_vo_dev) {
		WARN(CVI_VO_Disable(VO_DEV_ID));
		st_vo_dev = 0;
	}

	if (g_pic_pool != VB_INVALID_POOLID) {
		WARN(CVI_VB_DestroyPool(g_pic_pool));
		g_pic_pool = VB_INVALID_POOLID;
	}

	if (st_sys_up) {
		CVI_SYS_Exit();
		CVI_VB_Exit();
		st_sys_up = 0;
	}

	printf("[badge_landscape_vo] clean shutdown done\n");
	fflush(stdout);
}

static void on_signal(int sig)
{
	int saved = errno;
	char b = (char)sig;

	g_quit = 1;
	if (g_sigpipe[1] >= 0) {
		ssize_t n = write(g_sigpipe[1], &b, 1);	/* async-signal-safe */
		(void)n;
	}
	errno = saved;
}

/*
 * Wait for the stop condition.  poll()s the self-pipe (signals) and, when it is
 * useful, stdin.  No busy-poll, no signal race, and a non-tty stdin at EOF is
 * simply dropped from the poll set instead of ending the run.
 */
static void wait_for_stop(void)
{
	int stdin_is_tty = isatty(STDIN_FILENO);
	int watch_stdin = 1;
	unsigned long junk = 0;

	if (stdin_is_tty)
		printf("[badge_landscape_vo] running -- press Enter to stop"
		       " (SIGINT/SIGTERM also stop cleanly).\n");
	else
		printf("[badge_landscape_vo] running -- stdin is not a terminal;"
		       " stop with a newline on stdin, or SIGINT/SIGTERM"
		       " (e.g. systemctl stop).\n");
	fflush(stdout);

	while (1) {
		struct pollfd pfd[2];
		nfds_t n = 0;

		if (g_quit) {
			printf("[badge_landscape_vo] signal received -- stopping\n");
			return;
		}
		int sig_idx, in_idx = -1;
		int r;

		sig_idx = (int)n;
		pfd[n].fd = g_sigpipe[0];
		pfd[n].events = POLLIN;
		n++;

		if (watch_stdin) {
			in_idx = (int)n;
			pfd[n].fd = STDIN_FILENO;
			pfd[n].events = POLLIN;
			n++;
		}

		r = poll(pfd, n, -1);
		if (r < 0) {
			if (errno == EINTR)
				continue;
			fprintf(stderr, "[badge_landscape_vo] poll: %s\n",
				strerror(errno));
			return;
		}

		if (pfd[sig_idx].revents & POLLIN) {
			printf("[badge_landscape_vo] signal received -- stopping\n");
			return;
		}

		if (in_idx >= 0 && (pfd[in_idx].revents & (POLLIN | POLLHUP | POLLERR))) {
			char b[256];
			ssize_t got = read(STDIN_FILENO, b, sizeof(b));

			if (got > 0) {
				if (memchr(b, '\n', (size_t)got)) {
					printf("[badge_landscape_vo] newline on stdin"
					       " -- stopping\n");
					return;
				}
				junk += (unsigned long)got;
				if (!stdin_is_tty && junk > STDIN_JUNK_LIMIT) {
					fprintf(stderr, "[badge_landscape_vo] stdin:"
						" %lu bytes, no newline, not a tty"
						" -- ignoring stdin from now on;"
						" stop with SIGINT/SIGTERM\n", junk);
					watch_stdin = 0;
				}
				continue;
			}

			if (got == 0) {			/* EOF */
				if (stdin_is_tty) {
					printf("[badge_landscape_vo] stdin EOF on a"
					       " terminal -- stopping\n");
					return;
				}
				fprintf(stderr, "[badge_landscape_vo] stdin is at EOF"
					" and is not a terminal -- ignoring it;"
					" stop with SIGINT/SIGTERM\n");
				watch_stdin = 0;
				continue;
			}

			if (errno == EINTR || errno == EAGAIN)
				continue;
			fprintf(stderr, "[badge_landscape_vo] stdin read: %s"
				" -- ignoring stdin from now on\n", strerror(errno));
			watch_stdin = 0;
		}
	}
}

/* main */

static void usage(const char *p)
{
	fprintf(stderr,
		"usage: %s <stream.264> [WIDTHxHEIGHT]\n"
		"\n"
		"  stream.264    H.264 Annex-B elementary stream (looped)\n"
		"  WIDTHxHEIGHT  default %dx%d (landscape)\n"
		"\n"
		"Stop with a newline on stdin, or SIGINT/SIGTERM (so `systemctl stop`\n"
		"is a clean stop).  NEVER kill -9: the vendor stack leaks its VB pool.\n",
		p, DEF_WIDTH, DEF_HEIGHT);
}

int main(int argc, char **argv)
{
	struct sigaction sa;

	setvbuf(stdout, NULL, _IOLBF, 0);	/* keep logs live through a pipe */
	setvbuf(stderr, NULL, _IONBF, 0);

	/*
	 * --selftest-stdin exercises the stop logic only.  It opens no device,
	 * loads no vendor module and touches no hardware, so it is safe to run
	 * anywhere (including under qemu-user on a build host).
	 */
	if (argc >= 2 && !strcmp(argv[1], "--selftest-stdin")) {
		if (pipe(g_sigpipe) != 0) {
			fprintf(stderr, "pipe: %s\n", strerror(errno));
			return 1;
		}
		fcntl(g_sigpipe[0], F_SETFL, O_NONBLOCK);
		fcntl(g_sigpipe[1], F_SETFL, O_NONBLOCK);
		memset(&sa, 0, sizeof(sa));
		sa.sa_handler = on_signal;
		sigaction(SIGINT, &sa, NULL);
		sigaction(SIGTERM, &sa, NULL);
		signal(SIGPIPE, SIG_IGN);
		printf("[badge_landscape_vo] SELFTEST: stop logic only, no hardware\n");
		wait_for_stop();
		printf("[badge_landscape_vo] SELFTEST: returned\n");
		return 0;
	}

	if (argc < 2) {
		usage(argv[0]);
		return 1;
	}
	/*
	 * argv[1..] is the playlist. A trailing WIDTHxHEIGHT is geometry rather
	 * than a clip, which keeps the original `blvo <stream.264> [WxH]` form
	 * working unchanged while allowing `blvo a.264 b.264 c.264 [WxH]`.
	 */
	{
		int n = argc - 1;
		unsigned w, h;

		if (n >= 2 && sscanf(argv[argc - 1], "%ux%u", &w, &h) == 2 && w && h) {
			g_width = w;
			g_height = h;
			n--;
		}
		g_playlist = &argv[1];
		g_playlist_n = n;
		g_playlist_i = 0;
		g_stream_path = argv[1];
	}

	/* SIGUSR1/2 change track without disturbing the display. */
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_switch;
	sigaction(SIGUSR1, &sa, NULL);
	sigaction(SIGUSR2, &sa, NULL);

	if (access(g_stream_path, R_OK) != 0) {
		fprintf(stderr, "[badge_landscape_vo] %s: %s\n",
			g_stream_path, strerror(errno));
		return 1;
	}

	if (pipe(g_sigpipe) != 0) {
		fprintf(stderr, "[badge_landscape_vo] pipe: %s\n", strerror(errno));
		return 1;
	}
	fcntl(g_sigpipe[0], F_SETFL, O_NONBLOCK);
	fcntl(g_sigpipe[1], F_SETFL, O_NONBLOCK);

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_signal;		/* no SA_RESTART: break poll() */
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);
	signal(SIGPIPE, SIG_IGN);

	printf("[badge_landscape_vo] target: %ux%u  enIntfSync=%d (VO_OUTPUT_720P60)"
	       "  rotation=%d (ROTATION_0)  intf=0x%x (VO_INTF_MIPI)\n",
	       (unsigned)g_width, (unsigned)g_height, (int)VO_SYNC,
	       (int)ROTATION_0, (unsigned)VO_INTF);

	/*
	 * The bind is off by default because it does nothing on this stack
	 * (see pump_thread above); BLVO_BIND=1 re-enables it for comparison,
	 * BLVO_PUMP=0 disables the pump to reproduce the hang.
	 */
	if (getenv("BLVO_FPS")) {
		long f = atol(getenv("BLVO_FPS"));

		/* 0 disables pacing (the old free-run behaviour, which deadlocks
		 * kept only for bring-up). */
		if (f >= 0 && f <= 240)
			g_fps = f;
	}
	if (getenv("BLVO_BIND"))
		g_do_bind = atoi(getenv("BLVO_BIND"));
	if (getenv("BLVO_PUMP"))
		g_do_pump = atoi(getenv("BLVO_PUMP"));

	/* every stage is best-effort; nothing below aborts the run */
	sys_up();
	vo_up();
	vdec_up();
	bind_up();

	report();

	if (!st_vdec_chn) {
		fprintf(stderr, "[badge_landscape_vo] no VDEC channel -- not starting"
			" the feeder; see the warnings above\n");
		teardown();
		return 1;
	}

	if (g_do_pump &&
	    pthread_create(&g_pump, NULL, pump_thread,
			   (void *)(uintptr_t)VDEC_CHN_ID) != 0) {
		fprintf(stderr, "[badge_landscape_vo] pump pthread_create failed\n");
		g_pump = 0;
		teardown();
		return 1;
	}

	if (pthread_create(&g_feeder, NULL, feeder_thread,
			   (void *)(uintptr_t)VDEC_CHN_ID) != 0) {
		fprintf(stderr, "[badge_landscape_vo] pthread_create failed\n");
		g_feeder = 0;
		teardown();
		return 1;
	}

	if (pthread_create(&g_wdog, NULL, wdog_thread,
			   (void *)(uintptr_t)VDEC_CHN_ID) != 0) {
		fprintf(stderr, "[badge_landscape_vo] watchdog pthread_create failed\n");
		g_wdog = 0;		/* not fatal: playback still works */
	}

	wait_for_stop();

	teardown();
	return 0;
}
