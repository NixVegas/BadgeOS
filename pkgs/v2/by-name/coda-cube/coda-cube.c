/*
 * coda-cube: the SG2000's CODA980 H.264 decoder as a live 3D renderer.
 *
 * Every frame the A53 transforms a cube, resolves visibility per 4x4 (or 8x8)
 * block, and turns each block's texture coordinate into a motion vector into a
 * texture atlas held in long-term reference pictures. Explicit weighted
 * prediction does the lighting. The result is one residual-free P-picture,
 * which the decoder draws. The decoded NV12 frame is converted to the window
 * surface's BGR24 (SDL3 on the badge's patched wl_shm framebuffer) and
 * presented.
 *
 * The generator is a port of the mcr.c reference model (same float operations,
 * so --stream-out reproduces its P-pictures byte for byte). The decoder side
 * issues the cvi_vc_driver ioctls that libvdec issues.
 *
 * Build flags: -DCODA_HW (decoder, needs soph-mpi headers), -DCODA_SDL (window).
 * Without them only the off-device modes exist (--stream-out, --bench).
 *
 * usage: coda-cube [options]
 *   --size 1280x720|640x368   picture size (default 1280x720)
 *   --part 4|8|16             partition size (default 4)
 *   --deblock                 loop filter on (QP 51, max offsets), free on HW
 *   --pages K                 rotated atlas pages (default 12)
 *   --tex T                   texture size (default 224 at 720p, 112 at 640x368)
 *   --dist D                  camera distance (6 = far, 3.2 = near; default 6)
 *   --period S                seconds per revolution (default 8)
 *   --atlas FILE              K atlas pages, raw I420 WxH each (research layout)
 *   --tex-in FILE             6 TxT RGB textures instead of the built-in ones
 *   --seconds S               stop after S seconds (default: run until ESC/signal)
 *   --stats                   once a second: fps and the per-frame split (also CODA_STATS=1)
 *   --headless                decode, but no window (converts into a private buffer)
 *   --dmabuf                  present NV12 through linux-dmabuf instead of converting to the
 *                             BGR24 window surface: one copy per frame into soph_drm dumb
 *                             buffers, which sway scans out (1280x720; sets soph_drm's
 *                             yuv_encoding to bt601 and yuv_range to full while it runs)
 *   --zero-copy               --dmabuf without the copy: sway gets the decoder's own frame
 *                             buffers, exported read-only as dma-bufs through /dev/soph-ion,
 *                             and a frame goes back to the VDEC only when sway releases it
 *   --pace frame|release      with --dmabuf/--zero-copy: present a frame once sway has shown
 *                             the last one (wl_surface.frame; default), or as soon as a buffer
 *                             is free (release: frames past 60 per second are never shown, for
 *                             benchmarks of the whole pipeline)
 *   --user USER               with --zero-copy, run as root: open the decoder, /dev/soph-ion
 *                             and soph_drm's colour parameters, then drop to USER (its groups,
 *                             gid and uid) before connecting to USER's compositor
 *   --dpb-extra N             N more frame buffers: adds N to the SPS max_num_ref_frames, which
 *                             stays at most 16 (default 0; with --zero-copy 2, or as many as fit).
 *                             They leave the decoder a free buffer while sway holds frames, but
 *                             not with --smooth: its sliding window keeps older renders in them
 *   --show-cursor             do not hide the pointer over the window (while it shows, sway
 *                             composites instead of scanning out)
 *   --no-convert              skip the NV12->BGR24 conversion (headless only)
 *   --pipeline                decode frame n in a thread while frame n+1 is generated
 *   --hw-every N              read HwDecTime from /proc/cvitek/vdec every N frames (default 4, 0 = never)
 *   --uncached                map decoded frames write-combined instead of cached, so reading
 *                             them needs no DMA_BUF_IOCTL_SYNC
 *   --chn N                   VDEC channel (default 0)
 *   --destroy                 destroy channel --chn (after a killed run), set soph_drm's
 *                             yuv_encoding and yuv_range back to auto, and exit
 *   --stream-out FILE         no decoder: write the stream (SPS/PPS, pages, --frames P-pictures)
 *   --frames N                frames for --stream-out/--bench; frame f is at angle 2*pi*f/N (default 60)
 *   --info-out FILE           per-frame partitions etc. in mcr.c's info format (with --stream-out)
 *   --dump-tex FILE           write the 6 textures (RGB) and exit
 *   --dump-atlas FILE         write the K atlas pages (I420) and exit
 *   --bench N                 time the generator over --frames frames, best of N, and exit
 *   --pcm-test                make edge_mb_pcm() emit partly covered MBs as I_PCM (a test pattern)
 *   --aa                      arm A: edge MBs (silhouettes, creases) as anti-aliased I_PCM
 *   --qp Q --ab-offset O      arm B: slice QP and alpha/beta offset div2 of the loop filter
 *                             (with --deblock; --deblock alone = QP 51, offset +6)
 *   --smooth diag|hv          arm C: half-pel smoothing B-picture(s) after the render (shown instead)
 *   --pose T                  freeze the animation at angle T (radians, 0..8 pi)
 *   --cpu-model FILE          with --stream-out: every output picture as the CPU decodes it (I420)
 *   --edges-out FILE          with --stream-out: per frame, int32 count + int32 edge MB indices
 *   --ref-out FILE            with --stream-out: the reference render, --ref-ss N (default 4) supersampled
 *   --page-test N             check page_of() (the atan2f-free page choice) against atan2f, exit
 *   --no-neon                 --aa (and nal_wrap) on the portable C path: the bit-exact reference
 *   --mc-test N               check the block MC used by --aa against the per-sample one (and, on
 *                             aarch64, the NEON MC/WP against the C ones), exit
 *   --convert-test N          check the NV12->BGR24/XRGB path against the portable one and the
 *                             float formula, time N conversions onto a 1280x720 surface, exit
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <grp.h>
#include <inttypes.h>
#include <math.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <pwd.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <time.h>
#include <unistd.h>

#ifdef CODA_HW
#include <cvi_comm_vb.h>
#include <linux/cvi_comm_vdec.h>
#include <linux/cvi_comm_video.h>
#include <linux/cvi_errno.h>
#include <linux/cvi_vc_drv_ioctl.h>
#include <linux/dma-buf.h>
#include <soph_ion.h>
#endif
#ifdef CODA_SDL
#include <SDL3/SDL.h>
#include <drm/drm.h>
#include "present-dmabuf.h"
#endif
#if defined(__aarch64__)
#include <arm_neon.h>
#endif

#define G 12               /* atlas gutter (replicated texture edge) */
#define MAXT 16            /* max triangles binned per MB */
#define MAXREF 16          /* frame pictures: at most 16 active refs per list */
#define MAXMB 4096

static int W = 1280, H = 720, WMB, HMB, PART = 4, T = 0, K = 12, B;
static float DIST = 6.0f;
static int NREF, REFPAGE[MAXREF], REFFACE[MAXREF], REFK[MAXREF];
static int g_pcm_test;
static int g_dpb_extra;   /* --dpb-extra: spare frame buffers, through max_num_ref_frames */

/* phase 3: edge treatments. g_aa: edge MBs as anti-aliased I_PCM (arm A).
 * g_dbk/g_qp/g_abo: loop filter, slice QP, alpha/beta offset div2 (arm B).
 * g_smooth: half-pel smoothing B-picture(s) after the render (arm C):
 * 1 = one B, edge MBs (+2,+2)/(-2,-2) qpel; 2 = H pass then V pass. */
static int g_aa, g_dbk, g_qp = 26, g_abo, g_smooth, g_need_edges;
static uint32_t g_rng = 0x9e3779b9u;
static double frand(void) { g_rng ^= g_rng << 13; g_rng ^= g_rng >> 17; g_rng ^= g_rng << 5; return (g_rng >> 8) * (1.0 / 16777216.0); }
static uint8_t *PGY[16], *PGU[16], *PGV[16];   /* pages in memory: 0 = black, 1..K = atlas */
static uint8_t g_edge[MAXMB];                    /* MBs a visible polygon edge crosses */
static int g_nedge;
static uint8_t *g_pcmstore;                      /* this frame's I_PCM samples, 384 per MB */
static double g_t_aa;                            /* time in the AA hook, this frame */
typedef struct {
	int fc, ne;
	float a[4], b[4], c[4], s[4];    /* outer edges, inside >= 0; s = 1/(|a|+|b|) */
	float iz[3], uz[3], vz[3];       /* the face's screen-linear planes */
	float light, x0, y0, x1, y1;     /* bbox */
} VFace;
static VFace g_vf[6];
static int g_nvf;

static double now_s(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec * 1e-9;
}

static void die(const char *m)
{
	fprintf(stderr, "coda-cube: %s\n", m);
	exit(2);
}

/* ------------------------------------------------------------ bit writer */
typedef struct { uint8_t *buf; size_t len; uint64_t acc; int n; } BW;
static inline void bw_u(BW *b, int n, uint32_t v) {
    b->acc = (b->acc << n) | (v & (n == 32 ? 0xffffffffu : ((1u << n) - 1)));
    b->n += n;
    while (b->n >= 8) { b->n -= 8; b->buf[b->len++] = (uint8_t)(b->acc >> b->n); }
    b->acc &= (1ull << b->n) - 1;
}
static inline void bw_ue(BW *b, uint32_t v) {
    uint32_t x = v + 1; int nb = 32 - __builtin_clz(x);
    if (2 * nb - 1 <= 32) bw_u(b, 2 * nb - 1, x);
    else { bw_u(b, nb - 1, 0); bw_u(b, nb, x); }
}
static inline void bw_se(BW *b, int v) { bw_ue(b, v > 0 ? 2 * v - 1 : -2 * v); }
static inline void bw_trailing(BW *b) { bw_u(b, 1, 1); if (b->n) bw_u(b, 8 - b->n, 0); }
static size_t nal_wrap(uint8_t *out, int ref_idc, int type, const uint8_t *rbsp, size_t n) {
    size_t o = 0; int z = 0;
    out[o++] = 0; out[o++] = 0; out[o++] = 0; out[o++] = 1;
    out[o++] = (uint8_t)((ref_idc << 5) | type);
    for (size_t i = 0; i < n; i++) {
        /* 8 bytes all > 3 need no escape and end any zero run: copy them */
        if (i + 8 <= n) {
            uint64_t x;
            memcpy(&x, rbsp + i, 8);
            if (!((x - 0x0404040404040404ull) & ~x & 0x8080808080808080ull)) {
                memcpy(out + o, rbsp + i, 8);
                o += 8; i += 7; z = 0;
                continue;
            }
        }
        if (z >= 2 && rbsp[i] <= 3) { out[o++] = 3; z = 0; }
        out[o++] = rbsp[i]; z = rbsp[i] ? 0 : z + 1;
    }
    return o;
}

/* ------------------------------------------------------------ scene (mcr.c) */
typedef struct { float x, y, z; } V3;
typedef struct {
    float ea[3], eb[3], ec[3];   /* edges: a*x + b*y + c >= 0 inside */
    float iz[3], uz[3], vz[3];   /* screen-linear planes (a, b, c) for 1/Z, u/Z, v/Z */
    int face; float sx[3], sy[3], wz[3], wu[3], wv[3];
} Tri;
static const V3 CUBE[8] = {{-1,-1,-1},{1,-1,-1},{1,1,-1},{-1,1,-1},{-1,-1,1},{1,-1,1},{1,1,1},{-1,1,1}};
static const int FACE[6][4] = {{4,5,6,7},{1,0,3,2},{5,1,2,6},{0,4,7,3},{7,6,2,3},{0,1,5,4}};
static const V3 NORM[6] = {{0,0,1},{0,0,-1},{1,0,0},{-1,0,0},{0,1,0},{0,-1,0}};

typedef struct {
    int ntri; Tri tri[12]; float light[6];
    int nlist[MAXMB]; uint8_t list[MAXMB][MAXT];
} Frame;

static void rot(float a, float b, float c, float R[3][3]) {
    float ca = cosf(a), sa = sinf(a), cb = cosf(b), sb = sinf(b), cc = cosf(c), sc = sinf(c);
    float X[3][3] = {{1,0,0},{0,ca,-sa},{0,sa,ca}}, Y[3][3] = {{cb,0,sb},{0,1,0},{-sb,0,cb}},
          Z[3][3] = {{cc,-sc,0},{sc,cc,0},{0,0,1}}, M[3][3];
    for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) {
        M[i][j] = 0; for (int k = 0; k < 3; k++) M[i][j] += Y[i][k] * X[k][j];
    }
    for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) {
        R[i][j] = 0; for (int k = 0; k < 3; k++) R[i][j] += Z[i][k] * M[k][j];
    }
}

static int plane3(const float *sx, const float *sy, const float *v, float *p) {
    float d = (sx[1]-sx[0])*(sy[2]-sy[0]) - (sx[2]-sx[0])*(sy[1]-sy[0]);
    if (fabsf(d) < 1e-9f) return 0;
    p[0] = ((v[1]-v[0])*(sy[2]-sy[0]) - (v[2]-v[0])*(sy[1]-sy[0])) / d;
    p[1] = ((sx[1]-sx[0])*(v[2]-v[0]) - (sx[2]-sx[0])*(v[1]-v[0])) / d;
    p[2] = v[0] - p[0]*sx[0] - p[1]*sy[0];
    return 1;
}

/* t: animation angle; mcr.c's frame f of nframes is t = (float)f / nframes * 6.2831853f */
static void scene(float t, Frame *F) {
    float R[3][3];
    rot(0.55f + 0.9f * sinf(t), t, 0.25f * t, R);
    const float dist = DIST;
    const float foc = 0.95f * H, cx = W * 0.5f, cy = H * 0.5f;
    const V3 L = {-0.45f, 0.62f, -0.64f};   /* towards the light, camera space */
    float sx[8], sy[8], iz[8];
    for (int i = 0; i < 8; i++) {
        V3 p = CUBE[i];
        float X = R[0][0]*p.x + R[0][1]*p.y + R[0][2]*p.z;
        float Y = R[1][0]*p.x + R[1][1]*p.y + R[1][2]*p.z;
        float Z = R[2][0]*p.x + R[2][1]*p.y + R[2][2]*p.z + dist;
        iz[i] = 1.0f / Z; sx[i] = cx + foc * X * iz[i]; sy[i] = cy - foc * Y * iz[i];
    }
    F->ntri = 0;
    for (int fc = 0; fc < 6; fc++) {
        V3 n = NORM[fc];
        float nx = R[0][0]*n.x + R[0][1]*n.y + R[0][2]*n.z, ny = R[1][0]*n.x + R[1][1]*n.y + R[1][2]*n.z,
              nz = R[2][0]*n.x + R[2][1]*n.y + R[2][2]*n.z;
        float d = nx*L.x + ny*L.y + nz*L.z;
        F->light[fc] = 0.3f + 0.7f * (d > 0 ? d : 0);
        static const float U[4] = {0,1,1,0}, V[4] = {0,0,1,1};
        static const int TI[2][3] = {{0,1,2},{0,2,3}};
        for (int k = 0; k < 2; k++) {
            Tri *tr = &F->tri[F->ntri];
            for (int j = 0; j < 3; j++) {
                int vi = FACE[fc][TI[k][j]], ui = TI[k][j];
                tr->sx[j] = sx[vi]; tr->sy[j] = sy[vi]; tr->wz[j] = iz[vi];
                tr->wu[j] = U[ui] * iz[vi]; tr->wv[j] = V[ui] * iz[vi];
            }
            /* screen y points down: front faces are clockwise on screen */
            float area = (tr->sx[1]-tr->sx[0])*(tr->sy[2]-tr->sy[0]) - (tr->sx[2]-tr->sx[0])*(tr->sy[1]-tr->sy[0]);
            if (area <= 0) continue;              /* back face (or degenerate) */
            for (int j = 0; j < 3; j++) {
                int a = j, b = (j + 1) % 3;
                tr->ea[j] = -(tr->sy[b] - tr->sy[a]); tr->eb[j] = tr->sx[b] - tr->sx[a];
                tr->ec[j] = -(tr->ea[j] * tr->sx[a] + tr->eb[j] * tr->sy[a]);
            }
            plane3(tr->sx, tr->sy, tr->wz, tr->iz); plane3(tr->sx, tr->sy, tr->wu, tr->uz);
            plane3(tr->sx, tr->sy, tr->wv, tr->vz);
            tr->face = fc; F->ntri++;
        }
    }
    /* bin into macroblocks */
    memset(F->nlist, 0, sizeof(int) * WMB * HMB);
    for (int i = 0; i < F->ntri; i++) {
        Tri *tr = &F->tri[i];
        float x0 = fminf(tr->sx[0], fminf(tr->sx[1], tr->sx[2])), x1 = fmaxf(tr->sx[0], fmaxf(tr->sx[1], tr->sx[2]));
        float y0 = fminf(tr->sy[0], fminf(tr->sy[1], tr->sy[2])), y1 = fmaxf(tr->sy[0], fmaxf(tr->sy[1], tr->sy[2]));
        int mx0 = (int)floorf(x0 / 16), mx1 = (int)floorf(x1 / 16), my0 = (int)floorf(y0 / 16), my1 = (int)floorf(y1 / 16);
        if (mx0 < 0) mx0 = 0;
        if (my0 < 0) my0 = 0;
        if (mx1 >= WMB) mx1 = WMB - 1;
        if (my1 >= HMB) my1 = HMB - 1;
        for (int my = my0; my <= my1; my++) for (int mx = mx0; mx <= mx1; mx++) {
            int m = my * WMB + mx;
            /* reject MBs fully outside one edge (test the 4 corners) */
            int out = 0;
            for (int j = 0; j < 3 && !out; j++) {
                float a = tr->ea[j], b = tr->eb[j], c = tr->ec[j];
                float xs = a > 0 ? mx * 16 + 16 : mx * 16, ys = b > 0 ? my * 16 + 16 : my * 16;
                if (a * xs + b * ys + c < 0) out = 1;
            }
            if (!out && F->nlist[m] < MAXT) F->list[m][F->nlist[m]++] = (uint8_t)i;
        }
    }
}

/* ------------------------------------------------------------ MV prediction (mcr.c)
 * Neighbour state per 4x4 block: sdone = decoded (available), sref = refIdx
 * (-1 for an intra MB, which is available but predicts nothing), smv = MV. */
static int8_t *sref; static int16_t (*smv)[2]; static uint8_t *sdone; static int W4, H4;
static inline int nb(int x, int y, int *r, int *mx, int *my) {
    if (x < 0 || y < 0 || x >= W4 || y >= H4 || !sdone[y * W4 + x]) { *r = -1; *mx = *my = 0; return 0; }
    int i = y * W4 + x; *r = sref[i]; *mx = smv[i][0]; *my = smv[i][1]; return 1;
}
static inline int med(int a, int b, int c) { int t; if (a > b) { t = a; a = b; b = t; } if (b > c) b = c; return a > b ? a : b; }
static void mvp(int x, int y, int w, int r, int *px, int *py) {
    int ra, ax, ay, rb, bx, by, rc, cx, cy;
    int A = nb(x - 1, y, &ra, &ax, &ay), B_ = nb(x, y - 1, &rb, &bx, &by), C = nb(x + w, y - 1, &rc, &cx, &cy);
    if (!C) C = nb(x - 1, y - 1, &rc, &cx, &cy);
    if (!B_ && !C && A) { rb = rc = ra; bx = cx = ax; by = cy = ay; }
    int n = (ra == r) + (rb == r) + (rc == r);
    if (n == 1) {
        if (ra == r) { *px = ax; *py = ay; } else if (rb == r) { *px = bx; *py = by; } else { *px = cx; *py = cy; }
        return;
    }
    *px = med(ax, bx, cx); *py = med(ay, by, cy);
}
static void pskip_mv(int x, int y, int *px, int *py) {
    int ra, ax, ay, rb, bx, by;
    int A = nb(x - 1, y, &ra, &ax, &ay), B_ = nb(x, y - 1, &rb, &bx, &by);
    if (!A || !B_ || (ra == 0 && !ax && !ay) || (rb == 0 && !bx && !by)) { *px = *py = 0; return; }
    mvp(x, y, 4, 0, px, py);
}
static inline void setmb(int x, int y, int r, int mx, int my) {   /* setblk(x, y, 4, 4, ...) */
    const int16_t mv[8] = {(int16_t)mx, (int16_t)my, (int16_t)mx, (int16_t)my, (int16_t)mx, (int16_t)my, (int16_t)mx, (int16_t)my};
    for (int j = y; j < y + 4; j++) {
        int k = j * W4 + x;
        memset(sref + k, (int8_t)r, 4);
        memset(sdone + k, 1, 4);
        memcpy(smv[k], mv, sizeof mv);
    }
}
static inline void setblk(int x, int y, int w, int h, int r, int mx, int my) {
    for (int j = y; j < y + h; j++) for (int i = x; i < x + w; i++) {
        int k = j * W4 + i; sref[k] = (int8_t)r; smv[k][0] = (int16_t)mx; smv[k][1] = (int16_t)my; sdone[k] = 1;
    }
}

/* ------------------------------------------------------------ per-block decision (mcr.c) */
typedef struct { int16_t x, y, w, h, ref, mvx, mvy; } Part;   /* ref -1: I_PCM macroblock */
static int slot_x(int fc) { return (fc % 3) * B; }
static int slot_y(int fc) { return (fc / 3) * B; }
static int BLACKX, BLACKY;
static float CK[64], SK[64];
/* atlas point of texel-space point (tu,tv) of face fc in page k, block size bs; returns qpel mv */
static void mv_for(int fc, int k, float tu, float tv, float px, float py, int bs, int *mvx, int *mvy) {
    float dx = tu - T * 0.5f, dy = tv - T * 0.5f;
    float qx = B * 0.5f + CK[k] * dx + SK[k] * dy, qy = B * 0.5f - SK[k] * dx + CK[k] * dy;  /* R(-theta_k) */
    float lo = bs * 0.5f + 2.5f, hi = B - bs * 0.5f - 3.0f;
    if (qx < lo) qx = lo;
    if (qx > hi) qx = hi;
    if (qy < lo) qy = lo;
    if (qy > hi) qy = hi;
    *mvx = (int)lrintf(4.0f * (slot_x(fc) + qx - px));
    *mvy = (int)lrintf(4.0f * (slot_y(fc) + qy - py));
}

/*
 * The atlas page for screen->texture rotation atan2(y, x):
 * ((lrintf(atan2f(y, x) * K / 6.2831853f) % K) + K) % K, without atan2f in
 * the common case. A 5-term polynomial atan (Abramowitz & Stegun 4.4.49,
 * |error| <= 1e-5 rad) places the angle; only within 1e-4 page steps of a
 * rounding boundary (5x the worst error, in page units) does it ask atan2f,
 * so the page is always the one atan2f gives. --page-test checks it.
 */
static int g_page_slow;   /* fallbacks, for --page-test */
static inline int page_of(float y, float x)
{
	float ax = fabsf(x), ay = fabsf(y), mn = ax < ay ? ax : ay, mxv = ax < ay ? ay : ax;
	if (mxv > 1e-20f && mxv < 1e20f) {
		float t = mn / mxv, t2 = t * t;
		float a = t * (0.9998660f + t2 * (-0.3302995f + t2 * (0.1801410f + t2 * (-0.0851330f + t2 * 0.0208351f))));
		if (ay > ax) a = 1.57079633f - a;
		if (x < 0) a = 3.14159265f - a;
		if (y < 0) a = -a;
		float sct = a * K / 6.2831853f, fl = floorf(sct), fr = sct - fl;
		if (fabsf(fr - 0.5f) > 1e-4f) {
			int k = (int)fl + (fr > 0.5f);
			return ((k % K) + K) % K;
		}
	}
	g_page_slow++;
	int k = (int)lrintf(atan2f(y, x) * K / 6.2831853f);
	return ((k % K) + K) % K;
}

/* --page-test N: page_of() against the atan2f formula on N random directions
 * (all magnitudes and angles, plus points right at the page boundaries) */
static int page_test(long n)
{
	long bad = 0;
	g_page_slow = 0;
	for (long i = 0; i < n; i++) {
		float x, y;
		if (i & 1) {   /* uniform-ish directions and magnitudes */
			x = (float)((frand() * 2 - 1) * pow(10, frand() * 8 - 4));
			y = (float)((frand() * 2 - 1) * pow(10, frand() * 8 - 4));
		} else {       /* near a page boundary angle */
			double th = ((int)(frand() * 2 * K) - K + 0.5) * 6.283185307179586 / K + (frand() - 0.5) * 6e-4;   /* +-3e-4 rad: mostly just outside the fallback band */
			double r = pow(10, frand() * 6 - 3);
			x = (float)(r * cos(th));
			y = (float)(r * sin(th));
		}
		int k = (int)lrintf(atan2f(y, x) * K / 6.2831853f);
		bad += page_of(y, x) != ((k % K) + K) % K;
	}
	printf("page-test K=%d: %ld directions, %ld differ, %d fell back to atan2f\n", K, n, bad, g_page_slow);
	return bad != 0;
}

/* returns face id or -1; fills texel coords and the preferred angle page */
static int block_hit(const Frame *F, int m, float px, float py, float *tu, float *tv, int *kp) {
    int best = -1; float bz = 0;
    for (int k = 0; k < F->nlist[m]; k++) {
        const Tri *t = &F->tri[F->list[m][k]];
        if (t->ea[0]*px + t->eb[0]*py + t->ec[0] < 0 || t->ea[1]*px + t->eb[1]*py + t->ec[1] < 0 ||
            t->ea[2]*px + t->eb[2]*py + t->ec[2] < 0) continue;
        float z = t->iz[0]*px + t->iz[1]*py + t->iz[2];
        if (z > bz) { bz = z; best = F->list[m][k]; }
    }
    if (best < 0) return -1;
    const Tri *t = &F->tri[best];
    float inv = 1.0f / bz;
    float u = (t->uz[0]*px + t->uz[1]*py + t->uz[2]) * inv, v = (t->vz[0]*px + t->vz[1]*py + t->vz[2]) * inv;
    *tu = u * T; *tv = v * T; *kp = 0;
    if (K > 1) {   /* rotation part of the screen->texture Jacobian */
        float ux = (t->uz[0] - u * t->iz[0]) * inv, uy = (t->uz[1] - u * t->iz[1]) * inv;
        float vx = (t->vz[0] - v * t->iz[0]) * inv, vy = (t->vz[1] - v * t->iz[1]) * inv;
        *kp = page_of(vx - uy, ux + vy);              /* J = [[ux uy],[vx vy]] ~ R(th) S */
    }
    return t->face;
}

/* ------------------------------------------------------------ edges, CPU motion compensation, AA */
static void mark_segment(float x0, float y0, float x1, float y1, float a, float b, float c)
{
	float n = sqrtf(a * a + b * b);
	const float pad = 1.0f;   /* fractional coverage reaches 0.71 px from an edge */
	if (n < 1e-9f)
		return;
	int mx0 = (int)floorf((fminf(x0, x1) - pad) / 16), mx1 = (int)floorf((fmaxf(x0, x1) + pad) / 16);
	int my0 = (int)floorf((fminf(y0, y1) - pad) / 16), my1 = (int)floorf((fmaxf(y0, y1) + pad) / 16);
	if (mx0 < 0) mx0 = 0;
	if (my0 < 0) my0 = 0;
	if (mx1 >= WMB) mx1 = WMB - 1;
	if (my1 >= HMB) my1 = HMB - 1;
	for (int my = my0; my <= my1; my++)
		for (int mx = mx0; mx <= mx1; mx++) {
			float lo = 1e30f, hi = -1e30f;
			for (int k = 0; k < 4; k++) {
				float X = mx * 16 + ((k & 1) ? 16 + pad : -pad), Y = my * 16 + ((k & 2) ? 16 + pad : -pad);
				float d = a * X + b * Y + c;
				if (d < lo) lo = d;
				if (d > hi) hi = d;
			}
			if (lo <= 0 && hi >= 0)
				g_edge[my * WMB + mx] = 1;
		}
}

/* the visible faces (front-facing quads; the cube is convex, so they do not
 * overlap) and the MBs their outer edges cross: silhouettes and creases */
static void find_edges(const Frame *F)
{
	memset(g_edge, 0, (size_t)WMB * HMB);
	g_nvf = 0;
	for (int i = 0; i < F->ntri; i++) {
		const Tri *t0 = &F->tri[i];
		VFace *v = &g_vf[g_nvf++];
		float ex[4][4];   /* x0 y0 x1 y1 per edge */
		v->fc = t0->face;
		v->light = F->light[t0->face];
		memcpy(v->iz, t0->iz, sizeof v->iz);
		memcpy(v->uz, t0->uz, sizeof v->uz);
		memcpy(v->vz, t0->vz, sizeof v->vz);
		if (i + 1 < F->ntri && F->tri[i + 1].face == t0->face) {
			/* quad v0 v1 v2 v3: t0 = (v0 v1 v2), t1 = (v0 v2 v3); outer edges t0.e0, t0.e1, t1.e1, t1.e2 */
			const Tri *t1 = &F->tri[i + 1];
			const Tri *tt[4] = {t0, t0, t1, t1};
			const int jj[4] = {0, 1, 1, 2};
			v->ne = 4;
			for (int e = 0; e < 4; e++) {
				const Tri *t = tt[e];
				int j = jj[e], a = j, b = (j + 1) % 3;
				v->a[e] = t->ea[j]; v->b[e] = t->eb[j]; v->c[e] = t->ec[j];
				ex[e][0] = t->sx[a]; ex[e][1] = t->sy[a]; ex[e][2] = t->sx[b]; ex[e][3] = t->sy[b];
			}
			i++;
		} else {
			v->ne = 3;
			for (int j = 0; j < 3; j++) {
				v->a[j] = t0->ea[j]; v->b[j] = t0->eb[j]; v->c[j] = t0->ec[j];
				ex[j][0] = t0->sx[j]; ex[j][1] = t0->sy[j]; ex[j][2] = t0->sx[(j + 1) % 3]; ex[j][3] = t0->sy[(j + 1) % 3];
			}
		}
		v->x0 = v->y0 = 1e30f;
		v->x1 = v->y1 = -1e30f;
		for (int e = 0; e < v->ne; e++) {
			float w = fabsf(v->a[e]) + fabsf(v->b[e]);
			v->s[e] = w > 1e-12f ? 1.0f / w : 0;
			v->x0 = fminf(v->x0, fminf(ex[e][0], ex[e][2])); v->x1 = fmaxf(v->x1, fmaxf(ex[e][0], ex[e][2]));
			v->y0 = fminf(v->y0, fminf(ex[e][1], ex[e][3])); v->y1 = fmaxf(v->y1, fmaxf(ex[e][1], ex[e][3]));
			mark_segment(ex[e][0], ex[e][1], ex[e][2], ex[e][3], v->a[e], v->b[e], v->c[e]);
		}
	}
	g_nedge = 0;
	for (int m = 0; m < WMB * HMB; m++)
		g_nedge += g_edge[m];
}

/* H.264 8.4.2.2: quarter-sample luma (6-tap) and eighth-sample chroma
 * interpolation with the reference clamped at its borders, then explicit WP
 * with logWD 6. The same arithmetic as the decoder (and the research model). */
static inline int clip1(int v) { return v < 0 ? 0 : v > 255 ? 255 : v; }
static inline int pyx(const uint8_t *P, int x, int y)
{
	x = x < 0 ? 0 : x >= W ? W - 1 : x;
	y = y < 0 ? 0 : y >= H ? H - 1 : y;
	return P[(size_t)y * W + x];
}
static inline int b1_at(const uint8_t *P, int x, int y)
{
	return pyx(P, x - 2, y) - 5 * pyx(P, x - 1, y) + 20 * pyx(P, x, y) + 20 * pyx(P, x + 1, y) - 5 * pyx(P, x + 2, y) + pyx(P, x + 3, y);
}
static inline int h1_at(const uint8_t *P, int x, int y)
{
	return pyx(P, x, y - 2) - 5 * pyx(P, x, y - 1) + 20 * pyx(P, x, y) + 20 * pyx(P, x, y + 1) - 5 * pyx(P, x, y + 2) + pyx(P, x, y + 3);
}
static inline int avg2(int a, int b) { return (a + b + 1) >> 1; }
static int luma_qpel(const uint8_t *P, int x, int y, int fx, int fy)
{
	if (!fx && !fy)
		return pyx(P, x, y);
	int g0 = pyx(P, x, y);
	int b = clip1((b1_at(P, x, y) + 16) >> 5), h = clip1((h1_at(P, x, y) + 16) >> 5);
	if (fy == 0)
		return fx == 1 ? avg2(g0, b) : fx == 2 ? b : avg2(pyx(P, x + 1, y), b);
	if (fx == 0)
		return fy == 1 ? avg2(g0, h) : fy == 2 ? h : avg2(pyx(P, x, y + 1), h);
	int s = clip1((b1_at(P, x, y + 1) + 16) >> 5), m = clip1((h1_at(P, x + 1, y) + 16) >> 5);
	if (fx == 2 || fy == 2) {
		int j1 = b1_at(P, x, y - 2) - 5 * b1_at(P, x, y - 1) + 20 * b1_at(P, x, y) + 20 * b1_at(P, x, y + 1) -
			 5 * b1_at(P, x, y + 2) + b1_at(P, x, y + 3);
		int j = clip1((j1 + 512) >> 10);
		if (fx == 2)
			return fy == 1 ? avg2(b, j) : fy == 2 ? j : avg2(j, s);
		return fx == 1 ? avg2(h, j) : avg2(j, m);
	}
	if (fy == 1)
		return fx == 1 ? avg2(b, h) : avg2(b, m);
	return fx == 1 ? avg2(h, s) : avg2(m, s);
}
static inline int pcyx(const uint8_t *P, int x, int y)
{
	x = x < 0 ? 0 : x >= W / 2 ? W / 2 - 1 : x;
	y = y < 0 ? 0 : y >= H / 2 ? H / 2 - 1 : y;
	return P[(size_t)y * (W / 2) + x];
}
/* chroma sample (xc, yc) of a block predicted with luma MV (mvx, mvy) */
static inline int chroma_pred(const uint8_t *P, int xc, int yc, int mvx, int mvy)
{
	int xi = xc + (mvx >> 3), yi = yc + (mvy >> 3), fx = mvx & 7, fy = mvy & 7;
	if (xi >= 0 && yi >= 0 && xi + 1 < W / 2 && yi + 1 < H / 2) {
		const uint8_t *a = P + (size_t)yi * (W / 2) + xi, *c = a + W / 2;
		return ((8 - fx) * (8 - fy) * a[0] + fx * (8 - fy) * a[1] + (8 - fx) * fy * c[0] + fx * fy * c[1] + 32) >> 6;
	}
	return ((8 - fx) * (8 - fy) * pcyx(P, xi, yi) + fx * (8 - fy) * pcyx(P, xi + 1, yi) +
		(8 - fx) * fy * pcyx(P, xi, yi + 1) + fx * fy * pcyx(P, xi + 1, yi + 1) + 32) >> 6;
}
static inline int wp6(int v, int w, int o) { return clip1(((v * w + 32) >> 6) + o); }

/* luma_qpel() for a whole w x h block (w, h <= 16): the window is fetched
 * once and the 6-tap intermediates are shared. --mc-test checks it equals
 * luma_qpel() sample for sample. */
static void mc_luma_block(const uint8_t *P, int x, int y, int w, int h, int mvx, int mvy, int *out)
{
	int xi = x + (mvx >> 2), yi = y + (mvy >> 2), fx = mvx & 3, fy = mvy & 3, WW = w + 5, HH = h + 5;
	int win[21][21], B1[21][16];
	if (xi - 2 >= 0 && yi - 2 >= 0 && xi - 2 + WW <= W && yi - 2 + HH <= H) {
		for (int r = 0; r < HH; r++) {
			const uint8_t *row = P + (size_t)(yi - 2 + r) * W + xi - 2;
			for (int c = 0; c < WW; c++) win[r][c] = row[c];
		}
	} else {
		for (int r = 0; r < HH; r++)
			for (int c = 0; c < WW; c++) win[r][c] = pyx(P, xi - 2 + c, yi - 2 + r);
	}
#define TAP6(a, b, c, d, e, f) ((a) - 5 * (b) + 20 * (c) + 20 * (d) - 5 * (e) + (f))
	if (!fx && !fy) {
		for (int j = 0; j < h; j++) for (int i = 0; i < w; i++) out[j * w + i] = win[j + 2][i + 2];
	} else if (fy == 0) {               /* b, and the quarter positions beside it */
		int o = fx == 1 ? 2 : 3;
		for (int j = 0; j < h; j++)
			for (int i = 0; i < w; i++) {
				const int *a = &win[j + 2][i];
				int b = clip1((TAP6(a[0], a[1], a[2], a[3], a[4], a[5]) + 16) >> 5);
				out[j * w + i] = fx == 2 ? b : avg2(a[o], b);
			}
	} else if (fx == 0) {               /* h, and the quarter positions above and below it */
		int o = fy == 1 ? 2 : 3;
		for (int j = 0; j < h; j++)
			for (int i = 0; i < w; i++) {
				int x = i + 2, hh = clip1((TAP6(win[j][x], win[j + 1][x], win[j + 2][x], win[j + 3][x], win[j + 4][x], win[j + 5][x]) + 16) >> 5);
				out[j * w + i] = fy == 2 ? hh : avg2(win[j + o][x], hh);
			}
	} else if (fx == 2 || fy == 2) {    /* j, alone or averaged with b, s, h or m */
		for (int r = 0; r < HH; r++)
			for (int i = 0; i < w; i++) {
				const int *a = &win[r][i];
				B1[r][i] = TAP6(a[0], a[1], a[2], a[3], a[4], a[5]);
			}
		for (int j = 0; j < h; j++)
			for (int i = 0; i < w; i++) {
				int jj = clip1((TAP6(B1[j][i], B1[j + 1][i], B1[j + 2][i], B1[j + 3][i], B1[j + 4][i], B1[j + 5][i]) + 512) >> 10), v;
				if (fx == 2) {
					v = fy == 2 ? jj : avg2(jj, clip1((B1[j + (fy == 1 ? 2 : 3)][i] + 16) >> 5));
				} else {
					int x = i + (fx == 1 ? 2 : 3);
					v = avg2(jj, clip1((TAP6(win[j][x], win[j + 1][x], win[j + 2][x], win[j + 3][x], win[j + 4][x], win[j + 5][x]) + 16) >> 5));
				}
				out[j * w + i] = v;
			}
	} else {                            /* (1|3, 1|3): b or s averaged with h or m */
		int ry = fy == 1 ? 2 : 3, cx = fx == 1 ? 2 : 3;
		for (int j = 0; j < h; j++)
			for (int i = 0; i < w; i++) {
				const int *a = &win[j + ry][i];
				int b = clip1((TAP6(a[0], a[1], a[2], a[3], a[4], a[5]) + 16) >> 5), x = i + cx;
				int hh = clip1((TAP6(win[j][x], win[j + 1][x], win[j + 2][x], win[j + 3][x], win[j + 4][x], win[j + 5][x]) + 16) >> 5);
				out[j * w + i] = avg2(b, hh);
			}
	}
#undef TAP6
}

#if defined(__aarch64__)
static long mc_test_neon(int n, const uint8_t *P, const uint8_t *PU, const uint8_t *PV);
#endif
/* --mc-test: mc_luma_block() against luma_qpel() on random blocks, MVs and
 * pages, including blocks that reach past the picture border */
static int mc_test(int n)
{
	uint8_t *P = malloc((size_t)W * H);
	long bad = 0, tot = 0;
	for (size_t i = 0; i < (size_t)W * H; i++) P[i] = (uint8_t)(frand() * 256);
	for (int t = 0; t < n; t++) {
		int w = (t & 1) ? 4 : (t & 2) ? 8 : 16, h = w;
		int x = (int)(frand() * (W + 40)) - 20, y = (int)(frand() * (H + 40)) - 20;
		int mvx = (int)(frand() * 400) - 200, mvy = (int)(frand() * 400) - 200, out[256];
		mc_luma_block(P, x, y, w, h, mvx, mvy, out);
		for (int j = 0; j < h; j++)
			for (int i = 0; i < w; i++, tot++)
				bad += out[j * w + i] != luma_qpel(P, x + i + (mvx >> 2), y + j + (mvy >> 2), mvx & 3, mvy & 3);
	}
	printf("mc-test: %d blocks, %ld samples, %ld differ\n", n, tot, bad);
	int fail = bad != 0;
#if defined(__aarch64__)
	uint8_t *PU = malloc((size_t)W * H / 4), *PV = malloc((size_t)W * H / 4);
	for (size_t i = 0; i < (size_t)W * H / 4; i++) { PU[i] = (uint8_t)(frand() * 256); PV[i] = (uint8_t)(frand() * 256); }
	/* PU/PV are separate buffers here: keep the NEON loads inside them */
	uint8_t *big = malloc((size_t)W * H * 3 / 2 + 64);
	memcpy(big, P, (size_t)W * H); memcpy(big + (size_t)W * H, PU, (size_t)W * H / 4); memcpy(big + (size_t)W * H * 5 / 4, PV, (size_t)W * H / 4);
	long nb = mc_test_neon(n, big, big + (size_t)W * H, big + (size_t)W * H * 5 / 4);
	printf("mc-test NEON: %d 4x4 luma blocks, 2x2 chroma blocks and WP vectors vs C: %ld samples differ\n", n, nb);
	fail |= nb != 0;
	free(PU); free(PV); free(big);
#endif
	free(P);
	return fail;
}

/* the MV and page a 4x4 block centred at (cx, cy) gets for face v (block_hit's
 * texel point and page choice, evaluated on the face's planes) */
static void face_block_mv(const VFace *v, float cx, float cy, int *kp, int *mvx, int *mvy)
{
	float z = v->iz[0] * cx + v->iz[1] * cy + v->iz[2];
	if (z < 1e-6f) z = 1e-6f;
	float inv = 1.0f / z;
	float u = (v->uz[0] * cx + v->uz[1] * cy + v->uz[2]) * inv, w = (v->vz[0] * cx + v->vz[1] * cy + v->vz[2]) * inv;
	int k = 0;
	if (K > 1) {
		float ux = (v->uz[0] - u * v->iz[0]) * inv, uy = (v->uz[1] - u * v->iz[1]) * inv;
		float vx = (v->vz[0] - w * v->iz[0]) * inv, vy = (v->vz[1] - w * v->iz[1]) * inv;
		k = page_of(vx - uy, ux + vy);
	}
	*kp = k;
	mv_for(v->fc, k, u * T, w * T, cx, cy, 4, mvx, mvy);
}

/*
 * Arm A: one edge MB as anti-aliased I_PCM. Per pixel, each visible face's
 * coverage is the product of its outer edges' box-filter ramps
 * clamp(0.5 + d / (|nx| + |ny|)); the colour is sum(cov_i * sample_i) +
 * (1 - sum cov_i) * black. sample_i is exactly what the decoder draws for face
 * i in that 4x4 block (its MV, page and light; quarter-pel MC + WP on the CPU),
 * so fully covered pixels match the neighbouring MC blocks. Chroma coverage is
 * the mean over the 2x2 luma pixels.
 */
/* the faces that touch MB (X0, Y0) and, per face, the edges whose ramp is
 * not 1 everywhere in it (the others multiply by 1) */
static int aa_faces(int X0, int Y0, int cand[6], int ce[6][4], int nce[6])
{
	int nc = 0;
	for (int f = 0; f < g_nvf; f++) {
		const VFace *v = &g_vf[f];
		if (v->x1 < X0 - 1 || v->x0 > X0 + 17 || v->y1 < Y0 - 1 || v->y0 > Y0 + 17)
			continue;
		int out = 0, n = 0;
		for (int e = 0; e < v->ne && !out; e++) {   /* the ramp is linear: its extremes are at the corner pixels */
			float lo = 1e30f, hi = -1e30f;
			for (int k = 0; k < 4; k++) {
				float t = 0.5f + (v->a[e] * (X0 + ((k & 1) ? 15.5f : 0.5f)) + v->b[e] * (Y0 + ((k & 2) ? 15.5f : 0.5f)) + v->c[e]) * v->s[e];
				lo = t < lo ? t : lo;
				hi = t > hi ? t : hi;
			}
			if (hi <= 0) out = 1;
			else if (lo < 1) ce[nc][n++] = e;
		}
		if (out)
			continue;
		nce[nc] = n;
		cand[nc++] = f;
	}
	return nc;
}

static void aa_mb_c(int mb, uint8_t pcm[384])
{
	int X0 = (mb % WMB) * 16, Y0 = (mb / WMB) * 16, cand[6], ce[6][4], nce[6];
	int nc = aa_faces(X0, Y0, cand, ce, nce);
	static float cov[6][256];
	float sum[256], Ya[256], Ua[64], Va[64];
	for (int i = 0; i < 256; i++) sum[i] = 0;
	for (int c = 0; c < nc; c++) {
		const VFace *v = &g_vf[cand[c]];
		float *cv = cov[c];
		for (int i = 0; i < 256; i++) cv[i] = 1;
		for (int q = 0; q < nce[c]; q++) {
			int e = ce[c][q];
			float a = v->a[e], b = v->b[e], cc = v->c[e], sc = v->s[e];
			for (int y = 0; y < 16; y++) {
				float bpy = b * ((float)(Y0 + y) + 0.5f);
				for (int x = 0; x < 16; x++) {   /* evaluated per pixel: the NEON path computes the same */
					float t = 0.5f + (a * ((float)(X0 + x) + 0.5f) + bpy + cc) * sc;
					cv[y * 16 + x] *= t < 0 ? 0 : t > 1 ? 1 : t;
				}
			}
		}
		for (int i = 0; i < 256; i++) sum[i] += cv[i];
	}
	for (int i = 0; i < 256; i++) {
		if (sum[i] > 1) {
			for (int c = 0; c < nc; c++) cov[c][i] /= sum[i];
			sum[i] = 1;
		}
		Ya[i] = 0;
	}
	for (int i = 0; i < 64; i++) Ua[i] = Va[i] = 0;
	for (int q = 0; q < 16; q++) {
		int bx = X0 + (q & 3) * 4, by = Y0 + (q >> 2) * 4, o = (q >> 2) * 64 + (q & 3) * 4;
		for (int c = 0; c < nc; c++) {
			float mx = 0;
			for (int j = 0; j < 4; j++) for (int i = 0; i < 4; i++) { float t = cov[c][o + j * 16 + i]; mx = t > mx ? t : mx; }
			if (mx * 255 < 0.5f) continue;   /* contributes under half an LSB */
			const VFace *v = &g_vf[cand[c]];
			int k, mvx, mvy, w = (int)lrintf(v->light * 64);
			face_block_mv(v, bx + 2.0f, by + 2.0f, &k, &mvx, &mvy);
			const uint8_t *PU_ = PGU[1 + k], *PV_ = PGV[1 + k];
			int pred[16];
			mc_luma_block(PGY[1 + k], bx, by, 4, 4, mvx, mvy, pred);
			for (int j = 0; j < 4; j++)
				for (int i = 0; i < 4; i++) {
					float cv = cov[c][o + j * 16 + i];
					if (cv > 0)
						Ya[o + j * 16 + i] += cv * wp6(pred[j * 4 + i], w, 0);
				}
			for (int j = 0; j < 2; j++)
				for (int i = 0; i < 2; i++) {
					int l = o + 2 * j * 16 + 2 * i;
					float cc = 0.25f * (cov[c][l] + cov[c][l + 1] + cov[c][l + 16] + cov[c][l + 17]);
					if (cc <= 0) continue;
					int xc = bx / 2 + i, yc = by / 2 + j, ci = (yc - Y0 / 2) * 8 + (xc - X0 / 2);
					Ua[ci] += cc * wp6(chroma_pred(PU_, xc, yc, mvx, mvy), w, 128 - 2 * w);
					Va[ci] += cc * wp6(chroma_pred(PV_, xc, yc, mvx, mvy), w, 128 - 2 * w);
				}
		}
	}
	for (int i = 0; i < 256; i++) {
		float y = Ya[i] + 0.5f;
		pcm[i] = (uint8_t)(y > 255 ? 255 : y);
	}
	for (int i = 0; i < 64; i++) {
		int l = (i >> 3) * 32 + (i & 7) * 2;
		float bg = 1 - 0.25f * (sum[l] + sum[l + 1] + sum[l + 16] + sum[l + 17]);
		float u = Ua[i] + bg * 128 + 0.5f, v = Va[i] + bg * 128 + 0.5f;
		pcm[256 + i] = (uint8_t)(u < 0 ? 0 : u > 255 ? 255 : u);
		pcm[320 + i] = (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v);
	}
}

#if defined(__aarch64__)
/*
 * NEON versions of the --aa work, bit-exact with the C reference above
 * (--no-neon): the same integer MC/WP arithmetic, and the same float
 * operations in the same order (no fused multiply-add, IEEE min/max/div,
 * truncating conversions), so every I_PCM sample is identical.
 */
static int g_neon = 1;

/* horizontal 6-tap intermediates (b1) for output columns 0..7 of a row loaded at x - 2 */
static inline int16x8_t tap6h(uint8x16_t row)
{
	int16x8_t lo = vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(row)));
	int16x8_t hi = vreinterpretq_s16_u16(vmovl_u8(vget_high_u8(row)));
	int16x8_t s = vaddq_s16(lo, vextq_s16(lo, hi, 5));
	s = vmlaq_n_s16(s, vaddq_s16(vextq_s16(lo, hi, 2), vextq_s16(lo, hi, 3)), 20);
	return vmlsq_n_s16(s, vaddq_s16(vextq_s16(lo, hi, 1), vextq_s16(lo, hi, 4)), 5);
}
/* vertical 6-tap over six int16 rows */
static inline int16x8_t tap6v(int16x8_t r0, int16x8_t r1, int16x8_t r2, int16x8_t r3, int16x8_t r4, int16x8_t r5)
{
	int16x8_t s = vaddq_s16(r0, r5);
	s = vmlaq_n_s16(s, vaddq_s16(r2, r3), 20);
	return vmlsq_n_s16(s, vaddq_s16(r1, r4), 5);
}

/* mc_luma_block() for a 4x4 block; row j of the prediction in lanes 0..3 of out[j] */
static void mc_luma4_neon(const uint8_t *P, int x, int y, int mvx, int mvy, uint8x8_t out[4])
{
	int xi = x + (mvx >> 2), yi = y + (mvy >> 2), fx = mvx & 3, fy = mvy & 3;
	if (xi - 2 < 0 || yi - 2 < 0 || xi + 6 > W - 1 || yi + 6 > H - 1) {   /* clamped edges: the C path */
		int t[16];
		uint8_t b[32] = {0};
		mc_luma_block(P, x, y, 4, 4, mvx, mvy, t);
		for (int i = 0; i < 16; i++) b[(i >> 2) * 8 + (i & 3)] = (uint8_t)t[i];
		for (int j = 0; j < 4; j++) out[j] = vld1_u8(b + 8 * j);
		return;
	}
	/* rows yi-2 .. yi+6 from column xi-2 (lanes 0..8 used; the rest is the
	 * next pixels of the page, which always follows in the buffer) */
	const uint8_t *p0 = P + (size_t)(yi - 2) * W + (xi - 2);
	uint8x16_t R[9];
	for (int r = 0; r < 9; r++) R[r] = vld1q_u8(p0 + (size_t)r * W);
	if (!fx && !fy) {
		for (int j = 0; j < 4; j++) out[j] = vext_u8(vget_low_u8(R[j + 2]), vget_high_u8(R[j + 2]), 2);
		return;
	}
	if (fy == 0) {   /* b, (G+b)/2, (b+H)/2 */
		for (int j = 0; j < 4; j++) {
			uint8x8_t b = vqrshrun_n_s16(tap6h(R[j + 2]), 5);
			if (fx == 2) out[j] = b;
			else out[j] = vrhadd_u8(b, fx == 1 ? vext_u8(vget_low_u8(R[j + 2]), vget_high_u8(R[j + 2]), 2)
						       : vext_u8(vget_low_u8(R[j + 2]), vget_high_u8(R[j + 2]), 3));
		}
		return;
	}
	int16x8_t Rw[9];   /* columns 0..7 of each row, widened */
	for (int r = 0; r < 9; r++) Rw[r] = vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(R[r])));
	if (fx == 0) {   /* h, (G+h)/2, (h+M)/2 */
		for (int j = 0; j < 4; j++) {
			uint8x8_t h = vqrshrun_n_s16(tap6v(Rw[j], Rw[j + 1], Rw[j + 2], Rw[j + 3], Rw[j + 4], Rw[j + 5]), 5);
			h = vext_u8(h, h, 2);
			if (fy == 2) out[j] = h;
			else out[j] = vrhadd_u8(h, vext_u8(vget_low_u8(R[j + (fy == 1 ? 2 : 3)]), vget_high_u8(R[j + (fy == 1 ? 2 : 3)]), 2));
		}
		return;
	}
	if (fx == 2 || fy == 2) {   /* j, alone or with b, s, h or m */
		int16x8_t B1[9];
		for (int r = 0; r < 9; r++) B1[r] = tap6h(R[r]);
		for (int j = 0; j < 4; j++) {
			int16x4_t b0 = vget_low_s16(B1[j]), b1 = vget_low_s16(B1[j + 1]), b2 = vget_low_s16(B1[j + 2]);
			int16x4_t b3 = vget_low_s16(B1[j + 3]), b4 = vget_low_s16(B1[j + 4]), b5 = vget_low_s16(B1[j + 5]);
			int32x4_t acc = vaddl_s16(b0, b5);
			acc = vmlal_n_s16(acc, vadd_s16(b2, b3), 20);
			acc = vmlsl_n_s16(acc, vadd_s16(b1, b4), 5);
			uint16x4_t j16 = vqrshrun_n_s32(acc, 10);
			uint8x8_t jj = vqmovn_u16(vcombine_u16(j16, j16));
			uint8x8_t v;
			if (fx == 2) {
				v = fy == 2 ? jj : vrhadd_u8(jj, vqrshrun_n_s16(B1[j + (fy == 1 ? 2 : 3)], 5));
			} else {
				uint8x8_t h = vqrshrun_n_s16(tap6v(Rw[j], Rw[j + 1], Rw[j + 2], Rw[j + 3], Rw[j + 4], Rw[j + 5]), 5);
				v = vrhadd_u8(jj, fx == 1 ? vext_u8(h, h, 2) : vext_u8(h, h, 3));
			}
			out[j] = v;
		}
		return;
	}
	/* (1|3, 1|3): b (row j+2) or s (row j+3), averaged with h (col 2) or m (col 3) */
	for (int j = 0; j < 4; j++) {
		uint8x8_t b = vqrshrun_n_s16(tap6h(R[j + (fy == 1 ? 2 : 3)]), 5);
		uint8x8_t h = vqrshrun_n_s16(tap6v(Rw[j], Rw[j + 1], Rw[j + 2], Rw[j + 3], Rw[j + 4], Rw[j + 5]), 5);
		out[j] = vrhadd_u8(b, fx == 1 ? vext_u8(h, h, 2) : vext_u8(h, h, 3));
	}
}

/* chroma_pred() for a 2x2 block of both planes: lanes [U00 U01 U10 U11 V00 V01 V10 V11] */
static uint8x8_t mc_chroma2_neon(const uint8_t *PU, const uint8_t *PV, int xc, int yc, int mvx, int mvy)
{
	int xi = xc + (mvx >> 3), yi = yc + (mvy >> 3), fx = mvx & 7, fy = mvy & 7, CW = W / 2;
	if (xi < 0 || yi < 0 || xi + 8 > CW || yi + 2 > H / 2 - 1) {   /* edges, or an 8-byte load would leave the row */
		uint8_t b[8];
		for (int k = 0; k < 4; k++) {
			b[k] = (uint8_t)chroma_pred(PU, xc + (k & 1), yc + (k >> 1), mvx, mvy);
			b[4 + k] = (uint8_t)chroma_pred(PV, xc + (k & 1), yc + (k >> 1), mvx, mvy);
		}
		return vld1_u8(b);
	}
	const uint8_t *u = PU + (size_t)yi * CW + xi, *v = PV + (size_t)yi * CW + xi;
	uint8x8_t u0 = vld1_u8(u), u1 = vld1_u8(u + CW), u2 = vld1_u8(u + 2 * CW);
	uint8x8_t v0 = vld1_u8(v), v1 = vld1_u8(v + CW), v2 = vld1_u8(v + 2 * CW);
#define ZIP16(a, b) vreinterpret_u8_u16(vzip1_u16(vreinterpret_u16_u8(a), vreinterpret_u16_u8(b)))
#define PACK(a, b) vreinterpret_u8_u32(vzip1_u32(vreinterpret_u32_u8(a), vreinterpret_u32_u8(b)))
	/* A = [r0[0] r0[1] r1[0] r1[1]], B = the same one column right; C, D one row down */
	uint8x8_t A = PACK(ZIP16(u0, u1), ZIP16(v0, v1));
	uint8x8_t Bv = PACK(ZIP16(vext_u8(u0, u0, 1), vext_u8(u1, u1, 1)), ZIP16(vext_u8(v0, v0, 1), vext_u8(v1, v1, 1)));
	uint8x8_t C = PACK(ZIP16(u1, u2), ZIP16(v1, v2));
	uint8x8_t D = PACK(ZIP16(vext_u8(u1, u1, 1), vext_u8(u2, u2, 1)), ZIP16(vext_u8(v1, v1, 1), vext_u8(v2, v2, 1)));
#undef ZIP16
#undef PACK
	uint16x8_t acc = vmull_u8(A, vdup_n_u8((uint8_t)((8 - fx) * (8 - fy))));
	acc = vmlal_u8(acc, Bv, vdup_n_u8((uint8_t)(fx * (8 - fy))));
	acc = vmlal_u8(acc, C, vdup_n_u8((uint8_t)((8 - fx) * fy)));
	acc = vmlal_u8(acc, D, vdup_n_u8((uint8_t)(fx * fy)));
	return vrshrn_n_u16(acc, 6);
}

/* explicit WP with logWD 6 on 8 samples: clip(((v * w + 32) >> 6) + o) */
static inline uint8x8_t wp6_neon(uint8x8_t v, int w, int o)
{
	int16x8_t t = vreinterpretq_s16_u16(vmull_u8(v, vdup_n_u8((uint8_t)w)));
	t = vrshrq_n_s16(t, 6);
	return vqmovun_s16(vaddq_s16(t, vdupq_n_s16((int16_t)o)));
}
static inline float32x4_t u8lo_f32(uint8x8_t v)   /* lanes 0..3 as float */
{
	return vcvtq_f32_u32(vmovl_u16(vget_low_u16(vmovl_u8(v))));
}
static inline float32x4_t u8hi_f32(uint8x8_t v)   /* lanes 4..7 as float */
{
	return vcvtq_f32_u32(vmovl_u16(vget_high_u16(vmovl_u8(v))));
}

static void aa_mb_neon(int mb, uint8_t pcm[384])
{
	int X0 = (mb % WMB) * 16, Y0 = (mb / WMB) * 16, cand[6], ce[6][4], nce[6];
	int nc = aa_faces(X0, Y0, cand, ce, nce);
	static float cov[6][256] __attribute__((aligned(16)));
	float sum[256] __attribute__((aligned(16))), Ya[256] __attribute__((aligned(16)));
	float Ua[64] __attribute__((aligned(16))), Va[64] __attribute__((aligned(16)));
	const float32x4_t zero = vdupq_n_f32(0), one = vdupq_n_f32(1), half = vdupq_n_f32(0.5f);
	float32x4_t px[4];
	for (int k = 0; k < 4; k++) {
		float t[4] = {(float)(X0 + 4 * k) + 0.5f, (float)(X0 + 4 * k + 1) + 0.5f, (float)(X0 + 4 * k + 2) + 0.5f, (float)(X0 + 4 * k + 3) + 0.5f};
		px[k] = vld1q_f32(t);
	}
	for (int i = 0; i < 256; i += 4) vst1q_f32(sum + i, zero);
	/* coverage: per face, the product of its crossing edges' clamped ramps */
	for (int c = 0; c < nc; c++) {
		const VFace *v = &g_vf[cand[c]];
		float *cv = cov[c];
		int ne = nce[c];
		float32x4_t apx[4][4], cc[4], sc[4];   /* per crossing edge: a * px (row-invariant), c, s */
		float bb[4];
		for (int q = 0; q < ne; q++) {
			int e = ce[c][q];
			for (int k = 0; k < 4; k++) apx[q][k] = vmulq_f32(vdupq_n_f32(v->a[e]), px[k]);
			cc[q] = vdupq_n_f32(v->c[e]);
			sc[q] = vdupq_n_f32(v->s[e]);
			bb[q] = v->b[e];
		}
		for (int y = 0; y < 16; y++) {
			float pyf = (float)(Y0 + y) + 0.5f;
			float32x4_t p0 = one, p1 = one, p2 = one, p3 = one;   /* 1 * t0 * t1 ...: the C order */
			for (int q = 0; q < ne; q++) {
				float32x4_t bpy = vdupq_n_f32(bb[q] * pyf);
#define RAMP(k) vminq_f32(vmaxq_f32(vaddq_f32(half, vmulq_f32(vaddq_f32(vaddq_f32(apx[q][k], bpy), cc[q]), sc[q])), zero), one)
				p0 = vmulq_f32(p0, RAMP(0));
				p1 = vmulq_f32(p1, RAMP(1));
				p2 = vmulq_f32(p2, RAMP(2));
				p3 = vmulq_f32(p3, RAMP(3));
#undef RAMP
			}
			float *d = cv + y * 16, *sm = sum + y * 16;
			vst1q_f32(d, p0); vst1q_f32(d + 4, p1); vst1q_f32(d + 8, p2); vst1q_f32(d + 12, p3);
			vst1q_f32(sm, vaddq_f32(vld1q_f32(sm), p0));
			vst1q_f32(sm + 4, vaddq_f32(vld1q_f32(sm + 4), p1));
			vst1q_f32(sm + 8, vaddq_f32(vld1q_f32(sm + 8), p2));
			vst1q_f32(sm + 12, vaddq_f32(vld1q_f32(sm + 12), p3));
		}
	}
	/* where the faces overlap past full coverage, normalise */
	for (int i = 0; i < 256; i += 4) {
		float32x4_t s4 = vld1q_f32(sum + i);
		uint32x4_t over = vcgtq_f32(s4, one);
		if (vmaxvq_u32(over)) {
			for (int c = 0; c < nc; c++) {
				float32x4_t cv = vld1q_f32(cov[c] + i);
				vst1q_f32(cov[c] + i, vbslq_f32(over, vdivq_f32(cv, s4), cv));
			}
			vst1q_f32(sum + i, vbslq_f32(over, one, s4));
		}
		vst1q_f32(Ya + i, zero);
	}
	for (int i = 0; i < 64; i += 4) {
		vst1q_f32(Ua + i, zero);
		vst1q_f32(Va + i, zero);
	}
	for (int q = 0; q < 16; q++) {
		int bx = X0 + (q & 3) * 4, by = Y0 + (q >> 2) * 4, o = (q >> 2) * 64 + (q & 3) * 4;
		for (int c = 0; c < nc; c++) {
			const float *cv = cov[c] + o;
			float32x4_t r0 = vld1q_f32(cv), r1 = vld1q_f32(cv + 16), r2 = vld1q_f32(cv + 32), r3 = vld1q_f32(cv + 48);
			float mx = vmaxvq_f32(vmaxq_f32(vmaxq_f32(r0, r1), vmaxq_f32(r2, r3)));
			if (mx * 255 < 0.5f) continue;   /* contributes under half an LSB */
			const VFace *v = &g_vf[cand[c]];
			int k, mvx, mvy, w = (int)lrintf(v->light * 64);
			face_block_mv(v, bx + 2.0f, by + 2.0f, &k, &mvx, &mvy);
			uint8x8_t pr[4];
			mc_luma4_neon(PGY[1 + k], bx, by, mvx, mvy, pr);
			/* luma: Ya += cov * wp(pred) */
			uint8x8_t w01 = wp6_neon(vreinterpret_u8_u32(vzip1_u32(vreinterpret_u32_u8(pr[0]), vreinterpret_u32_u8(pr[1]))), w, 0);
			uint8x8_t w23 = wp6_neon(vreinterpret_u8_u32(vzip1_u32(vreinterpret_u32_u8(pr[2]), vreinterpret_u32_u8(pr[3]))), w, 0);
			float *ya = Ya + o;
			vst1q_f32(ya, vaddq_f32(vld1q_f32(ya), vmulq_f32(r0, u8lo_f32(w01))));
			vst1q_f32(ya + 16, vaddq_f32(vld1q_f32(ya + 16), vmulq_f32(r1, u8hi_f32(w01))));
			vst1q_f32(ya + 32, vaddq_f32(vld1q_f32(ya + 32), vmulq_f32(r2, u8lo_f32(w23))));
			vst1q_f32(ya + 48, vaddq_f32(vld1q_f32(ya + 48), vmulq_f32(r3, u8hi_f32(w23))));
			/* chroma: 2x2 coverage means, in the C order ((a + b) + c) + d */
			float32x2_t e1 = vget_low_f32(vuzp1q_f32(r1, r1)), o1 = vget_low_f32(vuzp2q_f32(r1, r1));
			float32x2_t e3 = vget_low_f32(vuzp1q_f32(r3, r3)), o3 = vget_low_f32(vuzp2q_f32(r3, r3));
			float32x2_t c0 = vadd_f32(vadd_f32(vpadd_f32(vget_low_f32(r0), vget_high_f32(r0)), e1), o1);
			float32x2_t c1 = vadd_f32(vadd_f32(vpadd_f32(vget_low_f32(r2), vget_high_f32(r2)), e3), o3);
			float32x4_t ccv = vmulq_n_f32(vcombine_f32(c0, c1), 0.25f);
			uint8x8_t ch = wp6_neon(mc_chroma2_neon(PGU[1 + k], PGV[1 + k], bx / 2, by / 2, mvx, mvy), w, 128 - 2 * w);
			float32x4_t uu = vmulq_f32(ccv, u8lo_f32(ch)), vv = vmulq_f32(ccv, u8hi_f32(ch));
			int ci = (by / 2 - Y0 / 2) * 8 + (bx / 2 - X0 / 2);
			vst1_f32(Ua + ci, vadd_f32(vld1_f32(Ua + ci), vget_low_f32(uu)));
			vst1_f32(Ua + ci + 8, vadd_f32(vld1_f32(Ua + ci + 8), vget_high_f32(uu)));
			vst1_f32(Va + ci, vadd_f32(vld1_f32(Va + ci), vget_low_f32(vv)));
			vst1_f32(Va + ci + 8, vadd_f32(vld1_f32(Va + ci + 8), vget_high_f32(vv)));
		}
	}
	/* to bytes: y = Ya + 0.5 truncated, chroma over the background (128) */
	for (int i = 0; i < 256; i += 16) {
		uint32x4_t a = vcvtq_u32_f32(vaddq_f32(vld1q_f32(Ya + i), half)), b = vcvtq_u32_f32(vaddq_f32(vld1q_f32(Ya + i + 4), half));
		uint32x4_t c = vcvtq_u32_f32(vaddq_f32(vld1q_f32(Ya + i + 8), half)), d = vcvtq_u32_f32(vaddq_f32(vld1q_f32(Ya + i + 12), half));
		uint16x8_t ab = vcombine_u16(vqmovn_u32(a), vqmovn_u32(b)), cd = vcombine_u16(vqmovn_u32(c), vqmovn_u32(d));
		vst1q_u8(pcm + i, vcombine_u8(vqmovn_u16(ab), vqmovn_u16(cd)));
	}
	const float32x4_t f128 = vdupq_n_f32(128);
	for (int j = 0; j < 8; j++) {
		const float *s0 = sum + 32 * j, *s1 = s0 + 16;
		float32x4_t p0 = vpaddq_f32(vld1q_f32(s0), vld1q_f32(s0 + 4)), p1 = vpaddq_f32(vld1q_f32(s0 + 8), vld1q_f32(s0 + 12));
		float32x4_t q0 = vld1q_f32(s1), q1 = vld1q_f32(s1 + 4), q2 = vld1q_f32(s1 + 8), q3 = vld1q_f32(s1 + 12);
		float32x4_t m0 = vaddq_f32(vaddq_f32(p0, vuzp1q_f32(q0, q1)), vuzp2q_f32(q0, q1));
		float32x4_t m1 = vaddq_f32(vaddq_f32(p1, vuzp1q_f32(q2, q3)), vuzp2q_f32(q2, q3));
		float32x4_t bg0 = vsubq_f32(one, vmulq_n_f32(m0, 0.25f)), bg1 = vsubq_f32(one, vmulq_n_f32(m1, 0.25f));
		float32x4_t u0 = vaddq_f32(vaddq_f32(vld1q_f32(Ua + 8 * j), vmulq_f32(bg0, f128)), half);
		float32x4_t u1 = vaddq_f32(vaddq_f32(vld1q_f32(Ua + 8 * j + 4), vmulq_f32(bg1, f128)), half);
		float32x4_t v0 = vaddq_f32(vaddq_f32(vld1q_f32(Va + 8 * j), vmulq_f32(bg0, f128)), half);
		float32x4_t v1 = vaddq_f32(vaddq_f32(vld1q_f32(Va + 8 * j + 4), vmulq_f32(bg1, f128)), half);
		uint16x8_t uu = vcombine_u16(vqmovn_u32(vcvtq_u32_f32(u0)), vqmovn_u32(vcvtq_u32_f32(u1)));
		uint16x8_t vv = vcombine_u16(vqmovn_u32(vcvtq_u32_f32(v0)), vqmovn_u32(vcvtq_u32_f32(v1)));
		vst1_u8(pcm + 256 + 8 * j, vqmovn_u16(uu));
		vst1_u8(pcm + 320 + 8 * j, vqmovn_u16(vv));
	}
}

/* --mc-test on aarch64: the NEON 4x4 luma and 2x2 chroma MC against the C ones */
static long mc_test_neon(int n, const uint8_t *P, const uint8_t *PU, const uint8_t *PV)
{
	long bad = 0;
	for (int t = 0; t < n; t++) {
		int x = (int)(frand() * (W + 40)) - 20, y = (int)(frand() * (H + 40)) - 20;
		int mvx = (int)(frand() * 400) - 200, mvy = (int)(frand() * 400) - 200, ref[16];
		uint8x8_t out[4];
		uint8_t o8[8];
		mc_luma4_neon(P, x, y, mvx, mvy, out);
		mc_luma_block(P, x, y, 4, 4, mvx, mvy, ref);
		for (int j = 0; j < 4; j++) {
			vst1_u8(o8, out[j]);
			for (int i = 0; i < 4; i++) bad += o8[i] != ref[j * 4 + i];
		}
		int xc = x / 2, yc = y / 2;
		vst1_u8(o8, mc_chroma2_neon(PU, PV, xc, yc, mvx, mvy));
		for (int k = 0; k < 4; k++) {
			bad += o8[k] != chroma_pred(PU, xc + (k & 1), yc + (k >> 1), mvx, mvy);
			bad += o8[4 + k] != chroma_pred(PV, xc + (k & 1), yc + (k >> 1), mvx, mvy);
		}
		int ww = 1 + (int)(frand() * 126), oo = (int)(frand() * 256) - 128;
		uint8x8_t wv = wp6_neon(out[0], ww, oo);
		vst1_u8(o8, wv);
		uint8_t i8[8];
		vst1_u8(i8, out[0]);
		for (int i = 0; i < 8; i++) bad += o8[i] != wp6(i8[i], ww, oo);
	}
	return bad;
}
#endif

static void aa_mb(int mb, uint8_t pcm[384])
{
#if defined(__aarch64__)
	if (g_neon) {
		aa_mb_neon(mb, pcm);
		return;
	}
#endif
	aa_mb_c(mb, pcm);
}

/*
 * The I_PCM hook. Called for every macroblock the cube touches, after
 * visibility (face16: the face of each of its 16 4x4 blocks, -1 = background).
 * Return true and fill pcm (256 Y, 64 Cb, 64 Cr, raster order) to emit the
 * macroblock as I_PCM with these pixels instead of motion vectors: the place
 * for CPU-rendered anti-aliased silhouettes. Stub: never, except --pcm-test,
 * which sends every partly covered macroblock as a test pattern, and --aa
 * (arm A), which sends every edge MB (find_edges) anti-aliased (aa_mb).
 */
static bool edge_mb_pcm(const Frame *F, int mb, const int *face16, int nblk, uint8_t pcm[384])
{
	(void)F;
	if (g_aa) {
		if (!g_edge[mb])
			return false;
		struct timespec t0, t1;
		clock_gettime(CLOCK_MONOTONIC, &t0);
		aa_mb(mb, pcm);
		clock_gettime(CLOCK_MONOTONIC, &t1);
		g_t_aa += (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) * 1e-9;
		return true;
	}
	if (!g_pcm_test)
		return false;
	int cov = 0;
	for (int q = 0; q < nblk; q++)
		cov += face16[q] >= 0;
	if (cov == 0 || cov == nblk)
		return false;
	/* test pattern; py/check.py paints the same */
	for (int y = 0; y < 16; y++)
		for (int x = 0; x < 16; x++)
			pcm[y * 16 + x] = (uint8_t)(((x + y) * 8 + mb) & 255);
	memset(pcm + 256, 64, 64);
	memset(pcm + 320, 192, 64);
	return true;
}

static int WY[MAXREF], OY[MAXREF], WC[MAXREF], OC[MAXREF];
static const int LWD = 6;
static int g_npcm;   /* I_PCM macroblocks in the last frame */

static inline void bw_te(BW *b, int r) { if (NREF == 2) bw_u(b, 1, (uint32_t)!r); else if (NREF > 2) bw_ue(b, (uint32_t)r); }
static int circd(int a, int b) { int d = abs(a - b) % K; return d < K - d ? d : K - d; }

/* encodes one frame's slice into b; appends partitions to parts (if non-NULL) */
static void encode_frame(const Frame *F, int frame_num, int poc, int is_ref, BW *b, Part *parts, int *nparts) {
    static int bface[MAXMB * 16], bk[MAXMB * 16]; static float btu[MAXMB * 16], btv[MAXMB * 16];
    int nb_ = PART == 4 ? 16 : PART == 8 ? 4 : 1, bs = PART;
    /* pass 1: visibility + preferred (face, page) per block */
    int hist[6][64]; memset(hist, 0, sizeof hist);
    for (int m = 0; m < WMB * HMB; m++) {
        int mx = m % WMB, my = m / WMB;
        if (!F->nlist[m]) {                   /* nothing binned: all background */
            for (int q = 0; q < nb_; q++) bface[m * 16 + q] = -1;
            continue;
        }
        for (int q = 0; q < nb_; q++) {
            int bx, by;
            if (PART == 4) { bx = mx * 16 + ((q >> 2) & 1) * 8 + (q & 1) * 4; by = my * 16 + ((q >> 2) >> 1) * 8 + ((q >> 1) & 1) * 4; }
            else if (PART == 8) { bx = mx * 16 + (q & 1) * 8; by = my * 16 + (q >> 1) * 8; }
            else { bx = mx * 16; by = my * 16; }
            int i = m * 16 + q;
            bface[i] = block_hit(F, m, bx + bs * 0.5f, by + bs * 0.5f, &btu[i], &btv[i], &bk[i]);
            if (bface[i] >= 0) hist[bface[i]][bk[i]]++;
        }
    }
    /* reference list: [0] black page, then the most used (face, page) pairs */
    NREF = 1; REFPAGE[0] = 0; REFFACE[0] = -1; REFK[0] = -1;
    int ent[6][64]; memset(ent, -1, sizeof ent);
    for (;;) {
        int bf = -1, bkk = -1, bc = 0;
        for (int f = 0; f < 6; f++) for (int k = 0; k < K; k++) if (ent[f][k] < 0 && hist[f][k] > bc) { bc = hist[f][k]; bf = f; bkk = k; }
        if (bf < 0 || NREF == MAXREF) break;
        ent[bf][bkk] = NREF; REFPAGE[NREF] = 1 + bkk; REFFACE[NREF] = bf; REFK[NREF] = bkk; NREF++;
    }
    for (int m = 0; m < WMB * HMB; m++) if (F->nlist[m]) for (int i = m * 16; i < m * 16 + nb_; i++) if (bface[i] >= 0 && ent[bface[i]][bk[i]] < 0) {
        int f = bface[i], best = -1;          /* entry budget exhausted: nearest available page for this face */
        for (int k = 0; k < K; k++) if (ent[f][k] >= 0 && (best < 0 || circd(k, bk[i]) < circd(best, bk[i]))) best = k;
        bk[i] = best;
    }
    for (int i = 1; i < NREF; i++) {
        int w = (int)lrintf(F->light[REFFACE[i]] * 64);
        WY[i] = w; OY[i] = 0; WC[i] = w; OC[i] = 128 - 2 * w;
    }
    /* slice header */
    bw_ue(b, 0); bw_ue(b, 5); bw_ue(b, 0);
    bw_u(b, 16, (uint32_t)frame_num & 0xffff);   /* 1 + K (the pages before) for a non-reference render */
    bw_u(b, 16, (uint32_t)poc & 0xffff);
    bw_u(b, 1, 1); bw_ue(b, (uint32_t)(NREF - 1));
    bw_u(b, 1, 1);
    for (int i = 0; i < NREF; i++) { bw_ue(b, 2); bw_ue(b, (uint32_t)REFPAGE[i]); }
    bw_ue(b, 3);
    bw_ue(b, LWD); bw_ue(b, LWD);
    bw_u(b, 1, 0); bw_u(b, 1, 0);
    for (int i = 1; i < NREF; i++) {
        bw_u(b, 1, 1); bw_se(b, WY[i]); bw_se(b, OY[i]);
        bw_u(b, 1, 1); bw_se(b, WC[i]); bw_se(b, OC[i]); bw_se(b, WC[i]); bw_se(b, OC[i]);
    }
    if (is_ref) bw_u(b, 1, 0);             /* dec_ref_pic_marking: sliding window */
    bw_se(b, g_qp - 26);
    if (g_dbk) { bw_ue(b, 0); bw_se(b, g_abo); bw_se(b, g_abo); }
    else bw_ue(b, 1);
    memset(sdone, 0, (size_t)W4 * H4);
    int skip = 0, np = 0;
    g_npcm = 0;
    for (int my = 0; my < HMB; my++) for (int mx = 0; mx < WMB; mx++) {
        int m = my * WMB + mx, x4 = mx * 4, y4 = my * 4, *fa = &bface[m * 16], any = 0;
        int mvx[16], mvy[16];
        uint8_t pcm[384];
        if (F->nlist[m]) for (int q = 0; q < nb_; q++) any |= fa[q] >= 0;
        if ((g_aa || any) && edge_mb_pcm(F, m, fa, nb_, pcm)) {
            bw_ue(b, skip); skip = 0;
            bw_ue(b, 30);                       /* P slice: mb_type 5 + 25 = I_PCM */
            if (b->n) bw_u(b, 8 - b->n, 0);     /* pcm_alignment_zero_bit */
            memcpy(b->buf + b->len, pcm, sizeof pcm);   /* byte aligned: acc is empty */
            b->len += sizeof pcm;
            if (g_pcmstore) memcpy(g_pcmstore + (size_t)m * 384, pcm, sizeof pcm);
            setmb(x4, y4, -1, 0, 0);     /* intra: available, refIdx -1, MV 0 */
            if (parts) parts[np++] = (Part){(int16_t)(mx*16), (int16_t)(my*16), 16, 16, -1, 0, 0};
            g_npcm++;
            continue;
        }
        if (!any) {
            int px, py; pskip_mv(x4, y4, &px, &py);
            if (!px && !py) { skip++; setmb(x4, y4, 0, 0, 0); }
            else {
                bw_ue(b, skip); skip = 0; bw_ue(b, 0); bw_te(b, 0);
                mvp(x4, y4, 4, 0, &px, &py); bw_se(b, -px); bw_se(b, -py); bw_ue(b, 0);
                setmb(x4, y4, 0, 0, 0);
            }
            if (parts) parts[np++] = (Part){(int16_t)(mx*16), (int16_t)(my*16), 16, 16, 0, 0, 0};
            continue;
        }
        bw_ue(b, skip); skip = 0;
        if (PART == 16) {
            int i = m * 16, r = ent[fa[0]][bk[i]], px, py;
            mv_for(fa[0], bk[i], btu[i], btv[i], mx * 16 + 8.0f, my * 16 + 8.0f, 16, &mvx[0], &mvy[0]);
            bw_ue(b, 0); bw_te(b, r);
            mvp(x4, y4, 4, r, &px, &py); bw_se(b, mvx[0] - px); bw_se(b, mvy[0] - py);
            setmb(x4, y4, r, mvx[0], mvy[0]);
            if (parts) parts[np++] = (Part){(int16_t)(mx*16), (int16_t)(my*16), 16, 16, (int16_t)r, (int16_t)mvx[0], (int16_t)mvy[0]};
            bw_ue(b, 0); continue;
        }
        bw_ue(b, 3);
        int ref[4], sub[4];
        for (int p = 0; p < 4; p++) {
            if (PART == 8) {
                int i = m * 16 + p; sub[p] = 0;
                if (fa[p] < 0) { ref[p] = 0; mvx[p] = mvy[p] = 0; continue; }
                ref[p] = ent[fa[p]][bk[i]];
                mv_for(fa[p], bk[i], btu[i], btv[i], mx * 16 + (p & 1) * 8 + 4.0f, my * 16 + (p >> 1) * 8 + 4.0f, 8, &mvx[p], &mvy[p]);
                continue;
            }
            int cnt[MAXREF] = {0}, nf = 0, br = -1;
            for (int s2 = 0; s2 < 4; s2++) { int i = m * 16 + p * 4 + s2; if (fa[p * 4 + s2] >= 0) { cnt[ent[fa[p*4+s2]][bk[i]]]++; nf++; } }
            if (!nf) { ref[p] = 0; sub[p] = 0; mvx[p * 4] = mvy[p * 4] = 0; continue; }
            for (int r = 1; r < NREF; r++) if (cnt[r] && (br < 0 || cnt[r] > cnt[br])) br = r;
            ref[p] = br; sub[p] = 3;
            for (int s2 = 0; s2 < 4; s2++) {
                int q = p * 4 + s2, i = m * 16 + q;
                int bx = mx * 16 + (p & 1) * 8 + (s2 & 1) * 4, by = my * 16 + (p >> 1) * 8 + (s2 >> 1) * 4;
                if (fa[q] < 0) { mvx[q] = 4 * (BLACKX - bx); mvy[q] = 4 * (BLACKY - by); continue; }
                /* the 8x8 reads page REFK[br]: this block's own face, at that page's angle */
                mv_for(fa[q], REFK[br], btu[i], btv[i], bx + 2.0f, by + 2.0f, 4, &mvx[q], &mvy[q]);
            }
        }
        for (int p = 0; p < 4; p++) bw_ue(b, (uint32_t)sub[p]);
        for (int p = 0; p < 4; p++) bw_te(b, ref[p]);
        for (int p = 0; p < 4; p++) {
            int bx = x4 + (p & 1) * 2, by = y4 + (p >> 1) * 2, px, py;
            if (sub[p] == 0) {
                int vx = PART == 8 ? mvx[p] : mvx[p * 4], vy = PART == 8 ? mvy[p] : mvy[p * 4];
                mvp(bx, by, 2, ref[p], &px, &py); bw_se(b, vx - px); bw_se(b, vy - py);
                setblk(bx, by, 2, 2, ref[p], vx, vy);
                if (parts) parts[np++] = (Part){(int16_t)(bx*4), (int16_t)(by*4), 8, 8, (int16_t)ref[p], (int16_t)vx, (int16_t)vy};
            } else {
                for (int s2 = 0; s2 < 4; s2++) {
                    int sx = bx + (s2 & 1), sy = by + (s2 >> 1), q = p * 4 + s2;
                    mvp(sx, sy, 1, ref[p], &px, &py); bw_se(b, mvx[q] - px); bw_se(b, mvy[q] - py);
                    setblk(sx, sy, 1, 1, ref[p], mvx[q], mvy[q]);
                    if (parts) parts[np++] = (Part){(int16_t)(sx*4), (int16_t)(sy*4), 4, 4, (int16_t)ref[p], (int16_t)mvx[q], (int16_t)mvy[q]};
                }
            }
        }
        bw_ue(b, 0);
    }
    if (skip) bw_ue(b, skip);
    bw_trailing(b);
    if (nparts) *nparts = np;
}

/*
 * Arm C: a B-picture whose two lists both hold the previous reference picture
 * (the render). Edge MBs are B_Bi_16x16 with L0 MV (m0x, m0y) and L1 MV
 * (m1x, m1y) in quarter samples, default (unweighted) averaging; every other
 * MB is B_L0_16x16 with MV 0, a copy. No B_Skip: that would be direct mode.
 */
static int8_t *bref1; static int16_t (*bmv1)[2];   /* L1 neighbour state; L0 uses sref/smv */
static size_t encode_bpic(uint8_t *rbsp, int frame_num, int poc, int is_ref, int m0x, int m0y, int m1x, int m1y)
{
	BW bb = {rbsp, 0, 0, 0}, *b = &bb;
	int8_t *r0 = sref;
	int16_t (*v0)[2] = smv;
	bw_ue(b, 0); bw_ue(b, 6); bw_ue(b, 0);
	bw_u(b, 16, (uint32_t)frame_num & 0xffff);
	bw_u(b, 16, (uint32_t)poc & 0xffff);
	bw_u(b, 1, 1);                          /* direct_spatial_mv_pred_flag (no direct MBs) */
	bw_u(b, 1, 1); bw_ue(b, 0); bw_ue(b, 0);  /* one active entry per list */
	for (int l = 0; l < 2; l++) {           /* both: the previous reference picture, abs_diff_pic_num 1 */
		bw_u(b, 1, 1); bw_ue(b, 0); bw_ue(b, 0); bw_ue(b, 3);
	}
	if (is_ref) bw_u(b, 1, 0);             /* sliding window */
	bw_se(b, 0); bw_ue(b, 1);               /* QP 26, no loop filter */
	memset(sdone, 0, (size_t)W4 * H4);
	for (int my = 0; my < HMB; my++)
		for (int mx = 0; mx < WMB; mx++) {
			int m = my * WMB + mx, x4 = mx * 4, y4 = my * 4, px, py, bi = g_edge[m];
			int ax = bi ? m0x : 0, ay = bi ? m0y : 0;
			bw_ue(b, 0);                    /* mb_skip_run */
			bw_ue(b, bi ? 3 : 1);           /* B_Bi_16x16 : B_L0_16x16 */
			sref = r0; smv = v0;
			mvp(x4, y4, 4, 0, &px, &py);
			bw_se(b, ax - px); bw_se(b, ay - py);
			if (bi) {
				sref = bref1; smv = bmv1;
				mvp(x4, y4, 4, 0, &px, &py);
				bw_se(b, m1x - px); bw_se(b, m1y - py);
			}
			bw_ue(b, 0);                    /* coded_block_pattern 0 */
			sref = r0; smv = v0;
			setmb(x4, y4, 0, ax, ay);
			sref = bref1; smv = bmv1;
			setmb(x4, y4, bi ? 0 : -1, bi ? m1x : 0, bi ? m1y : 0);
		}
	sref = r0; smv = v0;
	bw_trailing(b);
	return bb.len;
}

/* ------------------------------------------------------------ headers + pages (mcr.c) */
static size_t sps_pps(uint8_t *out) {
    uint8_t r[64]; BW b = {r, 0, 0, 0}; size_t o = 0;
    bw_u(&b, 8, 77); bw_u(&b, 8, 0); bw_u(&b, 8, 30); bw_ue(&b, 0);
    bw_ue(&b, 12); bw_ue(&b, 0); bw_ue(&b, 12);      /* log2 frame_num 16, poc type 0, log2 poc lsb 16 */
    /* max_num_ref_frames: the pages, + the render (+ the H pass) as short-term refs, + spare
     * frame buffers (the firmware allocates max_num_ref_frames + 2). Every reference is picked
     * explicitly, so spares change no prediction; with --smooth, the sliding window keeps
     * older renders in them. */
    bw_ue(&b, (uint32_t)(1 + K + g_smooth + g_dpb_extra)); bw_u(&b, 1, 0); bw_ue(&b, WMB - 1); bw_ue(&b, HMB - 1);
    bw_u(&b, 1, 1); bw_u(&b, 1, 1); bw_u(&b, 1, 0); bw_u(&b, 1, 0); bw_trailing(&b);
    o += nal_wrap(out + o, 3, 7, r, b.len);
    b.len = 0; b.n = 0; b.acc = 0;
    bw_ue(&b, 0); bw_ue(&b, 0); bw_u(&b, 1, 0); bw_u(&b, 1, 0); bw_ue(&b, 0); bw_ue(&b, 0); bw_ue(&b, 0);
    bw_u(&b, 1, 1); bw_u(&b, 2, 0); bw_se(&b, 0); bw_se(&b, 0); bw_se(&b, 0);
    bw_u(&b, 1, 1); bw_u(&b, 1, 0); bw_u(&b, 1, 0); bw_trailing(&b);
    o += nal_wrap(out + o, 3, 8, r, b.len);
    return o;
}
/* page k: 0 = the black IDR (long-term 0), 1..K = atlas pages (long-term k) */
static size_t pcm_page(uint8_t *out, uint8_t *rbsp, const uint8_t *Y, const uint8_t *U, const uint8_t *V, int k) {
    BW b = {rbsp, 0, 0, 0};
    int idr = k == 0;
    bw_ue(&b, 0); bw_ue(&b, 7); bw_ue(&b, 0); bw_u(&b, 16, (uint32_t)k);
    if (idr) bw_ue(&b, 0);
    bw_u(&b, 16, (uint32_t)(2 * k));
    if (idr) { bw_u(&b, 1, 0); bw_u(&b, 1, 1); }                     /* long_term_reference_flag */
    else {
        bw_u(&b, 1, 1);
        if (k == 1) { bw_ue(&b, 4); bw_ue(&b, (uint32_t)(K + 1)); }   /* MaxLongTermFrameIdx = K */
        bw_ue(&b, 6); bw_ue(&b, (uint32_t)k); bw_ue(&b, 0);
    }
    bw_se(&b, 0); bw_ue(&b, 1);
    for (int my = 0; my < HMB; my++) for (int mx = 0; mx < WMB; mx++) {
        bw_ue(&b, 25); if (b.n) bw_u(&b, 8 - b.n, 0);
        for (int y = 0; y < 16; y++) { memcpy(b.buf + b.len, Y + (size_t)(my*16+y)*W + mx*16, 16); b.len += 16; }
        for (int y = 0; y < 8; y++) { memcpy(b.buf + b.len, U + (size_t)(my*8+y)*(W/2) + mx*8, 8); b.len += 8; }
        for (int y = 0; y < 8; y++) { memcpy(b.buf + b.len, V + (size_t)(my*8+y)*(W/2) + mx*8, 8); b.len += 8; }
    }
    bw_trailing(&b);
    return nal_wrap(out, 3, idr ? 5 : 1, rbsp, b.len);
}

/* ------------------------------------------------------------ textures + atlas
 * Built-in textures: the reference model's six, with its numpy RNG, PIL font
 * and scipy blur replaced by small C stand-ins, and the NixOS pride logomark
 * instead of the smooth gradient (face 3). --tex-in loads six TxT RGB textures
 * instead. */
static double nrand(void) { double u = frand() + 1e-12, v = frand(); return sqrt(-2 * log(u)) * cos(6.283185307179586 * v); }

/* smooth value noise: an (n+1)^2 grid of normal samples, smoothstep-interpolated */
static void value_noise(int T_, int n, double *out)
{
	double *g = malloc(sizeof(double) * (size_t)(n + 1) * (n + 1));
	for (int i = 0; i < (n + 1) * (n + 1); i++)
		g[i] = nrand();
	for (int y = 0; y < T_; y++)
		for (int x = 0; x < T_; x++) {
			double fx = (x + 0.5) * n / T_, fy = (y + 0.5) * n / T_;
			int ix = (int)fx, iy = (int)fy;
			double ax = fx - ix, ay = fy - iy;
			ax = ax * ax * (3 - 2 * ax);
			ay = ay * ay * (3 - 2 * ay);
			double a = g[iy * (n + 1) + ix], b = g[iy * (n + 1) + ix + 1];
			double c = g[(iy + 1) * (n + 1) + ix], d = g[(iy + 1) * (n + 1) + ix + 1];
			out[y * T_ + x] = (a * (1 - ax) + b * ax) * (1 - ay) + (c * (1 - ax) + d * ax) * ay;
		}
	free(g);
}

static const struct { char c; uint8_t rows[8]; } GLYPHS[] = {
	{'.', {0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x0C, 0x00}},
	{'0', {0x3E, 0x63, 0x73, 0x7B, 0x6F, 0x67, 0x3E, 0x00}},
	{'2', {0x1E, 0x33, 0x30, 0x1C, 0x06, 0x33, 0x3F, 0x00}},
	{'4', {0x38, 0x3C, 0x36, 0x33, 0x7F, 0x30, 0x78, 0x00}},
	{'6', {0x1C, 0x06, 0x03, 0x1F, 0x33, 0x33, 0x1E, 0x00}},
	{'8', {0x1E, 0x33, 0x33, 0x1E, 0x33, 0x33, 0x1E, 0x00}},
	{'9', {0x1E, 0x33, 0x33, 0x3E, 0x30, 0x18, 0x0E, 0x00}},
	{'A', {0x0C, 0x1E, 0x33, 0x33, 0x3F, 0x33, 0x33, 0x00}},
	{'C', {0x3C, 0x66, 0x03, 0x03, 0x03, 0x66, 0x3C, 0x00}},
	{'D', {0x1F, 0x36, 0x66, 0x66, 0x66, 0x36, 0x1F, 0x00}},
	{'H', {0x33, 0x33, 0x33, 0x3F, 0x33, 0x33, 0x33, 0x00}},
	{'O', {0x1C, 0x36, 0x63, 0x63, 0x63, 0x36, 0x1C, 0x00}},
};   /* font8x8_basic (Daniel Hepper, public domain): bit 0 = leftmost pixel */

static void put8(uint8_t *px, double r, double g, double b)
{
	double v[3] = {r, g, b};
	for (int c = 0; c < 3; c++)
		px[c] = (uint8_t)(v[c] < 0 ? 0 : v[c] > 255 ? 255 : v[c]);   /* numpy clip + astype: truncates */
}

/*
 * The NixOS logomark, rainbow gradient, minimal
 * (https://brand.nixos.org/logos/nixos-logomark-rainbow-gradient-minimal.svg,
 * NixOS artwork, CC-BY 4.0), rasterized here: six copies of one lambda
 * polygon, copy k rotated by 60k degrees, world = R(60k)(p - (320, -554.256)),
 * each filled with a 3-stop linear gradient in the polygon's own space.
 * 4x4 samples per texel, on a light background.
 */
static const double NIX_PTS[9][2] = {
	{-304.0, -304.8409421321224}, {-176.0, -526.5434455009388}, {384.0, 443.40500673763256},
	{128.0, 443.40500673763256}, {0.0, 221.70250336881628}, {-128.0, 443.40500673763245},
	{-256.0, 443.40500673763245}, {-320.0, 332.55375505322434}, {-128.0, 0.0}};
static const uint8_t NIX_STOPS[6][3][3] = {   /* at 0 %, 25 %, 100 % */
	{{0x9e, 0x00, 0x00}, {0xaf, 0x00, 0x00}, {0xc1, 0x01, 0x00}},
	{{0xdc, 0x55, 0x00}, {0xee, 0x5e, 0x00}, {0xff, 0x67, 0x05}},
	{{0xdb, 0x99, 0x17}, {0xec, 0xa4, 0x12}, {0xfd, 0xb0, 0x0b}},
	{{0x00, 0x7f, 0x2d}, {0x00, 0x8d, 0x34}, {0x02, 0x9b, 0x3b}},
	{{0x02, 0x70, 0xa8}, {0x00, 0x7c, 0xba}, {0x00, 0x88, 0xcc}},
	{{0x45, 0x23, 0x97}, {0x4f, 0x2d, 0xa8}, {0x5a, 0x37, 0xbb}}};

static void nixos_logo(int T_, uint8_t *rgb)
{
	const double scale = 2304.0 / (T_ * 0.88);   /* the six lambdas span +-1152 x +-998 around 0: 88 % of the face */
	const double g1x = -320.0, g1y = -554.2562584220408, gdx = 128.0 - g1x, gdy = 221.70250336881628 - g1y;
	const double bg[3] = {244, 244, 240};
	double ck[6], sk[6];
	for (int k = 0; k < 6; k++) {   /* world -> local: R(-60k), + c */
		ck[k] = cos(-k * M_PI / 3);
		sk[k] = sin(-k * M_PI / 3);
	}
	for (int y = 0; y < T_; y++)
		for (int x = 0; x < T_; x++) {
			double acc[3] = {0, 0, 0};
			for (int sy = 0; sy < 4; sy++)
				for (int sx = 0; sx < 4; sx++) {
					double wx = ((x + (sx + 0.5) / 4) - T_ / 2.0) * scale;
					double wy = ((y + (sy + 0.5) / 4) - T_ / 2.0) * scale;
					const double *col = bg;
					double c3[3];
					for (int k = 0; k < 6 && col == bg; k++) {
						double lx = ck[k] * wx - sk[k] * wy + 320.0, ly = sk[k] * wx + ck[k] * wy - 554.2562584220408;
						if (lx < -320 || lx > 384 || ly < -527 || ly > 444) continue;   /* the lambda's bbox */
						int in = 0;
						for (int i = 0, j = 8; i < 9; j = i++) {
							double xi = NIX_PTS[i][0], yi = NIX_PTS[i][1], xj = NIX_PTS[j][0], yj = NIX_PTS[j][1];
							if ((yi > ly) != (yj > ly) && lx < (xj - xi) * (ly - yi) / (yj - yi) + xi)
								in = !in;
						}
						if (!in) continue;
						double t = ((lx - g1x) * gdx + (ly - g1y) * gdy) / (gdx * gdx + gdy * gdy);
						t = t < 0 ? 0 : t > 1 ? 1 : t;
						const uint8_t *s0 = NIX_STOPS[k][t < 0.25 ? 0 : 1], *s1 = NIX_STOPS[k][t < 0.25 ? 1 : 2];
						double f = t < 0.25 ? t / 0.25 : (t - 0.25) / 0.75;
						for (int q = 0; q < 3; q++) c3[q] = s0[q] + (s1[q] - s0[q]) * f;
						col = c3;
					}
					for (int q = 0; q < 3; q++) acc[q] += col[q];
				}
			for (int q = 0; q < 3; q++) rgb[3 * ((size_t)y * T_ + x) + q] = (uint8_t)(acc[q] / 16 + 0.5);
		}
}

static void make_textures(int T_, uint8_t *tex)
{
	size_t tt = (size_t)T_ * T_;
	double *n1 = malloc(sizeof(double) * tt), *acc = calloc(tt, sizeof(double)), *tmp = malloc(sizeof(double) * tt);
	double var[9][6];
	for (int i = 0; i < 9; i++)
		for (int j = 0; j < 6; j++)
			var[i][j] = 0.8 + 0.35 * frand();
	value_noise(T_, 8, n1);
	for (size_t i = 0; i < tt; i++)
		n1[i] *= 0.6;
	for (int o = 0; o < 5; o++) {
		value_noise(T_, 4 << o, tmp);
		for (size_t i = 0; i < tt; i++)
			acc[i] += tmp[i] / pow(1.7, o);
	}
	double lo = 1e9, hi = -1e9;
	for (size_t i = 0; i < tt; i++) {
		if (acc[i] < lo) lo = acc[i];
		if (acc[i] > hi) hi = acc[i];
	}
	for (int y = 0; y < T_; y++)
		for (int x = 0; x < T_; x++) {
			double xx = (double)x / T_, yy = (double)y / T_;
			size_t i = (size_t)y * T_ + x;
			/* 0 checker */
			int c = ((int)floor(xx * 8) + (int)floor(yy * 8)) % 2;
			put8(tex + 3 * i, c ? 235 : 150, c ? 235 : 30, c ? 225 : 40);
			/* 1 bricks */
			double by = floor(yy * 8), off = fmod(by, 2) * 0.5, bx = floor(xx * 4 + off);
			int mort = fmod(yy * 8, 1) < 0.12 || fmod(xx * 4 + off, 1) < 0.06;
			double vv = var[(int)by][(int)bx % 6];
			if (mort) put8(tex + 3 * (tt + i), 200, 195, 185);
			else put8(tex + 3 * (tt + i), 170 * vv, 75 * vv, 50 * vv);
			/* 2 text background (glyphs below) */
			put8(tex + 3 * (2 * tt + i), 240, 200, 40);
			/* 3: the NixOS logomark (below; the research had a smooth gradient here) */
			/* 4 wood rings */
			double ring = 0.5 + 0.5 * sin(2 * M_PI * (hypot(xx - 0.2, yy - 0.3) * 9 + n1[i] * 1.5));
			put8(tex + 3 * (4 * tt + i), 120 + 80 * ring, 70 + 50 * ring, 30 + 25 * ring);
			/* 5 fractal noise */
			double a = (acc[i] - lo) / (hi - lo);
			put8(tex + 3 * (5 * tt + i), 40 + 120 * a, 110 + 120 * a, 60 + 60 * a);
		}
	nixos_logo(T_, tex + 3 * 3 * tt);
	/* text: "CODA", "980", "H.264" */
	static const char *lines[3] = {"CODA", "980", "H.264"};
	int s = T_ / 40 > 0 ? T_ / 40 : 1;
	for (int k = 0; k < 3; k++) {
		int x0 = (int)(T_ * 0.08), y0 = (int)(T_ * (0.06 + 0.3 * k));
		for (const char *p = lines[k]; *p; p++, x0 += 8 * s) {
			const uint8_t *g = NULL;
			for (size_t q = 0; q < sizeof GLYPHS / sizeof GLYPHS[0]; q++)
				if (GLYPHS[q].c == *p)
					g = GLYPHS[q].rows;
			if (!g)
				continue;
			for (int gy = 0; gy < 8 * s; gy++)
				for (int gx = 0; gx < 8 * s; gx++) {
					int X = x0 + gx, Y = y0 + gy;
					if (X >= T_ || Y >= T_ || !((g[gy / s] >> (gx / s)) & 1))
						continue;
					put8(tex + 3 * (2 * tt + (size_t)Y * T_ + X), 20, 20, 90);
				}
		}
	}
	free(n1);
	free(acc);
	free(tmp);
}

/* ideaa.py bilinear(): clamp, then the 2x2 neighbourhood with ix <= T-2 */
static inline void bilinear(const uint8_t *tex, double ty, double tx, double *rgb)
{
	if (tx < 0) tx = 0;
	if (tx > T - 1) tx = T - 1;
	if (ty < 0) ty = 0;
	if (ty > T - 1) ty = T - 1;
	int ix = (int)floor(tx), iy = (int)floor(ty);
	if (ix > T - 2) ix = T - 2;
	if (iy > T - 2) iy = T - 2;
	double fx = tx - ix, fy = ty - iy;
	const uint8_t *a = tex + 3 * ((size_t)iy * T + ix), *c = a + 3 * (size_t)T;
	for (int k = 0; k < 3; k++)
		rgb[k] = (a[k] * (1 - fx) + a[3 + k] * fx) * (1 - fy) + (c[k] * (1 - fx) + c[3 + k] * fx) * fy;
}

/*
 * Atlas page k (ideaa.py atlas()): all six faces rotated by 2*pi*k/K in a 3x2
 * grid of B x B slots, atlas point q <-> texel point T/2 + R(theta)(q - B/2),
 * then the research's RGB->YUV 4:2:0 (full-range BT.601, chroma = 2x2 mean of
 * the full-resolution chroma). Two rows at a time, so it needs no big buffer.
 */
static void build_page(const uint8_t *tex, int k, uint8_t *Yp, uint8_t *Up, uint8_t *Vp)
{
	double th = 2 * M_PI * k / K, c = cos(th), s = sin(th);
	double *yy = malloc(sizeof(double) * 2 * W), *uu = malloc(sizeof(double) * 2 * W), *vv = malloc(sizeof(double) * 2 * W);
	for (int y2 = 0; y2 < H; y2 += 2) {
		for (int r = 0; r < 2; r++) {
			int y = y2 + r;
			for (int x = 0; x < W; x++) {
				double rgb[3] = {0, 0, 0};
				if (x < 3 * B && y < 2 * B) {
					int fc = (y / B) * 3 + x / B, i = y - (y / B) * B, j = x - (x / B) * B;
					double qx = (double)j + 0.5 - B / 2.0, qy = (double)i + 0.5 - B / 2.0;
					double tx = T / 2.0 + c * qx - s * qy, ty = T / 2.0 + s * qx + c * qy;
					bilinear(tex + (size_t)fc * T * T * 3, ty - 0.5, tx - 0.5, rgb);
					for (int q = 0; q < 3; q++) {
						rgb[q] = floor(rgb[q] + 0.5);
						if (rgb[q] < 0) rgb[q] = 0;
						if (rgb[q] > 255) rgb[q] = 255;
					}
				}
				double Yf = 0.299 * rgb[0] + 0.587 * rgb[1] + 0.114 * rgb[2];
				yy[r * W + x] = Yf;
				uu[r * W + x] = 128 + 0.564 * (rgb[2] - Yf);
				vv[r * W + x] = 128 + 0.713 * (rgb[0] - Yf);
			}
		}
		for (int r = 0; r < 2; r++)
			for (int x = 0; x < W; x++) {
				double q = floor(yy[r * W + x] + 0.5);
				int used = x < 3 * B && y2 + r < 2 * B;
				Yp[(size_t)(y2 + r) * W + x] = used ? (uint8_t)(q < 0 ? 0 : q > 255 ? 255 : q) : 0;
			}
		for (int x = 0; x < W; x += 2) {
			double su = (uu[x] + uu[W + x] + uu[x + 1] + uu[W + x + 1]) / 4;
			double sv = (vv[x] + vv[W + x] + vv[x + 1] + vv[W + x + 1]) / 4;
			double qu = floor(su + 0.5), qv = floor(sv + 0.5);
			int used = x < 3 * B && y2 < 2 * B;
			size_t o = (size_t)(y2 / 2) * (W / 2) + x / 2;
			Up[o] = used ? (uint8_t)(qu < 0 ? 0 : qu > 255 ? 255 : qu) : 128;
			Vp[o] = used ? (uint8_t)(qv < 0 ? 0 : qv > 255 ? 255 : qv) : 128;
		}
	}
	free(yy);
	free(uu);
	free(vv);
}

/* Pages come from --atlas (a file of K I420 pages) or are built from the textures. */
typedef struct { FILE *atlas; const uint8_t *tex; uint8_t *buf; } PageSrc;
static const uint8_t *get_page(PageSrc *ps, int k)
{
	size_t fs = (size_t)W * H * 3 / 2;
	if (ps->atlas) {
		if (fread(ps->buf, 1, fs, ps->atlas) != fs)
			die("short --atlas file");
	} else {
		build_page(ps->tex, k, ps->buf, ps->buf + (size_t)W * H, ps->buf + (size_t)W * H * 5 / 4);
	}
	return ps->buf;
}

/* ------------------------------------------------------------ the generator, per frame */
typedef struct {
	Frame *F;
	uint8_t *rbsp, *au;     /* RBSP scratch and the NAL-wrapped access units */
	size_t cap, len;
	int nau;                /* access units this frame: the render (+ smoothing B-pictures) */
	size_t auoff[3], aulen[3];
	Part *parts;
	int nparts, npcm, nedge;
	double t_aa, t_smooth;
} Gen;

static void gen_init(Gen *g, int want_parts)
{
	W4 = WMB * 4;
	H4 = HMB * 4;
	sref = malloc((size_t)W4 * H4);
	smv = malloc((size_t)W4 * H4 * 4);
	sdone = malloc((size_t)W4 * H4);
	g->F = malloc(sizeof(Frame));
	g->cap = (size_t)W * H * 2 + 65536;     /* every MB as I_PCM fits */
	g->rbsp = malloc(g->cap);
	g->au = malloc(g->cap * 3 / 2);
	g->parts = want_parts ? malloc(sizeof(Part) * (size_t)W4 * H4) : NULL;
	bref1 = malloc((size_t)W4 * H4);
	bmv1 = malloc((size_t)W4 * H4 * 4);
	if (!sref || !smv || !sdone || !g->F || !g->rbsp || !g->au || !bref1 || !bmv1)
		die("out of memory");
}

/* frame n's access units for animation angle t into g->au */
static void gen_frame(Gen *g, float t, long n)
{
	BW b = {g->rbsp, 0, 0, 0};
	int ref = g_smooth != 0;
	/* a non-reference render reuses frame_num 1 + K; reference pictures count
	 * on, one per reference picture (two per frame with the H pass) */
	int fn = ref ? (int)((K + 1 + (long)g_smooth * n) & 0xffff) : 1 + K;
	int poc = ref ? (int)((2 * (K + 1) + 6 * n) & 0xffff) : (int)((2 * (n % 16000 + 1 + K)) & 0xffff);
	g_t_aa = 0;
	g->t_smooth = 0;
	scene(t, g->F);
	if (g_aa || g_smooth || g_need_edges)
		find_edges(g->F);
	encode_frame(g->F, fn, poc, ref, &b, g->parts, &g->nparts);
	g->npcm = g_npcm;
	g->nedge = g_nedge;
	g->t_aa = g_t_aa;
	g->auoff[0] = 0;
	g->aulen[0] = nal_wrap(g->au, ref ? 2 : 0, 1, g->rbsp, b.len);
	g->nau = 1;
	size_t o = g->aulen[0];
	if (g_smooth) {
		double t0 = now_s();
		size_t n1;
		if (g_smooth == 1) {
			n1 = encode_bpic(g->rbsp, fn + 1, poc + 2, 0, 2, 2, -2, -2);
			g->auoff[1] = o; g->aulen[1] = nal_wrap(g->au + o, 0, 1, g->rbsp, n1); o += g->aulen[1];
			g->nau = 2;
		} else {
			n1 = encode_bpic(g->rbsp, fn + 1, poc + 2, 1, 2, 0, -2, 0);
			g->auoff[1] = o; g->aulen[1] = nal_wrap(g->au + o, 2, 1, g->rbsp, n1); o += g->aulen[1];
			n1 = encode_bpic(g->rbsp, fn + 2, poc + 4, 0, 0, 2, 0, -2);
			g->auoff[2] = o; g->aulen[2] = nal_wrap(g->au + o, 0, 1, g->rbsp, n1); o += g->aulen[2];
			g->nau = 3;
		}
		g->t_smooth = now_s() - t0;
	}
	g->len = o;
}

/* --cpu-model: what a conformant decoder outputs for the render, from the
 * partitions, the pages and this frame's I_PCM samples */
static void model_p(const Gen *g, uint8_t *Y, uint8_t *U, uint8_t *V)
{
	for (int q = 0; q < g->nparts; q++) {
		const Part *p = &g->parts[q];
		if (p->ref < 0) {
			const uint8_t *s = g_pcmstore + (size_t)((p->y / 16) * WMB + p->x / 16) * 384;
			for (int j = 0; j < 16; j++) memcpy(Y + (size_t)(p->y + j) * W + p->x, s + 16 * j, 16);
			for (int j = 0; j < 8; j++) {
				memcpy(U + (size_t)(p->y / 2 + j) * (W / 2) + p->x / 2, s + 256 + 8 * j, 8);
				memcpy(V + (size_t)(p->y / 2 + j) * (W / 2) + p->x / 2, s + 320 + 8 * j, 8);
			}
			continue;
		}
		int pg = REFPAGE[p->ref], r = p->ref;
		for (int j = 0; j < p->h; j++)
			for (int i = 0; i < p->w; i++) {
				int v = luma_qpel(PGY[pg], p->x + i + (p->mvx >> 2), p->y + j + (p->mvy >> 2), p->mvx & 3, p->mvy & 3);
				Y[(size_t)(p->y + j) * W + p->x + i] = (uint8_t)(r ? wp6(v, WY[r], OY[r]) : v);
			}
		for (int j = 0; j < p->h / 2; j++)
			for (int i = 0; i < p->w / 2; i++) {
				int xc = p->x / 2 + i, yc = p->y / 2 + j;
				int u = chroma_pred(PGU[pg], xc, yc, p->mvx, p->mvy), v = chroma_pred(PGV[pg], xc, yc, p->mvx, p->mvy);
				U[(size_t)yc * (W / 2) + xc] = (uint8_t)(r ? wp6(u, WC[r], OC[r]) : u);
				V[(size_t)yc * (W / 2) + xc] = (uint8_t)(r ? wp6(v, WC[r], OC[r]) : v);
			}
	}
}

/* the B-picture of encode_bpic() from its reference picture S */
static void model_b(const uint8_t *SY, const uint8_t *SU, const uint8_t *SV, uint8_t *Y, uint8_t *U, uint8_t *V,
		    int m0x, int m0y, int m1x, int m1y)
{
	for (int m = 0; m < WMB * HMB; m++) {
		int X0 = (m % WMB) * 16, Y0 = (m / WMB) * 16;
		for (int j = 0; j < 16; j++)
			for (int i = 0; i < 16; i++) {
				int x = X0 + i, y = Y0 + j, v = SY[(size_t)y * W + x];
				if (g_edge[m])
					v = avg2(luma_qpel(SY, x + (m0x >> 2), y + (m0y >> 2), m0x & 3, m0y & 3),
						 luma_qpel(SY, x + (m1x >> 2), y + (m1y >> 2), m1x & 3, m1y & 3));
				Y[(size_t)y * W + x] = (uint8_t)v;
			}
		for (int j = 0; j < 8; j++)
			for (int i = 0; i < 8; i++) {
				int xc = X0 / 2 + i, yc = Y0 / 2 + j;
				size_t o = (size_t)yc * (W / 2) + xc;
				if (g_edge[m]) {
					U[o] = (uint8_t)avg2(chroma_pred(SU, xc, yc, m0x, m0y), chroma_pred(SU, xc, yc, m1x, m1y));
					V[o] = (uint8_t)avg2(chroma_pred(SV, xc, yc, m0x, m0y), chroma_pred(SV, xc, yc, m1x, m1y));
				} else {
					U[o] = SU[o];
					V[o] = SV[o];
				}
			}
	}
}

/* --ref-out: the research's reference render (ideaa.py reference(), ref420())
 * with ss x ss supersampling: front-most triangle at each sample point,
 * perspective-correct uv, bilinear texture, exact light, box filter */
static void ref_render(const Frame *F, const uint8_t *tex, int ss, uint8_t *Y, uint8_t *U, uint8_t *V)
{
	double *rgb = calloc((size_t)W * H * 3, sizeof(double));
	for (int y = 0; y < H; y++)
		for (int x = 0; x < W; x++) {
			int m = (y / 16) * WMB + x / 16;
			double acc[3] = {0, 0, 0};
			for (int sy = 0; sy < ss; sy++)
				for (int sx_ = 0; sx_ < ss; sx_++) {
					double px = x + (sx_ + 0.5) / ss, py = y + (sy + 0.5) / ss, best = 0, col[3] = {0, 0, 0};
					for (int k = 0; k < F->nlist[m]; k++) {
						const Tri *t = &F->tri[F->list[m][k]];
						double x0 = t->sx[0], x1 = t->sx[1], x2 = t->sx[2], y0 = t->sy[0], y1 = t->sy[1], y2 = t->sy[2];
						double d = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0);
						double l1 = ((x2 - px) * (y0 - py) - (x0 - px) * (y2 - py)) / d;
						double l2 = ((x0 - px) * (y1 - py) - (x1 - px) * (y0 - py)) / d;
						double l0 = 1 - l1 - l2;
						if (l0 < 0 || l1 < 0 || l2 < 0) continue;
						double z = l0 * t->wz[0] + l1 * t->wz[1] + l2 * t->wz[2];
						if (!(z > best)) continue;
						double u = (l0 * t->wu[0] + l1 * t->wu[1] + l2 * t->wu[2]) / (z > 0 ? z : 1);
						double v = (l0 * t->wv[0] + l1 * t->wv[1] + l2 * t->wv[2]) / (z > 0 ? z : 1);
						double uu = u * T - 0.5, vv = v * T - 0.5;
						uu = uu < 0 ? 0 : uu > T - 1 ? T - 1 : uu;
						vv = vv < 0 ? 0 : vv > T - 1 ? T - 1 : vv;
						int iu = (int)floor(uu), iv = (int)floor(vv);
						if (iu > T - 2) iu = T - 2;
						if (iv > T - 2) iv = T - 2;
						double fu = uu - iu, fv = vv - iv;
						const uint8_t *tx = tex + (size_t)t->face * T * T * 3, *a = tx + 3 * ((size_t)iv * T + iu), *c = a + 3 * (size_t)T;
						for (int q = 0; q < 3; q++)
							col[q] = ((a[q] * (1 - fu) + a[3 + q] * fu) * (1 - fv) + (c[q] * (1 - fu) + c[3 + q] * fu) * fv) * F->light[t->face];
						best = z;
					}
					for (int q = 0; q < 3; q++) acc[q] += col[q];
				}
			for (int q = 0; q < 3; q++) rgb[3 * ((size_t)y * W + x) + q] = acc[q] / (ss * ss);
		}
	for (int y = 0; y < H; y += 2)
		for (int x = 0; x < W; x += 2) {
			double su = 0, sv = 0;
			const int ord[4][2] = {{0, 0}, {1, 0}, {0, 1}, {1, 1}};   /* (dy, dx): numpy's P[0::2,0::2] + P[1::2,0::2] + P[0::2,1::2] + P[1::2,1::2] */
			for (int k = 0; k < 4; k++) {
				const double *c = rgb + 3 * ((size_t)(y + ord[k][0]) * W + x + ord[k][1]);
				double yy = 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2];
				su += 128 + 0.564 * (c[2] - yy);
				sv += 128 + 0.713 * (c[0] - yy);
				double q = floor(yy + 0.5);
				Y[(size_t)(y + ord[k][0]) * W + x + ord[k][1]] = (uint8_t)(q < 0 ? 0 : q > 255 ? 255 : q);
			}
			double qu = floor(su / 4 + 0.5), qv = floor(sv / 4 + 0.5);
			U[(size_t)(y / 2) * (W / 2) + x / 2] = (uint8_t)(qu < 0 ? 0 : qu > 255 ? 255 : qu);
			V[(size_t)(y / 2) * (W / 2) + x / 2] = (uint8_t)(qv < 0 ? 0 : qv > 255 ? 255 : qv);
		}
	free(rgb);
}

static void write_info(FILE *info, const Gen *g)
{
	const Frame *F = g->F;
	int32_t hdr[4] = {(int32_t)g->nparts, F->ntri, (int32_t)g->len, NREF};
	fwrite(hdr, 4, 4, info);
	fwrite(REFPAGE, 4, NREF, info); fwrite(WY, 4, NREF, info); fwrite(OY, 4, NREF, info);
	fwrite(WC, 4, NREF, info); fwrite(OC, 4, NREF, info);
	fwrite(F->light, 4, 6, info);
	for (int i = 0; i < F->ntri; i++) {
		float rec[16]; const Tri *t = &F->tri[i];
		for (int j = 0; j < 3; j++) { rec[j*5] = t->sx[j]; rec[j*5+1] = t->sy[j]; rec[j*5+2] = t->wz[j]; rec[j*5+3] = t->wu[j]; rec[j*5+4] = t->wv[j]; }
		rec[15] = (float)t->face; fwrite(rec, 4, 16, info);
	}
	fwrite(g->parts, sizeof(Part), (size_t)g->nparts, info);
}

/* ------------------------------------------------------------ NV12 -> BGR24 / XRGB8888
 * Full-range BT.601, the inverse of the atlas's conversion (ideaa.py yuv2rgb),
 * in Q7 fixed point: R = Y + 1.402 V', G = Y - 0.344 U' - 0.714 V', B = Y + 1.772 U'.
 * scale 2 doubles each pixel in both directions (640x368 on a 1280x720 surface). */
enum { FMT_BGR24, FMT_XRGB };

#if defined(__aarch64__)
static inline __attribute__((always_inline)) void st_px(uint8_t *d, uint8x16_t b, uint8x16_t g, uint8x16_t r, int fmt)
{
	if (fmt == FMT_BGR24) {
		uint8x16x3_t o = {{b, g, r}};
		vst3q_u8(d, o);
	} else {
		uint8x16x4_t o = {{b, g, r, vdupq_n_u8(255)}};
		vst4q_u8(d, o);
	}
}

static inline __attribute__((always_inline)) void cvt_rows(const uint8_t *y0, const uint8_t *y1, const uint8_t *uv,
		uint8_t *const d[4], int w, int fmt, int scale)
{
	const int bpp = fmt == FMT_BGR24 ? 3 : 4;
	const uint8x8_t k128 = vdup_n_u8(128);
	for (int x = 0; x < w; x += 16) {
		uint8x8x2_t c = vld2_u8(uv + x);
		int16x8_t u = vreinterpretq_s16_u16(vsubl_u8(c.val[0], k128));
		int16x8_t v = vreinterpretq_s16_u16(vsubl_u8(c.val[1], k128));
		int16x8_t rv = vrshrq_n_s16(vmulq_n_s16(v, 179), 7);
		int16x8_t gv = vrshrq_n_s16(vmlaq_n_s16(vmulq_n_s16(u, -44), v, -91), 7);
		int16x8_t bv = vrshrq_n_s16(vmulq_n_s16(u, 227), 7);
		int16x8x2_t R = vzipq_s16(rv, rv), Gc = vzipq_s16(gv, gv), Bc = vzipq_s16(bv, bv);
		for (int row = 0; row < 2; row++) {
			uint8x16_t yy = vld1q_u8((row ? y1 : y0) + x);
			int16x8_t yl = vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(yy)));
			int16x8_t yh = vreinterpretq_s16_u16(vmovl_u8(vget_high_u8(yy)));
			uint8x16_t r = vcombine_u8(vqmovun_s16(vaddq_s16(yl, R.val[0])), vqmovun_s16(vaddq_s16(yh, R.val[1])));
			uint8x16_t g = vcombine_u8(vqmovun_s16(vaddq_s16(yl, Gc.val[0])), vqmovun_s16(vaddq_s16(yh, Gc.val[1])));
			uint8x16_t b = vcombine_u8(vqmovun_s16(vaddq_s16(yl, Bc.val[0])), vqmovun_s16(vaddq_s16(yh, Bc.val[1])));
			if (scale == 1) {
				if (d[row])
					st_px(d[row] + (size_t)x * bpp, b, g, r, fmt);
			} else {
				uint8x16x2_t r2 = vzipq_u8(r, r), g2 = vzipq_u8(g, g), b2 = vzipq_u8(b, b);
				for (int k = 0; k < 2; k++) {
					uint8_t *dd = d[2 * row + k];
					if (!dd)
						continue;
					st_px(dd + (size_t)2 * x * bpp, b2.val[0], g2.val[0], r2.val[0], fmt);
					st_px(dd + (size_t)(2 * x + 16) * bpp, b2.val[1], g2.val[1], r2.val[1], fmt);
				}
			}
		}
	}
}
#endif
/* portable reference for the NEON path (same integer arithmetic) */
static inline __attribute__((unused)) void cvt_rows_c(const uint8_t *y0, const uint8_t *y1, const uint8_t *uv,
		uint8_t *const d[4], int w, int fmt, int scale)
{
	const int bpp = fmt == FMT_BGR24 ? 3 : 4;
	for (int row = 0; row < 2; row++)
		for (int x = 0; x < w; x++) {
			int Y = (row ? y1 : y0)[x], u = uv[x & ~1] - 128, v = uv[x | 1] - 128;
			int rgb[3] = {Y + ((179 * v + 64) >> 7), Y + ((-44 * u - 91 * v + 64) >> 7), Y + ((227 * u + 64) >> 7)};
			uint8_t px[4];
			for (int q = 0; q < 3; q++)
				px[2 - q] = (uint8_t)(rgb[q] < 0 ? 0 : rgb[q] > 255 ? 255 : rgb[q]);
			px[3] = 255;
			for (int k = 0; k < scale; k++) {
				uint8_t *dd = d[scale == 1 ? row : 2 * row + k];
				if (!dd)
					continue;
				for (int sx = 0; sx < scale; sx++)
					memcpy(dd + (size_t)(x * scale + sx) * bpp, px, (size_t)bpp);
			}
		}
}
#if !defined(__aarch64__)
#define cvt_rows cvt_rows_c
#endif
static int g_cvt_c;   /* --convert-test: use the portable path */

/*
 * Convert a WxH NV12 picture into a dw x dh surface, centred, scaled by
 * `scale`, clipped vertically. The source must not be wider than the surface
 * (scaled); a narrower one is centred.
 */
static __attribute__((unused)) void nv12_to_surface(const uint8_t *Y, size_t ys, const uint8_t *UV, size_t cs, int w, int h,
		uint8_t *dst, size_t pitch, int dw, int dh, int fmt, int scale)
{
	const int bpp = fmt == FMT_BGR24 ? 3 : 4;
	int ox = (dw - w * scale) / 2, oy = (dh - h * scale) / 2;
	if (ox < 0)
		return;
	for (int y = 0; y < h; y += 2) {
		uint8_t *d[4] = {NULL, NULL, NULL, NULL};
		for (int k = 0; k < 2 * scale; k++) {
			int dy = oy + y * scale + k;
			if (dy >= 0 && dy < dh)
				d[k] = dst + (size_t)dy * pitch + (size_t)ox * bpp;
		}
		if (!d[0] && !d[1] && !d[2] && !d[3])
			continue;
		const uint8_t *y0 = Y + (size_t)y * ys, *y1 = y0 + ys, *uv = UV + (size_t)(y / 2) * cs;
		if (g_cvt_c) {
			cvt_rows_c(y0, y1, uv, d, w, fmt, scale);
		} else if (fmt == FMT_BGR24) {
			if (scale == 1) cvt_rows(y0, y1, uv, d, w, FMT_BGR24, 1);
			else cvt_rows(y0, y1, uv, d, w, FMT_BGR24, 2);
		} else {
			if (scale == 1) cvt_rows(y0, y1, uv, d, w, FMT_XRGB, 1);
			else cvt_rows(y0, y1, uv, d, w, FMT_XRGB, 2);
		}
	}
}

/* ------------------------------------------------------------ decoder (vdecdump.c) */
static volatile sig_atomic_t g_stop;
static __attribute__((unused)) void on_sig(int s) { (void)s; g_stop = 1; }
static int g_zero_copy;   /* --zero-copy: sway reads the decoder's frame buffers, nothing maps them */

#ifdef CODA_HW
typedef struct { VIDEO_FRAME_INFO_S *pstFrame; CVI_S32 s32MilliSec; } VIDEO_FRAME_INFO_EX_S;
typedef struct { VDEC_STREAM_S *pstStream; CVI_S32 s32MilliSec; } VDEC_STREAM_EX_S;

static int g_fd = -1, g_mapion = -1, g_chn, g_created, g_started, g_uncached;
static volatile int g_late, g_stale;   /* pictures that came after SEND_STREAM returned; older ones drained */

static int x_ioctl(unsigned long req, void *arg)
{
	int r;
	do
		r = ioctl(g_fd, req, arg);
	while (r == -1 && errno == EINTR);
	return r;
}

static int chn_exists(void)
{
	VDEC_CHN_STATUS_S st;
	memset(&st, 0, sizeof(st));
	return x_ioctl(CVI_VC_VDEC_QUERY_STATUS, &st) == 0;
}

static void vd_close(void)
{
	if (g_fd < 0)
		return;
	if (g_started && x_ioctl(CVI_VC_VDEC_STOP_RECV_STREAM, NULL))
		fprintf(stderr, "coda-cube: StopRecvStream failed\n");
	g_started = 0;
	if (g_created) {
		int r = x_ioctl(CVI_VC_VDEC_DESTROY_CHN, NULL);
		fprintf(stderr, "@destroy chn=%d ret=%#x\n", g_chn, (unsigned)r);
	}
	g_created = 0;
	close(g_fd);
	g_fd = -1;
}

static int vd_open_dev(void)
{
	char dev[64];
	snprintf(dev, sizeof(dev), "/dev/%s%d", CVI_VC_DRV_DECODER_DEV_NAME, g_chn);
	g_fd = open(dev, O_RDWR | O_DSYNC | O_CLOEXEC);
	if (g_fd < 0) {
		fprintf(stderr, "coda-cube: open %s: %s (is cvi_vc_driver loaded?)\n", dev, strerror(errno));
		return -1;
	}
	return 0;
}

/* the channel, on the decoder device vd_open_dev() opened, or opens now */
static int vd_open(size_t bsz)
{
	VDEC_CHN_ATTR_S attr;
	VDEC_CHN_PARAM_S param;
	int r;

	if (g_fd < 0 && vd_open_dev())
		return -1;
	if (chn_exists()) {
		fprintf(stderr, "coda-cube: channel %d exists (another user, or a killed run: --destroy)\n", g_chn);
		close(g_fd);
		g_fd = -1;
		return -1;
	}
	if (!g_zero_copy) {   /* zero-copy, no frame is read on the CPU */
		g_mapion = open("/dev/soph-ion", O_RDWR | O_CLOEXEC);
		if (g_mapion < 0) {
			fprintf(stderr, "coda-cube: open /dev/soph-ion: %s (run as root)\n", strerror(errno));
			return -1;
		}
	}
	memset(&attr, 0, sizeof(attr));
	attr.enType = PT_H264;
	attr.enMode = VIDEO_MODE_FRAME;
	attr.u32PicWidth = (CVI_U32)W;
	attr.u32PicHeight = (CVI_U32)H;
	attr.u32StreamBufSize = (CVI_U32)bsz;
	attr.u32FrameBufCnt = 4;     /* > 4 turns display reordering on */
	r = x_ioctl(CVI_VC_VDEC_CREATE_CHN, &attr);
	fprintf(stderr, "@create chn=%d %dx%d bs=%zu ret=%#x\n", g_chn, W, H, bsz, (unsigned)r);
	if (r)
		return -1;
	g_created = 1;
	memset(&param, 0, sizeof(param));
	r = x_ioctl(CVI_VC_VDEC_GET_CHN_PARAM, &param);
	param.enPixelFormat = PIXEL_FORMAT_NV12;
	param.u32DisplayFrameNum = 0;
	r |= x_ioctl(CVI_VC_VDEC_SET_CHN_PARAM, &param);
	r |= x_ioctl(CVI_VC_VDEC_START_RECV_STREAM, NULL);
	fprintf(stderr, "@start ret=%#x\n", (unsigned)r);
	if (r)
		return -1;
	g_started = 1;
	return 0;
}

static int vd_send(const uint8_t *au, size_t len, uint64_t pts)
{
	VDEC_STREAM_S st;
	VDEC_STREAM_EX_S sx;
	memset(&st, 0, sizeof(st));
	st.pu8Addr = (CVI_U8 *)au;
	st.u32Len = (CVI_U32)len;
	st.u64PTS = pts;
	st.bEndOfFrame = CVI_TRUE;
	st.bEndOfStream = CVI_FALSE;
	st.bDisplay = CVI_TRUE;
	sx.pstStream = &st;
	sx.s32MilliSec = -1;
	return x_ioctl(CVI_VC_VDEC_SEND_STREAM, &sx);
}

static int vd_get_ms(VIDEO_FRAME_INFO_S *fi, int ms)
{
	VIDEO_FRAME_INFO_EX_S fx;
	memset(fi, 0, sizeof(*fi));
	fx.pstFrame = fi;
	fx.s32MilliSec = ms;
	return x_ioctl(CVI_VC_VDEC_GET_FRAME, &fx);
}

static void vd_release(VIDEO_FRAME_INFO_S *fi)
{
	if (x_ioctl(CVI_VC_VDEC_RELEASE_FRAME, fi))
		fprintf(stderr, "@warn release failed\n");
}

/*
 * Frame buffers are ION allocations, each exported once through /dev/soph-ion
 * and mapped whole, and kept (the codec reuses a fixed set). Read-only, the map
 * is cacheable and every read is bracketed by DMA_BUF_IOCTL_SYNC; with
 * --uncached it is writable, hence write-combined, and needs no maintenance.
 */
typedef struct { uint64_t start; size_t size; uint8_t *base; int fd; } Map;
static Map g_maps[64];
static int g_nmaps;

static const Map *map_of(const uint8_t *p)
{
	for (int i = 0; i < g_nmaps; i++)
		if (p >= g_maps[i].base && p < g_maps[i].base + g_maps[i].size)
			return &g_maps[i];
	return NULL;
}

static const uint8_t *map_get(uint64_t pa, size_t len)
{
	struct soph_ion_export ex = { .phys = pa, .flags = O_CLOEXEC };
	uint8_t *m;

	for (int i = 0; i < g_nmaps; i++)
		if (pa >= g_maps[i].start && len <= g_maps[i].size && pa - g_maps[i].start <= g_maps[i].size - len)
			return g_maps[i].base + (pa - g_maps[i].start);
	if (len == 0 || g_nmaps == 64)
		return NULL;
	if (!g_uncached)
		ex.flags |= SOPH_ION_EXPORT_RDONLY;
	if (ioctl(g_mapion, SOPH_ION_IOC_EXPORT, &ex)) {
		fprintf(stderr, "coda-cube: export of the frame at %#" PRIx64 ": %s\n", pa, strerror(errno));
		return NULL;
	}
	if (len > ex.size - ex.offset) {
		fprintf(stderr, "coda-cube: %zu B at %#" PRIx64 " run past its %llu B ION allocation\n",
			len, pa, (unsigned long long)ex.size);
		close(ex.fd);
		return NULL;
	}
	m = mmap(NULL, ex.size, g_uncached ? PROT_READ | PROT_WRITE : PROT_READ, MAP_SHARED, ex.fd, 0);
	if (m == MAP_FAILED) {
		fprintf(stderr, "coda-cube: map of the frame at %#" PRIx64 ": %s\n", pa, strerror(errno));
		close(ex.fd);
		return NULL;
	}
	g_maps[g_nmaps++] = (Map){ pa - ex.offset, ex.size, m, ex.fd };
	return m + ex.offset;
}

static void unmap_all(void)
{
	for (int i = 0; i < g_nmaps; i++) {
		munmap(g_maps[i].base, g_maps[i].size);
		close(g_maps[i].fd);
	}
	g_nmaps = 0;
	if (g_mapion >= 0)
		close(g_mapion);
	g_mapion = -1;
}

/* DMA_BUF_SYNC_START before the CPU reads a frame (it drops the stale lines of
 * the cacheable map), DMA_BUF_SYNC_END after */
static void map_sync(const Map *m, uint64_t how)
{
	struct dma_buf_sync s = { .flags = how | DMA_BUF_SYNC_READ };

	if (g_uncached || !m)
		return;
	while (ioctl(m->fd, DMA_BUF_IOCTL_SYNC, &s) == -1 && errno == EINTR)
		;
}

static void frame_sync(const uint8_t *y, const uint8_t *c, uint64_t how)
{
	const Map *my = map_of(y), *mc = map_of(c);

	map_sync(my, how);
	if (mc != my)
		map_sync(mc, how);
}

/* HwDecTime (us) of our channel, the driver's last value */
static long long proc_hw(void)
{
	static char buf[65536];
	char key[32];
	long long hw = -1;
	FILE *f = fopen("/proc/cvitek/vdec", "r");
	if (!f)
		return -1;
	size_t n = fread(buf, 1, sizeof(buf) - 1, f);
	fclose(f);
	buf[n] = 0;
	snprintf(key, sizeof(key), "ID: %d\t", g_chn);
	for (char *p = buf; (p = strstr(p, "HwDecTime:")); p++) {
		char *line = p;
		while (line > buf && line[-1] != '\n')
			line--;
		if (strncmp(line, key, strlen(key)))
			continue;
		sscanf(p, "HwDecTime: %lld", &hw);
		break;
	}
	return hw;
}

/* --pipeline: the decoder ioctls in a worker thread, so the A53 presents frame
 * n and generates frame n+2 while the decoder (and the ioctl sleeping on it)
 * works on frame n+1. The worker issues every decoder ioctl, the release of
 * the shown frame included: a RELEASE_FRAME racing a SEND_STREAM from another
 * thread made the vendor driver drop pictures and fill its bitstream buffer. */
/* send a frame's access units; keep the last one's picture (the one shown),
 * release the others. HwDecTime summed over them when sample_hw. */
static int decode_aus(const uint8_t *au, const size_t *off, const size_t *len, int nau, uint64_t pts,
		      VIDEO_FRAME_INFO_S *fi, int sample_hw, double *hw)
{
	*hw = -1;
	for (int a = 0; a < nau; a++) {
		VIDEO_FRAME_INFO_S nx;
		int r = vd_send(au + off[a], len[a], pts);
		if (r) {
			fprintf(stderr, "@drop pts=%llu au=%d/%d bytes=%zu: SEND_STREAM ret=%d errno=%d\n",
				(unsigned long long)pts, a, nau, len[a], r, errno);
			return 0;
		}
		/* SEND_STREAM normally returns with the picture queued; under load it
		 * can come a little later. Wait for it, and drain anything queued
		 * behind it: a late picture left in the queue would hold a frame
		 * buffer for good and starve the decoder. Keep the newest. */
		if (vd_get_ms(fi, 0)) {
			if ((r = vd_get_ms(fi, 200))) {
				fprintf(stderr, "@drop pts=%llu au=%d/%d bytes=%zu: no picture within 200 ms (GET_FRAME ret=%d errno=%d)\n",
					(unsigned long long)pts, a, nau, len[a], r, errno);
				return 0;
			}
			g_late++;
		}
		while (vd_get_ms(&nx, 0) == 0) {
			vd_release(fi);
			*fi = nx;
			g_stale++;
		}
		if (sample_hw) {
			long long h = proc_hw();
			if (h >= 0) *hw = (*hw < 0 ? 0 : *hw) + (double)h;
		}
		if (a + 1 < nau)
			vd_release(fi);
	}
	return 1;
}

/* Frames to give back to the VDEC before the next decode: pipelined, the
 * shown one; with --zero-copy, those whose buffer sway has released. Each
 * frame buffer is in here at most once, and the VDEC has fewer than this. */
#define MAX_HELD 32
static VIDEO_FRAME_INFO_S g_rel[MAX_HELD];
static int g_nrel;

static void rel_push(const VIDEO_FRAME_INFO_S *fi)
{
	if (g_nrel == MAX_HELD) {
		fprintf(stderr, "@warn release queue full\n");
		return;
	}
	g_rel[g_nrel++] = *fi;
}

/* the main thread's releases, when no worker runs */
static void rel_flush(void)
{
	for (int i = 0; i < g_nrel; i++)
		vd_release(&g_rel[i]);
	g_nrel = 0;
}

typedef struct {
	pthread_t th;
	pthread_mutex_t mu;
	pthread_cond_t cv;
	const uint8_t *au;
	size_t off[3], len[3];
	int nau, sample;
	uint64_t pts;
	int busy, quit, ok, nrel;
	VIDEO_FRAME_INFO_S fi, rel[MAX_HELD];   /* fi: the decoded picture; rel: released first */
	double t_ioctl, hw;
} Worker;

static void *worker_main(void *arg)
{
	Worker *w = arg;
	pthread_mutex_lock(&w->mu);
	for (;;) {
		while (!w->busy && !w->quit)
			pthread_cond_wait(&w->cv, &w->mu);
		if (w->quit)
			break;
		pthread_mutex_unlock(&w->mu);
		double t0 = now_s(), hw;
		for (int i = 0; i < w->nrel; i++)
			vd_release(&w->rel[i]);
		int ok = decode_aus(w->au, w->off, w->len, w->nau, w->pts, &w->fi, w->sample, &hw);
		double t1 = now_s();
		w->hw = hw;
		pthread_mutex_lock(&w->mu);
		w->ok = ok;
		w->t_ioctl = t1 - t0;
		w->busy = 0;
		pthread_cond_broadcast(&w->cv);
	}
	pthread_mutex_unlock(&w->mu);
	return NULL;
}

/* the next decode, after the releases queued so far (the queue is the worker's from here) */
static void worker_submit(Worker *w, const Gen *g, uint64_t pts, int sample)
{
	pthread_mutex_lock(&w->mu);
	memcpy(w->rel, g_rel, sizeof(g_rel[0]) * (size_t)g_nrel);
	w->nrel = g_nrel;
	g_nrel = 0;
	w->au = g->au;
	memcpy(w->off, g->auoff, sizeof w->off);
	memcpy(w->len, g->aulen, sizeof w->len);
	w->nau = g->nau;
	w->sample = sample;
	w->pts = pts;
	w->busy = 1;
	pthread_cond_broadcast(&w->cv);
	pthread_mutex_unlock(&w->mu);
}

static void worker_wait(Worker *w)
{
	pthread_mutex_lock(&w->mu);
	while (w->busy)
		pthread_cond_wait(&w->cv, &w->mu);
	pthread_mutex_unlock(&w->mu);
}

#ifdef CODA_SDL
/* --dmabuf: each decoded frame is copied into a soph_drm dumb buffer in the
 * decoder's own layout and handed to sway as an NV12 dma-buf. A dumb buffer
 * is free again when sway releases it. soph_drm has no .gem_create_object
 * hook, so dumb buffers are write-combined: the copy needs no cache
 * maintenance on its destination. */
#define DB_N 4
#define DB_W 1280u
#define DB_H 1104u          /* 1280 x 1104 x 8 bpp = 1,413,120 B, the decoder's frame size */
#define DB_UV 942080u       /* UV after 736 luma rows (the decoder's VPU_ALIGN32(720)) */
typedef struct { uint32_t handle; int fd, idx, busy; uint8_t *map; size_t size; } DumbBuf;
static DumbBuf g_db[DB_N];
static int g_drm = -1, g_db_next;
static unsigned g_releases;

static void db_released(void *tag, void *data)
{
	(void)data;
	((DumbBuf *)tag)->busy = 0;
	g_releases++;
}

static void db_close(void)
{
	if (g_drm < 0)   /* db_open never ran: g_db is still all zero */
		return;
	for (int i = 0; i < DB_N; i++) {
		DumbBuf *b = &g_db[i];
		if (b->map)
			munmap(b->map, b->size);
		if (b->fd >= 0)
			close(b->fd);
		if (b->handle) {
			struct drm_mode_destroy_dumb dd = { .handle = b->handle };
			ioctl(g_drm, DRM_IOCTL_MODE_DESTROY_DUMB, &dd);
		}
		*b = (DumbBuf){ .fd = -1 };
	}
	if (g_drm >= 0)
		close(g_drm);
	g_drm = -1;
}

/* the dumb buffers on card1 (soph_drm), exported and added to the presenter */
static int db_open(struct dmabuf_presenter *p)
{
	char name[32] = "";
	struct drm_version v = { .name_len = sizeof(name) - 1, .name = name };

	for (int i = 0; i < DB_N; i++)
		g_db[i] = (DumbBuf){ .fd = -1 };
	g_drm = open("/dev/dri/card1", O_RDWR | O_CLOEXEC);
	if (g_drm < 0) {
		fprintf(stderr, "coda-cube: open /dev/dri/card1: %s\n", strerror(errno));
		return -1;
	}
	if (ioctl(g_drm, DRM_IOCTL_VERSION, &v) || strcmp(name, "sophdrm")) {
		fprintf(stderr, "coda-cube: /dev/dri/card1 is %s, not sophdrm\n", name[0] ? name : "unknown");
		return -1;
	}
	for (int i = 0; i < DB_N; i++) {
		DumbBuf *b = &g_db[i];
		struct drm_mode_create_dumb cd = { .height = DB_H, .width = DB_W, .bpp = 8 };
		struct drm_mode_map_dumb md = { 0 };
		struct drm_prime_handle ph = { .flags = DRM_CLOEXEC | DRM_RDWR };
		if (ioctl(g_drm, DRM_IOCTL_MODE_CREATE_DUMB, &cd)) {
			fprintf(stderr, "coda-cube: dumb buffer %d: %s\n", i, strerror(errno));
			return -1;
		}
		b->handle = cd.handle;
		if (cd.pitch != DB_W || cd.size < (uint64_t)DB_W * DB_H) {
			fprintf(stderr, "coda-cube: dumb buffer pitch %u size %llu, want %u and %u\n", cd.pitch,
				(unsigned long long)cd.size, DB_W, DB_W * DB_H);
			return -1;
		}
		b->size = (size_t)cd.size;
		md.handle = cd.handle;
		ph.handle = cd.handle;
		if (ioctl(g_drm, DRM_IOCTL_MODE_MAP_DUMB, &md) || ioctl(g_drm, DRM_IOCTL_PRIME_HANDLE_TO_FD, &ph)) {
			fprintf(stderr, "coda-cube: dumb buffer %d: map/export: %s\n", i, strerror(errno));
			return -1;
		}
		b->fd = ph.fd;
		b->map = mmap(NULL, b->size, PROT_READ | PROT_WRITE, MAP_SHARED, g_drm, (off_t)md.offset);
		if (b->map == MAP_FAILED) {
			b->map = NULL;
			fprintf(stderr, "coda-cube: dumb buffer %d: mmap: %s\n", i, strerror(errno));
			return -1;
		}
		b->idx = dmabuf_presenter_add_buffer(p, b->fd, DB_UV, DB_W, b);
		if (b->idx < 0)
			return -1;
	}
	fprintf(stderr, "@dmabuf %d dumb buffers on card1 (sophdrm), %ux%u x 8 bpp, %zu B, NV12 UV at %u, stride %u\n",
		DB_N, DB_W, DB_H, g_db[0].size, DB_UV, DB_W);
	return 0;
}

/* a free dumb buffer, round robin; waits for sway's releases, which pace the frame rate */
static int db_get(struct dmabuf_presenter *p)
{
	double t0 = now_s();

	dmabuf_presenter_dispatch(p);
	for (;;) {
		for (int k = 0; k < DB_N; k++) {
			int i = (g_db_next + k) % DB_N;
			if (!g_db[i].busy) {
				g_db_next = (i + 1) % DB_N;
				return i;
			}
		}
		if (g_stop || dmabuf_presenter_wait(p, 100) < 0)
			return -1;
		if (now_s() - t0 > 2.0) {
			fprintf(stderr, "coda-cube: no dumb buffer released within 2 s\n");
			return -1;
		}
	}
}

static void db_copy(DumbBuf *b, const uint8_t *Y, size_t ys, const uint8_t *C, size_t cs, int w, int h)
{
	if (w > (int)DB_W)
		w = DB_W;
	if (h > (int)(DB_UV / DB_W))   /* the luma rows end where UV starts */
		h = DB_UV / DB_W;
	if (ys == DB_W && cs == DB_W && w == (int)DB_W) {
		memcpy(b->map, Y, (size_t)DB_W * h);
		memcpy(b->map + DB_UV, C, (size_t)DB_W * (h / 2));
		return;
	}
	for (int y = 0; y < h; y++)
		memcpy(b->map + (size_t)y * DB_W, Y + (size_t)y * ys, (size_t)w);
	for (int y = 0; y < h / 2; y++)
		memcpy(b->map + DB_UV + (size_t)y * DB_W, C + (size_t)y * cs, (size_t)w);
}

/* --zero-copy: sway gets the decoder's own frame buffers. Each is exported once
 * through /dev/soph-ion, kept by its physical address (as map_get keeps its
 * maps), and wrapped in an NV12 wl_buffer. While sway holds a buffer, its frame
 * is not released, so the decoder cannot write into it; on wl_buffer.release
 * the frame joins the release queue, for the next decode. */
typedef struct {
	uint64_t pa;              /* u64PhyAddr[0] */
	uint32_t uv, stride;      /* u64PhyAddr[1] - u64PhyAddr[0], u32Stride[0] */
	int fd, idx, busy;
	VIDEO_FRAME_INFO_S fi;    /* the frame on it, while busy */
} ZcBuf;
static ZcBuf g_zc[MAX_HELD];
static int g_nzc, g_ion = -1;

static void zc_released(void *tag, void *data)
{
	ZcBuf *z = tag;

	(void)data;
	if (!z->busy) {
		fprintf(stderr, "@warn zero-copy: release of pa %#" PRIx64 ", which sway did not hold\n", z->pa);
		return;
	}
	z->busy = 0;
	rel_push(&z->fi);
	g_releases++;
}

static int zc_open(void)
{
	g_ion = open("/dev/soph-ion", O_RDWR | O_CLOEXEC);
	if (g_ion < 0) {
		fprintf(stderr, "coda-cube: open /dev/soph-ion: %s (a soph_ion_compat without the exporter?)\n",
			strerror(errno));
		return -1;
	}
	return 0;
}

static void zc_close(void)
{
	for (int i = 0; i < g_nzc; i++)
		close(g_zc[i].fd);
	g_nzc = 0;
	if (g_ion >= 0)
		close(g_ion);
	g_ion = -1;
}

/* frame f's buffer, exported and added to the presenter on first sight */
static ZcBuf *zc_get(struct dmabuf_presenter *p, const VIDEO_FRAME_S *f)
{
	uint64_t pa = f->u64PhyAddr[0], uv = (uint64_t)f->u64PhyAddr[1] - pa;
	/* read-only: sway only reads it, and the decoder still uses the frame as a reference */
	struct soph_ion_export ex = { .phys = pa, .flags = O_CLOEXEC | SOPH_ION_EXPORT_RDONLY };
	ZcBuf *z;

	for (int i = 0; i < g_nzc; i++) {
		z = &g_zc[i];
		if (z->pa != pa)
			continue;
		if (z->uv != uv || z->stride != f->u32Stride[0] || z->busy) {
			fprintf(stderr, "coda-cube: frame at %#" PRIx64 ": UV +%" PRIu64 " stride %u%s, was UV +%u stride %u\n",
				pa, uv, f->u32Stride[0], z->busy ? " while sway holds it" : "", z->uv, z->stride);
			return NULL;
		}
		return z;
	}
	if ((int)f->u32Width != W || (int)f->u32Height != H || f->u32Stride[0] != f->u32Stride[1] ||
	    f->u64PhyAddr[1] <= pa || uv > UINT32_MAX || g_nzc == MAX_HELD) {
		fprintf(stderr, "coda-cube: frame at %#" PRIx64 " (%ux%u, strides %u/%u, UV +%" PRIu64 ", buffer %d): cannot present it as is\n",
			pa, f->u32Width, f->u32Height, f->u32Stride[0], f->u32Stride[1], uv, g_nzc);
		return NULL;
	}
	if (ioctl(g_ion, SOPH_ION_IOC_EXPORT, &ex)) {
		fprintf(stderr, "coda-cube: export of the frame at %#" PRIx64 ": %s\n", pa, strerror(errno));
		return NULL;
	}
	z = &g_zc[g_nzc++];   /* zc_close() closes the fd from here on */
	*z = (ZcBuf){ .pa = pa, .uv = (uint32_t)uv, .stride = f->u32Stride[0], .fd = ex.fd, .idx = -1 };
	/* the presenter's planes start at offset 0 of the fd: one frame per allocation */
	if (ex.offset || uv + (uint64_t)f->u32Stride[1] * (f->u32Height / 2) > ex.size) {
		fprintf(stderr, "coda-cube: frame at %#" PRIx64 " is at %llu in a %llu B ION allocation, UV at +%" PRIu64 "\n",
			pa, (unsigned long long)ex.offset, (unsigned long long)ex.size, uv);
		return NULL;
	}
	z->idx = dmabuf_presenter_add_buffer(p, ex.fd, z->uv, z->stride, z);
	if (z->idx < 0)
		return NULL;
	fprintf(stderr, "@zero-copy buffer %d: u64PhyAddr[0] %#" PRIx64 ", UV at +%u, stride %u, dma-buf of %llu B\n",
		g_nzc - 1, pa, z->uv, z->stride, (unsigned long long)ex.size);
	return z;
}

/* frame buffers sway holds now */
static int zc_held(void)
{
	int n = 0;

	for (int i = 0; i < g_nzc; i++)
		n += g_zc[i].busy;
	return n;
}

/*
 * coda-cube's frames are full-range BT.601: soph_drm's yuv_encoding and
 * yuv_range say so while they are on screen. Both, because the plane's own
 * COLOR_ENCODING and COLOR_RANGE are whatever the last DRM master left
 * (wlroots never sets them), which "auto" would follow. The parameters stay
 * open, so the old values go back at exit even after --user.
 */
#define NCOLOR 2
static const char *const COLOR_PARAM[NCOLOR] = {
	"/sys/module/soph_drm/parameters/yuv_encoding",
	"/sys/module/soph_drm/parameters/yuv_range",
};
static const char *const COLOR_NAME[NCOLOR] = { "yuv_encoding", "yuv_range" };
static const char *const COLOR_WANT[NCOLOR] = { "bt601", "full" };
static int g_color_fd[NCOLOR] = { -1, -1 };
static char g_color_saved[NCOLOR][16];

/* a module parameter's value, without the newline */
static int param_read(int fd, char *val, size_t n)
{
	ssize_t r = pread(fd, val, n - 1, 0);

	if (r <= 0)
		return -1;
	val[r] = 0;
	val[strcspn(val, "\n")] = 0;
	return 0;
}

static int param_write(int fd, const char *val)
{
	size_t n = strlen(val);

	return pwrite(fd, val, n, 0) == (ssize_t)n ? 0 : -1;
}

static void color_restore(void)
{
	for (int i = 0; i < NCOLOR; i++) {
		if (g_color_fd[i] < 0)
			continue;
		if (g_color_saved[i][0] && param_write(g_color_fd[i], g_color_saved[i]))
			fprintf(stderr, "coda-cube: cannot restore %s to %s: %s\n", COLOR_PARAM[i], g_color_saved[i],
				strerror(errno));
		else if (g_color_saved[i][0])
			fprintf(stderr, "@%s %s again\n", COLOR_NAME[i], g_color_saved[i]);
		close(g_color_fd[i]);
		g_color_fd[i] = -1;
		g_color_saved[i][0] = 0;
	}
}

static int color_set(void)
{
	atexit(color_restore);
	for (int i = 0; i < NCOLOR; i++) {
		char cur[sizeof(g_color_saved[i])];

		g_color_fd[i] = open(COLOR_PARAM[i], O_RDWR | O_CLOEXEC);
		if (g_color_fd[i] < 0 || param_read(g_color_fd[i], cur, sizeof(cur))) {
			fprintf(stderr, "coda-cube: cannot open %s: %s (soph_drm without NV12, or not root?)\n",
				COLOR_PARAM[i], strerror(errno));
			return -1;
		}
		if (!strcmp(cur, COLOR_WANT[i]))
			fprintf(stderr, "@warn %s is %s already: left by a killed coda-cube? It stays %s at exit; "
				"coda-cube --destroy sets it to auto\n", COLOR_NAME[i], cur, cur);
		if (param_write(g_color_fd[i], COLOR_WANT[i])) {
			fprintf(stderr, "coda-cube: cannot write %s: %s\n", COLOR_PARAM[i], strerror(errno));
			return -1;
		}
		memcpy(g_color_saved[i], cur, sizeof(cur));
		fprintf(stderr, "@%s %s -> %s\n", COLOR_NAME[i], cur, COLOR_WANT[i]);
	}
	return 0;
}

/* --destroy: a run that could not restore them (kill -9, a crash) left them set */
static void color_reset(void)
{
	for (int i = 0; i < NCOLOR; i++) {
		char cur[sizeof(g_color_saved[i])];
		int fd = open(COLOR_PARAM[i], O_RDWR | O_CLOEXEC);

		if (fd < 0)
			continue;
		if (!param_read(fd, cur, sizeof(cur)) && strcmp(cur, "auto")) {
			if (param_write(fd, "auto"))
				fprintf(stderr, "coda-cube: cannot write %s: %s\n", COLOR_PARAM[i], strerror(errno));
			else
				fprintf(stderr, "@%s %s -> auto\n", COLOR_NAME[i], cur);
		}
		close(fd);
	}
}

/*
 * --user: root up to here, for the decoder, /dev/soph-ion and the colour
 * parameters, then USER for everything else, the compositor's socket first
 * of all. Not dumpable from here on: the fds root opened stay out of reach of
 * USER's other processes.
 */
static int drop_to(const char *user)
{
	struct passwd *pw = getpwnam(user);
	char dir[64];

	if (!pw || !pw->pw_uid) {
		fprintf(stderr, "coda-cube: --user %s: %s\n", user, pw ? "that is root" : "no such user");
		return -1;
	}
	if (initgroups(pw->pw_name, pw->pw_gid) || setresgid(pw->pw_gid, pw->pw_gid, pw->pw_gid) ||
	    setresuid(pw->pw_uid, pw->pw_uid, pw->pw_uid)) {
		fprintf(stderr, "coda-cube: --user %s: %s\n", user, strerror(errno));
		return -1;
	}
	if (!setuid(0) || prctl(PR_SET_DUMPABLE, 0, 0, 0, 0)) {
		fprintf(stderr, "coda-cube: --user %s: root not dropped\n", user);
		return -1;
	}
	snprintf(dir, sizeof(dir), "/run/user/%u", (unsigned)pw->pw_uid);
	setenv("XDG_RUNTIME_DIR", dir, 0);
	fprintf(stderr, "@user %s: uid %u gid %u\n", user, (unsigned)getuid(), (unsigned)getgid());
	return 0;
}
#endif /* CODA_SDL */
#endif /* CODA_HW */

/* ------------------------------------------------------------ stats */
typedef struct {
	int n;
	double gen, ioctl, conv, present, proc, total, bytes, wait, aa, smooth;
	double hw, relwait, submit, framewait;
	int nhw, drops, npcm, nedge;
	unsigned shown, nrel;
	int held, nbuf;   /* --zero-copy: most frames sway held at once, buffers exported */
	uint64_t pa;      /* --zero-copy: u64PhyAddr[0] of the frame presented last */
} Acc;

static int g_dmabuf;   /* --dmabuf: conv is the copy into a dumb buffer; --zero-copy: the buffer lookup */

static __attribute__((unused)) void acc_print(const char *tag, const Acc *a, double secs)
{
	int n = a->n ? a->n : 1;
	fprintf(stderr, "%s fps %.1f | gen %.2f (aa %.2f smooth %.2f) ioctl %.2f (hw %.2f n=%d) %s %.2f present %.2f | frame %.2f ms | AU %.1f KB | edge MBs %.0f pcm %.0f | drops %d\n",
		tag, a->n / secs, 1e3 * a->gen / n, 1e3 * a->aa / n, 1e3 * a->smooth / n, 1e3 * a->ioctl / n,
		a->nhw ? a->hw / a->nhw / 1e3 : -1.0, a->nhw, g_zero_copy ? "lookup" : g_dmabuf ? "copy" : "conv", 1e3 * a->conv / n,
		1e3 * a->present / n, 1e3 * a->total / n, a->bytes / n / 1024, (double)a->nedge / n, (double)a->npcm / n,
		a->drops);
	if (a->wait > 0 || a->proc > 0)
		fprintf(stderr, "%s   (wait-for-worker %.2f ms, submit-to-worker %.2f ms, /proc read %.2f ms per frame)\n",
			tag, 1e3 * a->wait / n, 1e3 * a->submit / n, 1e3 * a->proc / n);
	if (g_zero_copy)
		fprintf(stderr, "%s   (zero-copy: shown %.1f fps, wait-for-frame %.2f ms per frame, %u releases, %d decoder buffers exported, sway held up to %d, last presented %#" PRIx64 ")\n",
			tag, a->shown / secs, 1e3 * a->framewait / n, a->nrel, a->nbuf, a->held, a->pa);
	else if (g_dmabuf)
		fprintf(stderr, "%s   (dma-buf: shown %.1f fps, wait-for-frame %.2f ms, wait-for-release %.2f ms per frame, %u releases)\n",
			tag, a->shown / secs, 1e3 * a->framewait / n, 1e3 * a->relwait / n, a->nrel);
}

/* --convert-test: NEON vs portable vs the float formula, and timing */
static int convert_test(int iters)
{
	const int w = W, h = H, dw = 1280, dh = 720;
	uint8_t *Y = malloc((size_t)w * h), *UV = malloc((size_t)w * h / 2);
	uint8_t *a = malloc((size_t)dw * dh * 4), *b = malloc((size_t)dw * dh * 4);
	int fail = 0;
	for (size_t i = 0; i < (size_t)w * h; i++) Y[i] = (uint8_t)(frand() * 256);
	for (size_t i = 0; i < (size_t)w * h / 2; i++) UV[i] = (uint8_t)(frand() * 256);
	int scale = dw >= 2 * w ? 2 : 1;
	for (int fmt = 0; fmt < 2; fmt++) {
		int bpp = fmt == FMT_BGR24 ? 3 : 4;
		size_t pitch = (size_t)dw * bpp;
		memset(a, 0x55, (size_t)dw * dh * 4);
		memset(b, 0x55, (size_t)dw * dh * 4);
		g_cvt_c = 0; nv12_to_surface(Y, (size_t)w, UV, (size_t)w, w, h, a, pitch, dw, dh, fmt, scale);
		g_cvt_c = 1; nv12_to_surface(Y, (size_t)w, UV, (size_t)w, w, h, b, pitch, dw, dh, fmt, scale);
		size_t diff = 0;
		for (size_t i = 0; i < pitch * dh; i++) diff += a[i] != b[i];
		/* float formula (ideaa.py yuv2rgb) at every source pixel */
		int maxe = 0, oy = (dh - h * scale) / 2;
		for (int y = 0; y < h; y++) {
			int dy = oy + y * scale;
			if (dy < 0 || dy >= dh) continue;
			for (int x = 0; x < w; x++) {
				double Yf = Y[(size_t)y * w + x], Uf = UV[(size_t)(y / 2) * w + (x & ~1)] - 128.0, Vf = UV[(size_t)(y / 2) * w + (x | 1)] - 128.0;
				double rgb[3] = {Yf + 1.402 * Vf + 0.5, Yf - 0.344 * Uf - 0.714 * Vf + 0.5, Yf + 1.772 * Uf + 0.5};
				const uint8_t *px = a + (size_t)dy * pitch + (size_t)x * scale * bpp;
				for (int q = 0; q < 3; q++) {
					int e = (int)(rgb[q] < 0 ? 0 : rgb[q] > 255 ? 255 : rgb[q]);
					int d = abs(px[2 - q] - e);
					if (d > maxe) maxe = d;
				}
			}
		}
		printf("convert %dx%d -> %dx%d %s scale %d: fast vs portable %zu differing bytes, max error vs float %d\n",
		       w, h, dw, dh, fmt == FMT_BGR24 ? "BGR24" : "XRGB8888", scale, diff, maxe);
		fail |= diff != 0 || maxe > 2;
		for (int c = 0; c < (getenv("CODA_CVT_FAST_ONLY") ? 1 : 2); c++) {
			if (c == 0 && fmt == FMT_XRGB && getenv("CODA_CVT_FAST_ONLY"))
				break;
			g_cvt_c = c;
			double t0 = now_s();
			for (int i = 0; i < iters; i++)
				nv12_to_surface(Y, (size_t)w, UV, (size_t)w, w, h, a, pitch, dw, dh, fmt, scale);
			printf("  %s: %.3f ms per frame (%d iterations)\n", c ? "portable" : "fast", 1e3 * (now_s() - t0) / iters, iters);
		}
	}
	g_cvt_c = 0;
	return fail;
}

/* ------------------------------------------------------------ main */
int main(int argc, char **argv)
{
	int deblock = 0, headless = 0, ref_ss = 4, qp = -1, abo = -99, no_convert = 0, pipeline = 0, hw_every = 4, frames = 60, bench = 0;
	int stats = getenv("CODA_STATS") && atoi(getenv("CODA_STATS")) > 0, destroy = 0, cvt_test = 0, mc_tests = 0, dmabuf = 0;
	int show_cursor = 0, zero_copy = 0, dpb_extra = -1, pace_release = 0;
	const char *run_as = NULL;
	long page_tests = 0;
	double seconds = 0, period = 8, pose = -1;
	const char *atlas_path = NULL, *tex_in = NULL, *stream_out = NULL, *info_out = NULL;
	const char *dump_tex = NULL, *dump_atlas = NULL, *cpu_model = NULL, *edges_out = NULL, *ref_out = NULL;
	enum { O_SIZE = 1000, O_PART, O_DEBLOCK, O_PAGES, O_TEX, O_DIST, O_PERIOD, O_ATLAS, O_TEXIN, O_SECONDS,
	       O_STATS, O_HEADLESS, O_NOCONV, O_PIPE, O_HWEVERY, O_UNCACHED, O_CHN, O_DESTROY, O_STREAM, O_FRAMES,
	       O_INFO, O_DUMPTEX, O_DUMPATLAS, O_BENCH, O_PCMTEST, O_CVTTEST, O_AA, O_QP, O_ABO, O_SMOOTH,
	       O_POSE, O_CPUMODEL, O_EDGESOUT, O_REFOUT, O_REFSS, O_MCTEST, O_NONEON, O_PAGETEST, O_DMABUF, O_SHOWCURSOR,
	       O_ZEROCOPY, O_DPBEXTRA, O_PACE, O_USER };
	static const struct option opts[] = {
		{"size", 1, 0, O_SIZE}, {"part", 1, 0, O_PART}, {"deblock", 0, 0, O_DEBLOCK}, {"pages", 1, 0, O_PAGES},
		{"tex", 1, 0, O_TEX}, {"dist", 1, 0, O_DIST}, {"period", 1, 0, O_PERIOD}, {"atlas", 1, 0, O_ATLAS},
		{"tex-in", 1, 0, O_TEXIN}, {"seconds", 1, 0, O_SECONDS}, {"stats", 0, 0, O_STATS},
		{"headless", 0, 0, O_HEADLESS}, {"no-convert", 0, 0, O_NOCONV}, {"pipeline", 0, 0, O_PIPE},
		{"hw-every", 1, 0, O_HWEVERY}, {"uncached", 0, 0, O_UNCACHED}, {"chn", 1, 0, O_CHN},
		{"destroy", 0, 0, O_DESTROY}, {"stream-out", 1, 0, O_STREAM}, {"frames", 1, 0, O_FRAMES},
		{"info-out", 1, 0, O_INFO}, {"dump-tex", 1, 0, O_DUMPTEX}, {"dump-atlas", 1, 0, O_DUMPATLAS},
		{"bench", 1, 0, O_BENCH}, {"pcm-test", 0, 0, O_PCMTEST}, {"convert-test", 1, 0, O_CVTTEST},
		{"aa", 0, 0, O_AA}, {"qp", 1, 0, O_QP}, {"ab-offset", 1, 0, O_ABO}, {"smooth", 1, 0, O_SMOOTH},
		{"pose", 1, 0, O_POSE}, {"cpu-model", 1, 0, O_CPUMODEL}, {"edges-out", 1, 0, O_EDGESOUT},
		{"ref-out", 1, 0, O_REFOUT}, {"ref-ss", 1, 0, O_REFSS}, {"mc-test", 1, 0, O_MCTEST}, {"no-neon", 0, 0, O_NONEON}, {"page-test", 1, 0, O_PAGETEST},
		{"dmabuf", 0, 0, O_DMABUF}, {"show-cursor", 0, 0, O_SHOWCURSOR}, {"zero-copy", 0, 0, O_ZEROCOPY},
		{"dpb-extra", 1, 0, O_DPBEXTRA}, {"pace", 1, 0, O_PACE}, {"user", 1, 0, O_USER}, {0, 0, 0, 0}};
	int opt;
	while ((opt = getopt_long(argc, argv, "", opts, NULL)) != -1) {
		switch (opt) {
		case O_SIZE:
			if (sscanf(optarg, "%dx%d", &W, &H) != 2) die("--size WxH");
			break;
		case O_PART: PART = atoi(optarg); break;
		case O_DEBLOCK: deblock = 1; break;
		case O_PAGES: K = atoi(optarg); break;
		case O_TEX: T = atoi(optarg); break;
		case O_DIST: DIST = (float)atof(optarg); break;
		case O_PERIOD: period = atof(optarg); break;
		case O_ATLAS: atlas_path = optarg; break;
		case O_TEXIN: tex_in = optarg; break;
		case O_SECONDS: seconds = atof(optarg); break;
		case O_STATS: stats = 1; break;
		case O_HEADLESS: headless = 1; break;
		case O_NOCONV: no_convert = 1; break;
		case O_PIPE: pipeline = 1; break;
		case O_HWEVERY: hw_every = atoi(optarg); break;
#ifdef CODA_HW
		case O_UNCACHED: g_uncached = 1; break;
		case O_CHN: g_chn = atoi(optarg); break;
#else
		case O_UNCACHED: case O_CHN: break;
#endif
		case O_DESTROY: destroy = 1; break;
		case O_STREAM: stream_out = optarg; break;
		case O_FRAMES: frames = atoi(optarg); break;
		case O_INFO: info_out = optarg; break;
		case O_DUMPTEX: dump_tex = optarg; break;
		case O_DUMPATLAS: dump_atlas = optarg; break;
		case O_BENCH: bench = atoi(optarg); break;
		case O_PCMTEST: g_pcm_test = 1; break;
		case O_CVTTEST: cvt_test = atoi(optarg); break;
		case O_AA: g_aa = 1; break;
		case O_QP: qp = atoi(optarg); break;
		case O_ABO: abo = atoi(optarg); break;
		case O_SMOOTH:
			g_smooth = !strcmp(optarg, "diag") ? 1 : !strcmp(optarg, "hv") ? 2 : !strcmp(optarg, "off") ? 0 : -1;
			if (g_smooth < 0) die("--smooth diag|hv|off");
			break;
		case O_POSE: pose = atof(optarg); break;
		case O_CPUMODEL: cpu_model = optarg; break;
		case O_EDGESOUT: edges_out = optarg; break;
		case O_REFOUT: ref_out = optarg; break;
		case O_REFSS: ref_ss = atoi(optarg); break;
		case O_MCTEST: mc_tests = atoi(optarg); break;
		case O_PAGETEST: page_tests = atol(optarg); break;
		case O_DMABUF: dmabuf = 1; break;
		case O_ZEROCOPY: zero_copy = dmabuf = 1; break;
		case O_DPBEXTRA:
			dpb_extra = atoi(optarg);
			if (dpb_extra < 0) die("--dpb-extra N: N >= 0");
			break;
		case O_SHOWCURSOR: show_cursor = 1; break;
		case O_PACE:
			pace_release = !strcmp(optarg, "release") ? 1 : !strcmp(optarg, "frame") ? 0 : -1;
			if (pace_release < 0) die("--pace frame|release");
			break;
		case O_USER: run_as = optarg; break;
		case O_NONEON:
#if defined(__aarch64__)
			g_neon = 0;
#endif
			break;
		default: fprintf(stderr, "see the header of coda-cube.c\n"); return 2;
		}
	}
	setvbuf(stderr, NULL, _IOLBF, 0);
	if (dmabuf && (headless || W != 1280 || H != 720))
		die("--dmabuf, --zero-copy: 1280x720 in a window only");
	if (run_as && !zero_copy)
		die("--user: with --zero-copy only, the one route that opens /dev/soph-ion before the drop");
	g_dmabuf = dmabuf;
	g_zero_copy = zero_copy;
	if (dpb_extra >= 0)
		g_dpb_extra = dpb_extra;
	else if (zero_copy) {   /* 2, or what still fits under the 16 references */
		int room = 16 - (1 + K + g_smooth);
		g_dpb_extra = room < 0 ? 0 : room < 2 ? room : 2;
	}

#ifdef CODA_HW
	if (destroy) {
#ifdef CODA_SDL
		color_reset();   /* first: it needs no codec, which a cleanup may have unloaded */
#endif
		if (vd_open_dev())
			return 2;
		int r = chn_exists() ? x_ioctl(CVI_VC_VDEC_DESTROY_CHN, NULL) : 0;
		fprintf(stderr, "@destroy-only chn=%d ret=%#x\n", g_chn, (unsigned)r);
		close(g_fd);
		return r ? 1 : 0;
	}
#else
	(void)destroy;
#endif

	if (cvt_test)
		return convert_test(cvt_test);
	if (mc_tests)
		return mc_test(mc_tests);
	if (page_tests)
		return page_test(page_tests);
	if (W % 16 || H % 16 || W > 1280 * 2 || W * H / 256 > MAXMB) die("size: multiples of 16, at most 4096 MBs");
	if (PART != 4 && PART != 8 && PART != 16) die("--part 4|8|16");
	if (K < 1 || K + g_smooth > 14) die("--pages 1..15 (with --smooth: 1..14 diag, 1..13 hv)");
	if (1 + K + g_smooth + g_dpb_extra > 16) die("--dpb-extra: max_num_ref_frames (1 + K + smooth + N) must stay at most 16");
	/* loop filter: --deblock alone is the research's QP 51, offsets +6 */
	g_dbk = deblock;
	g_qp = qp >= 0 ? qp : deblock ? 51 : 26;
	g_abo = abo != -99 ? abo : deblock ? 6 : 0;
	if (g_qp < 0 || g_qp > 51 || g_abo < -6 || g_abo > 6) die("--qp 0..51, --ab-offset -6..6");
	g_need_edges = edges_out != NULL;
	if (!T) T = W >= 1280 ? 224 : W >= 640 ? 112 : 80;
	WMB = W / 16; HMB = H / 16;
	B = K == 1 ? T + 2 * G : 2 * (int)ceilf(T * 1.41421356f * 0.5f) + 2 * G;
	for (int k = 0; k < K; k++) { CK[k] = cosf(6.2831853f * k / K); SK[k] = sinf(6.2831853f * k / K); }
	if (3 * B > W || 2 * B > H) die("the atlas slots do not fit the picture: smaller --tex");
	if (3 * B <= W - 16) { BLACKX = W - 12; BLACKY = H / 2; } else if (2 * B <= H - 16) { BLACKX = 8; BLACKY = 2 * B + 4; }
	else die("no room for the black patch");
#if defined(__aarch64__)
	int neon_on = g_neon;
#else
	int neon_on = 0;
#endif
	fprintf(stderr, "@config %dx%d part %d deblock %d qp %d ab-offset %d aa %d smooth %d neon %d K %d T %d B %d dist %.2f\n",
		W, H, PART, g_dbk, g_qp, g_abo, g_aa, g_smooth, neon_on, K, T, B, DIST);

	/* textures (only needed when the pages are built here) */
	uint8_t *tex = NULL;
	size_t texsz = (size_t)6 * T * T * 3;
	if (atlas_path && ref_out && !tex_in)
		die("--ref-out with --atlas needs --tex-in");
	if (!atlas_path || dump_tex || ref_out) {
		double t0 = now_s();
		tex = malloc(texsz);
		if (tex_in) {
			FILE *f = fopen(tex_in, "rb");
			if (!f || fread(tex, 1, texsz, f) != texsz) die("--tex-in: cannot read 6*T*T*3 bytes");
			fclose(f);
		} else {
			make_textures(T, tex);
		}
		fprintf(stderr, "@textures %.0f ms\n", 1e3 * (now_s() - t0));
	}
	if (dump_tex) {
		FILE *f = fopen(dump_tex, "wb");
		if (!f || fwrite(tex, 1, texsz, f) != texsz) die("--dump-tex");
		fclose(f);
		if (!dump_atlas) return 0;
	}
	size_t fs = (size_t)W * H * 3 / 2;
	PageSrc ps = {NULL, tex, malloc(fs)};
	if (atlas_path && !(ps.atlas = fopen(atlas_path, "rb"))) die("--atlas: cannot open");
	if (dump_atlas) {
		FILE *f = fopen(dump_atlas, "wb");
		double t0 = now_s();
		for (int k = 0; k < K; k++)
			if (!f || fwrite(get_page(&ps, k), 1, fs, f) != fs) die("--dump-atlas");
		fclose(f);
		fprintf(stderr, "@atlas %d pages %.0f ms\n", K, 1e3 * (now_s() - t0));
		return 0;
	}

	Gen g;
	gen_init(&g, info_out != NULL || cpu_model != NULL);
	if (cpu_model || g_aa)
		g_pcmstore = malloc((size_t)WMB * HMB * 384);
	/* pages in memory: the AA hook samples them, the CPU model decodes from them */
	int keep_pages = g_aa || cpu_model;

	if (bench) {
		double best = 1e9, sum = 0;
		if (keep_pages) {   /* the AA hook samples the pages */
			uint8_t *bl = calloc(fs, 1);
			memset(bl + (size_t)W * H, 128, (size_t)W * H / 2);
			PGY[0] = bl; PGU[0] = bl + (size_t)W * H; PGV[0] = bl + (size_t)W * H * 5 / 4;
			for (int k = 0; k < K; k++) {
				uint8_t *c = malloc(fs);
				memcpy(c, get_page(&ps, k), fs);
				PGY[k + 1] = c; PGU[k + 1] = c + (size_t)W * H; PGV[k + 1] = c + (size_t)W * H * 5 / 4;
			}
		}
		size_t bytes = 0;
		for (int r = 0; r < bench; r++) {
			double t0 = now_s();
			bytes = 0;
			for (int f = 0; f < frames; f++) {
				gen_frame(&g, (float)f / frames * 6.2831853f, f);
				bytes += g.len;
			}
			double dt = (now_s() - t0) / frames;
			sum += dt;
			if (dt < best) best = dt;
		}
		printf("bench %dx%d part %d deblock %d aa %d smooth %d K %d: %.1f us/frame best, %.1f us/frame mean (%d x %d frames), %.1f B/frame\n",
		       W, H, PART, g_dbk, g_aa, g_smooth, K, best * 1e6, sum / bench * 1e6, bench, frames, (double)bytes / frames);
		return 0;
	}

	/* the access units that set the decoder up: SPS + PPS + black IDR, then K pages */
	uint8_t *black = malloc(fs), *pagebuf = malloc((size_t)W * H * 3 + 65536);   /* + emulation prevention */
	uint8_t *pagerbsp = malloc((size_t)W * H * 2 + 4096);
	memset(black, 0, (size_t)W * H);
	memset(black + (size_t)W * H, 128, (size_t)W * H / 2);
	size_t au0 = sps_pps(pagebuf);
	au0 += pcm_page(pagebuf + au0, pagerbsp, black, black + (size_t)W * H, black + (size_t)W * H * 5 / 4, 0);

	if (stream_out) {
		FILE *out = fopen(stream_out, "wb"), *info = info_out ? fopen(info_out, "wb") : NULL;
		if (!out || (info_out && !info)) die("cannot open --stream-out/--info-out");
		fwrite(pagebuf, 1, au0, out);
		PGY[0] = black; PGU[0] = black + (size_t)W * H; PGV[0] = black + (size_t)W * H * 5 / 4;
		for (int k = 0; k < K; k++) {
			const uint8_t *p = get_page(&ps, k);
			size_t n = pcm_page(pagebuf, pagerbsp, p, p + (size_t)W * H, p + (size_t)W * H * 5 / 4, k + 1);
			fwrite(pagebuf, 1, n, out);
			if (keep_pages) {
				uint8_t *c = malloc(fs);
				memcpy(c, p, fs);
				PGY[k + 1] = c; PGU[k + 1] = c + (size_t)W * H; PGV[k + 1] = c + (size_t)W * H * 5 / 4;
			}
		}
		FILE *fm = cpu_model ? fopen(cpu_model, "wb") : NULL, *fe = edges_out ? fopen(edges_out, "wb") : NULL;
		FILE *fr = ref_out ? fopen(ref_out, "wb") : NULL;
		uint8_t *m0 = malloc(fs), *m1 = malloc(fs), *m2 = malloc(fs);
		if ((cpu_model && !fm) || (edges_out && !fe) || (ref_out && !fr)) die("cannot open an output");
		double tg = 0, taa = 0, tsm = 0;
		size_t bytes = 0;
		int npcm = 0, nedge = 0;
		for (int f = 0; f < frames; f++) {
			double t0 = now_s();
			gen_frame(&g, pose >= 0 ? (float)pose : (float)f / frames * 6.2831853f, f);
			tg += now_s() - t0;
			taa += g.t_aa;
			tsm += g.t_smooth;
			bytes += g.len;
			npcm += g.npcm;
			nedge += g.nedge;
			fwrite(g.au, 1, g.len, out);
			if (info)
				write_info(info, &g);
			if (fm) {
				uint8_t *Yp = m0, *Up = m0 + (size_t)W * H, *Vp = m0 + (size_t)W * H * 5 / 4;
				model_p(&g, Yp, Up, Vp);
				fwrite(m0, 1, fs, fm);
				if (g_smooth == 1) {
					model_b(Yp, Up, Vp, m1, m1 + (size_t)W * H, m1 + (size_t)W * H * 5 / 4, 2, 2, -2, -2);
					fwrite(m1, 1, fs, fm);
				} else if (g_smooth == 2) {
					model_b(Yp, Up, Vp, m1, m1 + (size_t)W * H, m1 + (size_t)W * H * 5 / 4, 2, 0, -2, 0);
					model_b(m1, m1 + (size_t)W * H, m1 + (size_t)W * H * 5 / 4, m2, m2 + (size_t)W * H, m2 + (size_t)W * H * 5 / 4, 0, 2, 0, -2);
					fwrite(m1, 1, fs, fm);
					fwrite(m2, 1, fs, fm);
				}
			}
			if (fe) {
				int32_t n = g_nedge;
				fwrite(&n, 4, 1, fe);
				for (int32_t m = 0; m < WMB * HMB; m++)
					if (g_edge[m]) fwrite(&m, 4, 1, fe);
			}
			if (fr) {
				ref_render(g.F, tex, ref_ss, m0, m0 + (size_t)W * H, m0 + (size_t)W * H * 5 / 4);
				fwrite(m0, 1, fs, fr);
			}
		}
		fclose(out);
		if (info) fclose(info);
		if (fm) fclose(fm);
		if (fe) fclose(fe);
		if (fr) fclose(fr);
		fprintf(stderr, "@stream %s: %d frames x %d AUs, gen %.1f us/frame (aa %.1f, smooth %.1f), %.1f B/frame, %.1f edge MBs, %.1f I_PCM MBs per frame\n",
			stream_out, frames, g.nau, tg / frames * 1e6, taa / frames * 1e6, tsm / frames * 1e6, (double)bytes / frames,
			(double)nedge / frames, (double)npcm / frames);
		return 0;
	}

#ifndef CODA_HW
	(void)headless; (void)no_convert; (void)pipeline; (void)hw_every; (void)seconds; (void)period; (void)stats;
	(void)show_cursor; (void)run_as; (void)pace_release;
	die("built without the decoder (CODA_HW): only --stream-out, --bench, --dump-*");
#else
	struct sigaction sa;
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_sig;
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGHUP, &sa, NULL);
	signal(SIGPIPE, SIG_IGN);
	atexit(vd_close);

	/* What root opens, before the window: the colour parameters, /dev/soph-ion and the
	 * decoder device (no channel yet, so a refused window leaves none behind). */
#ifdef CODA_SDL
	SDL_Window *win = NULL;
	struct dmabuf_presenter *pres = NULL;
	if (dmabuf && color_set())
		return 1;
	if (zero_copy && (zc_open() || vd_open_dev()))
		return 1;
	if (run_as && drop_to(run_as))
		return 1;
	if (!headless) {
		SDL_SetHint(SDL_HINT_NO_SIGNAL_HANDLERS, "1");
		/* hints only: the session's environment wins (SWAYENV imports it) */
		SDL_SetHint(SDL_HINT_FRAMEBUFFER_ACCELERATION, "0");
		SDL_SetHint("SDL_VIDEO_WAYLAND_SHM_FORMAT", "SDL_PIXELFORMAT_BGR24");
		/* every frame redraws every pixel: present the shm buffers themselves */
		SDL_SetHint("SDL_VIDEO_WAYLAND_FRAMEBUFFER_NO_COPY", "1");
		if (!SDL_Init(SDL_INIT_VIDEO)) {
			fprintf(stderr, "coda-cube: SDL_Init: %s\n", SDL_GetError());
			return 1;
		}
		win = SDL_CreateWindow("coda-cube", 1280, 720, SDL_WINDOW_FULLSCREEN);
		if (!win) {
			fprintf(stderr, "coda-cube: SDL_CreateWindow: %s\n", SDL_GetError());
			SDL_Quit();
			return 1;
		}
		SDL_SyncWindow(win);
		if (!show_cursor)
			SDL_HideCursor();
	}
	if (dmabuf) {
		pres = dmabuf_presenter_create(win, 1280, 720, zero_copy ? zc_released : db_released, NULL);
		if (!pres || (!zero_copy && db_open(pres))) {
			dmabuf_presenter_destroy(pres);
			db_close();
			zc_close();
			SDL_DestroyWindow(win);
			SDL_Quit();
			return 1;
		}
	} else if (win) {
		SDL_Surface *s = SDL_GetWindowSurface(win);
		if (!s || (s->format != SDL_PIXELFORMAT_BGR24 && s->format != SDL_PIXELFORMAT_XRGB8888)) {
			fprintf(stderr, "coda-cube: window surface %s, need BGR24 or XRGB8888\n",
				s ? SDL_GetPixelFormatName(s->format) : SDL_GetError());
			SDL_DestroyWindow(win);
			SDL_Quit();
			return 1;
		}
		fprintf(stderr, "@window %dx%d %s pitch %d\n", s->w, s->h, SDL_GetPixelFormatName(s->format), s->pitch);
	}
#else
	(void)show_cursor; (void)run_as; (void)pace_release;
	if (!headless) die("built without SDL (CODA_SDL): use --headless");
#endif

	/* decoder setup */
	size_t bsz = (2 * au0 + 0xffff) & ~(size_t)0xffff;
	if (bsz < (1u << 20)) bsz = 1u << 20;
	if (vd_open(bsz)) return 4;
	double t_setup = now_s();
	{
		VIDEO_FRAME_INFO_S fi;
		int got = 0;
		double tb = 0;
		for (int k = 0; k <= K && !g_stop; k++) {
			size_t n = au0;
			if (k > 0) {
				double t0 = now_s();
				const uint8_t *p = get_page(&ps, k - 1);
				n = pcm_page(pagebuf, pagerbsp, p, p + (size_t)W * H, p + (size_t)W * H * 5 / 4, k);
				if (keep_pages) {
					uint8_t *c = malloc(fs);
					if (!c) die("out of memory for the pages");
					memcpy(c, p, fs);
					PGY[k] = c; PGU[k] = c + (size_t)W * H; PGV[k] = c + (size_t)W * H * 5 / 4;
				}
				tb += now_s() - t0;
			}
			if (vd_send(pagebuf, n, (uint64_t)k))
				fprintf(stderr, "@warn send page %d failed\n", k);
			if (vd_get_ms(&fi, 200) == 0) {
				got++;
				vd_release(&fi);
				while (vd_get_ms(&fi, 0) == 0) {
					got++;
					vd_release(&fi);
				}
			}
		}
		fprintf(stderr, "@pages %d sent, %d frames back, %.0f ms (building pages %.0f ms)\n",
			K + 1, got, 1e3 * (now_s() - t_setup), 1e3 * tb);
		if (got != K + 1)
			fprintf(stderr, "@warn expected %d page frames\n", K + 1);
	}
	if (!keep_pages)
		free(black);
	PGY[0] = black; PGU[0] = black + (size_t)W * H; PGV[0] = black + (size_t)W * H * 5 / 4;
	free(pagebuf);
	free(pagerbsp);
	free(ps.buf);
	free(tex);
	if (ps.atlas) fclose(ps.atlas);

	/* the frame loop */
	uint8_t *hbuf = NULL;
	size_t hpitch = 1280 * 3;
	if (headless && !no_convert) hbuf = malloc(hpitch * 720);
	Gen g2;   /* --pipeline: a second access-unit buffer */
	Gen *cur = &g, *nxt = &g;
	if (pipeline) {
		g2 = g;
		g2.rbsp = malloc(g.cap);
		g2.au = malloc(g.cap * 3 / 2);
		nxt = &g2;
	}
	Worker wk;
	memset(&wk, 0, sizeof(wk));
	if (pipeline) {
		pthread_mutex_init(&wk.mu, NULL);
		pthread_cond_init(&wk.cv, NULL);
		if (pthread_create(&wk.th, NULL, worker_main, &wk)) die("pthread_create");
	}
	Acc iv = {0}, all = {0};
#ifdef CODA_SDL
	unsigned frames0 = 0, rel0 = 0;   /* --dmabuf: frame callbacks and releases counted so far */
#endif
	double t_start = now_s(), t_iv = t_start, t_warm = 0;
	long fnum = 0;
	int dry = 0;
	const double TWO_PI = 6.283185307179586;
#define ANGLE(ts) (pose >= 0 ? (float)pose : (float)(fmod(((ts) - t_start) / period, 4.0) * TWO_PI))
	if (pipeline) {
		gen_frame(cur, ANGLE(now_s()), 0);
		worker_submit(&wk, cur, 0, hw_every > 0);
		gen_frame(nxt, ANGLE(now_s()), 1);
	}
	while (!g_stop) {
		double t0 = now_s(), t1, t2, t3, t4, t5, tproc = 0, twait = 0, tio = 0, hw = -1;
		VIDEO_FRAME_INFO_S fi;
		int ok;
		size_t aulen;
		const Gen *gs;   /* the generator state of the frame generated in this iteration */
		if (!pipeline) {
			gen_frame(cur, ANGLE(t0), fnum);
			gs = cur;
			aulen = cur->len;
			t1 = now_s();
			rel_flush();   /* zero-copy: the frames whose buffers sway released */
			ok = decode_aus(cur->au, cur->auoff, cur->aulen, cur->nau, (uint64_t)fnum, &fi,
					hw_every > 0 && fnum % hw_every == 0, &hw);
			t2 = now_s();
			tio = t2 - t1;
		} else {
			/* frame n from the worker; n+1 is already generated (in nxt) */
			t1 = t0;
			worker_wait(&wk);
			twait = now_s() - t1;
			tio = wk.t_ioctl;
			hw = wk.hw;
			ok = wk.ok;
			fi = wk.fi;
			gs = cur;
			aulen = cur->len;
			t2 = now_s();
		}
		t3 = now_s();
		double t3b = t3;
#ifdef CODA_SDL
		int slot = -1;
		ZcBuf *zc = NULL;
#endif
		if (ok && zero_copy) {
			dry = 0;
#ifdef CODA_SDL
			/* nothing to map, copy or convert: the frame's own buffer goes to sway */
			zc = zc_get(pres, &fi.stVFrame);
			if (!zc) {
				if (!pipeline)   /* pipelined, the worker's last picture (this one) is released below */
					vd_release(&fi);
				break;
			}
#endif
		} else if (ok) {
			dry = 0;
			const VIDEO_FRAME_S *f = &fi.stVFrame;
			const uint8_t *Yp = map_get(f->u64PhyAddr[0], (size_t)f->u32Stride[0] * f->u32Height);
			const uint8_t *Cp = map_get(f->u64PhyAddr[1], (size_t)f->u32Stride[1] * (f->u32Height / 2));
			if (!Yp || !Cp) {
				fprintf(stderr, "coda-cube: cannot map frame at %#" PRIx64 "\n", (uint64_t)f->u64PhyAddr[0]);
				if (!pipeline)   /* pipelined, the worker's last picture (this one) is released below */
					vd_release(&fi);
				break;
			}
			uint8_t *dst = hbuf;
			size_t pitch = hpitch;
			int dw = 1280, dh = 720, fmt = FMT_BGR24;
#ifdef CODA_SDL
			SDL_Surface *s = NULL;
			if (dmabuf) {
				/* the dumb buffer sway released, then copy; the frame goes back to the VDEC right after */
				slot = db_get(pres);
				t3b = now_s();
				if (slot < 0) {
					if (!pipeline)   /* pipelined, the worker's last picture (this one) is released below */
						vd_release(&fi);
					break;
				}
				frame_sync(Yp, Cp, DMA_BUF_SYNC_START);
				db_copy(&g_db[slot], Yp, f->u32Stride[0], Cp, f->u32Stride[1], (int)f->u32Width, (int)f->u32Height);
				frame_sync(Yp, Cp, DMA_BUF_SYNC_END);
			} else if (win) {
				s = SDL_GetWindowSurface(win);   /* no-copy: pixels move every update */
				if (!s) {
					fprintf(stderr, "coda-cube: surface: %s\n", SDL_GetError());
					if (!pipeline)
						vd_release(&fi);
					break;
				}
				dst = s->pixels;
				pitch = (size_t)s->pitch;
				dw = s->w;
				dh = s->h;
				fmt = s->format == SDL_PIXELFORMAT_BGR24 ? FMT_BGR24 : FMT_XRGB;
			}
#endif
			if (dst) {
				int scale = (dw >= 2 * W) ? 2 : 1;
				frame_sync(Yp, Cp, DMA_BUF_SYNC_START);
				nv12_to_surface(Yp, f->u32Stride[0], Cp, f->u32Stride[1], (int)f->u32Width, (int)f->u32Height,
						dst, pitch, dw, dh, fmt, scale);
				frame_sync(Yp, Cp, DMA_BUF_SYNC_END);
			}
			if (!pipeline)
				vd_release(&fi);
		} else {
			iv.drops++;
			all.drops++;
			if (++dry >= 8) {
				fprintf(stderr, "coda-cube: 8 frames in a row without a picture: VPU hung? (vpu-reset.sh)\n");
				break;
			}
		}
		/* the woken worker usually preempts this thread for its ioctls: time that apart */
		double tsub = now_s();
		if (pipeline) {   /* the worker releases frame n (zero-copy: what sway released), then decodes n+1 */
			if (ok && !zero_copy)
				rel_push(&fi);
			worker_submit(&wk, nxt, (uint64_t)(fnum + 1), hw_every > 0 && (fnum + 1) % hw_every == 0);
			Gen *tmp = cur; cur = nxt; nxt = tmp;
		}
		t4 = now_s();
		double tframe = 0;   /* waiting for sway to show the last frame */
#ifdef CODA_SDL
		unsigned shown = 0, nrel = 0;
		int held = 0;
		if (win) {
			if (dmabuf) {
				/* Paced on the display: a frame goes up once sway has shown the last
				 * one, so none is drawn only to be replaced unseen. The decoder works on
				 * the next frame meanwhile. Not drawn at all (another workspace, say),
				 * the surface gets a frame every 100 ms. */
				if (!pace_release && (zc || slot >= 0)) {
					if (dmabuf_presenter_wait_frame(pres, 100) < 0)
						g_stop = 1;   /* the display is gone; the present below says so */
					tframe = now_s() - t4;
				}
				if (zc) {   /* sway holds the frame until it releases the buffer */
					zc->busy = 1;
					zc->fi = fi;
					if (dmabuf_presenter_present(pres, zc->idx))
						g_stop = 1;   /* the display is gone */
				} else if (slot >= 0) {
					g_db[slot].busy = 1;
					if (dmabuf_presenter_present(pres, g_db[slot].idx))
						g_stop = 1;   /* the display is gone */
				}
			} else if (ok && !SDL_UpdateWindowSurface(win)) {
				fprintf(stderr, "coda-cube: UpdateWindowSurface: %s\n", SDL_GetError());
			}
			SDL_Event ev;
			while (SDL_PollEvent(&ev)) {
				if (ev.type == SDL_EVENT_QUIT) g_stop = 1;
				if (ev.type == SDL_EVENT_KEY_DOWN && ev.key.key == SDLK_ESCAPE) g_stop = 1;
			}
			if (dmabuf) {
				dmabuf_presenter_dispatch(pres);
				shown = dmabuf_presenter_frames(pres) - frames0;
				frames0 += shown;
				nrel = g_releases - rel0;
				rel0 += nrel;
				if (zero_copy)
					held = zc_held();
			}
		}
#endif
		t5 = now_s();
		double t6 = t5;
		if (pipeline) {   /* frame n+2, while the worker decodes n+1 */
			gen_frame(nxt, ANGLE(t5), fnum + 2);
			t6 = now_s();
		}
		Acc *as[2] = {&iv, &all};
		for (int q = 0; q < 2; q++) {
			Acc *a = as[q];
			if (q == 1 && t5 - t_start < 2.0)   /* the overall summary skips the first 2 s */
				continue;
			if (q == 1 && !t_warm) t_warm = t0;
			a->n++;
			a->gen += pipeline ? t6 - t5 : t1 - t0;
			a->ioctl += tio;
			a->wait += twait;
			a->proc += tproc;
			a->conv += tsub - t3b;
			a->submit += t4 - tsub;
			a->relwait += t3b - t3;
#ifdef CODA_SDL
			a->shown += shown;
			a->nrel += nrel;
			if (held > a->held)
				a->held = held;
			if (zc)
				a->pa = zc->pa;
			a->nbuf = g_nzc;
#endif
			a->present += t5 - t4 - tframe;
			a->framewait += tframe;
			a->total += t6 - t0;
			a->bytes += (double)aulen;
			a->npcm += gs->npcm;
			a->nedge += gs->nedge;
			a->aa += gs->t_aa;
			a->smooth += gs->t_smooth;
			if (hw >= 0) { a->hw += hw; a->nhw++; }
		}
		fnum++;
		if (stats && t5 - t_iv >= 1.0) {
			acc_print("@stats", &iv, t5 - t_iv);
			memset(&iv, 0, sizeof(iv));
			t_iv = t5;
		}
		if (seconds > 0 && t5 - t_start >= seconds)
			break;
	}
	if (pipeline) {
		worker_wait(&wk);
		if (wk.ok) vd_release(&wk.fi);
		pthread_mutex_lock(&wk.mu);
		wk.quit = 1;
		pthread_cond_broadcast(&wk.cv);
		pthread_mutex_unlock(&wk.mu);
		pthread_join(wk.th, NULL);
	}
	rel_flush();   /* zero-copy: what sway released since the last decode; the rest goes with the channel */
	double tend = now_s();
	fprintf(stderr, "@done frames %ld in %.1f s (stop=%d) late pictures %d, drained %d\n", fnum, tend - t_start, (int)g_stop, g_late, g_stale);
	if (all.n)
		acc_print("@summary", &all, tend - t_warm);
	unmap_all();
	vd_close();
#ifdef CODA_SDL
	if (win) {
		dmabuf_presenter_destroy(pres);
		SDL_DestroyWindow(win);
		SDL_Quit();
	}
	if (dmabuf) {
		db_close();
		zc_close();
		color_restore();
	}
#endif
	free(hbuf);
	return 0;
#endif /* CODA_HW */
}
