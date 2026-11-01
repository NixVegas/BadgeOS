/* badgedemo.c: a looping 720p demoscene prod for the badge.
 *
 *   video : procedural effects rendered at 640x360, 2x point-scaled to 1280x720
 *           into whatever scanout buffer we were given (RGB planar, RGB packed,
 *           or a plain Linux fbdev), so it can drive either the lt8912b-bringup
 *           framebuffer or /dev/fb0 unchanged.
 *   audio : the softsynth in synth.h, out via ALSA (which on this badge lands on
 *           I2S -> LT8912B -> HDMI audio).
 *
 * It never exits: the song loops and the part sequencer wraps with it.
 *
 *   ./badgedemo --dump out.rgb --frames 600     # off-target render, no hardware
 *   ./badgedemo --fb /dev/fb0                   # linux framebuffer
 *   ./badgedemo --planar /sys/kernel/debug/lt8912b_bringup/fbmap --audio hw:0,0
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <errno.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <math.h>

#include "synth.h"
#include "song.h"
#include "effects.h"

#define OW 1280
#define OH 720

static volatile sig_atomic_t stop;
static void on_sig(int s) { (void)s; stop = 1; }

/* output targets */
enum out_kind { OUT_NONE, OUT_DUMP, OUT_PACKED, OUT_PLANAR };

struct out {
	enum out_kind kind;
	uint8_t *mem;           /* mapped scanout */
	size_t   len;
	int      fd;
	uint32_t stride;        /* bytes per line, packed only */
};

/* 640x360 XRGB -> 1280x720, duplicating both axes. */
static void blit_packed(const uint32_t *src, struct out *o)
{
	for (int y = 0; y < IH; y++) {
		const uint32_t *s = src + (size_t)y * IW;
		uint32_t *d0 = (uint32_t *)(o->mem + (size_t)(y * 2) * o->stride);
		uint32_t *d1 = (uint32_t *)(o->mem + (size_t)(y * 2 + 1) * o->stride);

		for (int x = 0; x < IW; x++) {
			uint32_t p = s[x];

			d0[x * 2] = d0[x * 2 + 1] = p;
			d1[x * 2] = d1[x * 2 + 1] = p;
		}
	}
}

/* Three 1280x720 8-bit planes back to back: R, G, B (DISP fmt=2 RGB_PLANAR). */
static void blit_planar(const uint32_t *src, struct out *o)
{
	const size_t plane = (size_t)OW * OH;
	uint8_t *R = o->mem, *G = o->mem + plane, *B = o->mem + 2 * plane;

	for (int y = 0; y < IH; y++) {
		const uint32_t *s = src + (size_t)y * IW;
		size_t r0 = (size_t)(y * 2) * OW, r1 = r0 + OW;

		for (int x = 0; x < IW; x++) {
			uint32_t p = s[x];
			uint8_t  r = (uint8_t)(p >> 16), g = (uint8_t)(p >> 8), b = (uint8_t)p;
			size_t   i0 = r0 + (size_t)x * 2, i1 = r1 + (size_t)x * 2;

			R[i0] = R[i0 + 1] = R[i1] = R[i1 + 1] = r;
			G[i0] = G[i0 + 1] = G[i1] = G[i1 + 1] = g;
			B[i0] = B[i0 + 1] = B[i1] = B[i1 + 1] = b;
		}
	}
}

/* 8x8 font for the scroller (A-Z 0-9 and a few marks) */
static const uint8_t FONT[40][8] = {
#define C(a,b,c,d,e,f,g,h) {a,b,c,d,e,f,g,h}
C(0x18,0x3c,0x66,0x66,0x7e,0x66,0x66,0), C(0x7c,0x66,0x66,0x7c,0x66,0x66,0x7c,0),
C(0x3c,0x66,0x60,0x60,0x60,0x66,0x3c,0), C(0x78,0x6c,0x66,0x66,0x66,0x6c,0x78,0),
C(0x7e,0x60,0x60,0x7c,0x60,0x60,0x7e,0), C(0x7e,0x60,0x60,0x7c,0x60,0x60,0x60,0),
C(0x3c,0x66,0x60,0x6e,0x66,0x66,0x3e,0), C(0x66,0x66,0x66,0x7e,0x66,0x66,0x66,0),
C(0x3c,0x18,0x18,0x18,0x18,0x18,0x3c,0), C(0x1e,0x0c,0x0c,0x0c,0x6c,0x6c,0x38,0),
C(0x66,0x6c,0x78,0x70,0x78,0x6c,0x66,0), C(0x60,0x60,0x60,0x60,0x60,0x60,0x7e,0),
C(0x63,0x77,0x7f,0x6b,0x63,0x63,0x63,0), C(0x66,0x76,0x7e,0x7e,0x6e,0x66,0x66,0),
C(0x3c,0x66,0x66,0x66,0x66,0x66,0x3c,0), C(0x7c,0x66,0x66,0x7c,0x60,0x60,0x60,0),
C(0x3c,0x66,0x66,0x66,0x6e,0x6c,0x36,0), C(0x7c,0x66,0x66,0x7c,0x78,0x6c,0x66,0),
C(0x3e,0x60,0x60,0x3c,0x06,0x06,0x7c,0), C(0x7e,0x18,0x18,0x18,0x18,0x18,0x18,0),
C(0x66,0x66,0x66,0x66,0x66,0x66,0x3c,0), C(0x66,0x66,0x66,0x66,0x66,0x3c,0x18,0),
C(0x63,0x63,0x63,0x6b,0x7f,0x77,0x63,0), C(0x66,0x66,0x3c,0x18,0x3c,0x66,0x66,0),
C(0x66,0x66,0x66,0x3c,0x18,0x18,0x18,0), C(0x7e,0x06,0x0c,0x18,0x30,0x60,0x7e,0),
C(0x3c,0x66,0x6e,0x76,0x66,0x66,0x3c,0), C(0x18,0x38,0x18,0x18,0x18,0x18,0x7e,0),
C(0x3c,0x66,0x06,0x0c,0x30,0x60,0x7e,0), C(0x7e,0x0c,0x18,0x0c,0x06,0x66,0x3c,0),
C(0x0c,0x1c,0x3c,0x6c,0x7e,0x0c,0x0c,0), C(0x7e,0x60,0x7c,0x06,0x06,0x66,0x3c,0),
C(0x3c,0x60,0x60,0x7c,0x66,0x66,0x3c,0), C(0x7e,0x06,0x0c,0x18,0x30,0x30,0x30,0),
C(0x3c,0x66,0x66,0x3c,0x66,0x66,0x3c,0), C(0x3c,0x66,0x66,0x3e,0x06,0x06,0x3c,0),
C(0,0,0,0,0,0,0,0),                      C(0x18,0x18,0x18,0x18,0x18,0,0x18,0),
C(0x00,0x66,0xff,0xff,0x7e,0x3c,0x18,0), C(0x08,0x1c,0x3e,0x7f,0x3e,0x1c,0x08,0),
#undef C
};
static int glyph(char c)
{
	if (c >= 'A' && c <= 'Z') return c - 'A';
	if (c >= 'a' && c <= 'z') return c - 'a';
	if (c >= '0' && c <= '9') return 26 + (c - '0');
	if (c == '!') return 37;
	if (c == '*') return 38;
	if (c == '.') return 39;
	return 36;                      /* space */
}

static const char SCROLLTEXT[] =
	"NIX VEGAS PRESENTS ... A BADGE PRODUCTION ... "
	"SG2000 MIPI DSI INTO AN LT8912B BRIDGE AT 720P60 ... "
	"THE SCREEN WAS BLACK FOR A VERY LONG TIME ... "
	"IT WAS THE SYNC POLARITY ALL ALONG ... "
	"GREETINGS TO EVERYONE STILL READING REGISTER DUMPS AT 3AM ... "
	"WRAP ... ";

static void draw_scroller(uint32_t *fb, float t, int yb, uint32_t col)
{
	int len = (int)sizeof(SCROLLTEXT) - 1;
	int px  = (int)(t * 150.0f);

	for (int x = 0; x < IW; x++) {
		int gx = px + x;
		int ci = (gx >> 4) % len;           /* 16 px per glyph */
		int cx = (gx >> 1) & 7;
		const uint8_t *g = FONT[glyph(SCROLLTEXT[ci])];
		int wob = (int)(fsin((float)x * 0.02f + t * 2.2f) * 9.0f);

		for (int r = 0; r < 8; r++) {
			if (!(g[r] & (0x80 >> cx)))
				continue;
			for (int k = 0; k < 2; k++) {
				int y = yb + wob + r * 2 + k;

				if (y >= 0 && y < IH)
					fb[(size_t)y * IW + x] = col;
			}
		}
	}
}

/* part sequencer */
/* div: render this part every Nth frame and hold the canvas in between. The
 * raymarcher measures ~63 ms/frame on the badge (15.9 fps), so it runs at half
 * the 30 fps content rate rather than dragging the whole prod down. */
struct part { void (*fn)(uint32_t *, float, float); float secs; const char *name; int scroll; int div; };

static const struct part PARTS[] = {
	{ fx_plasma,   16.0f, "plasma",    0, 1 },
	{ fx_stars,    14.0f, "starfield", 1, 1 },
	{ fx_tunnel,   18.0f, "tunnel",    0, 1 },
	{ fx_roto,     16.0f, "rotozoom",  1, 1 },
	{ fx_raymarch, 22.0f, "raymarch",  0, 2 },
	{ fx_tunnel,   12.0f, "tunnel II", 1, 1 },
};
#define NPARTS ((int)(sizeof(PARTS) / sizeof(PARTS[0])))

static double now_s(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

int main(int argc, char **argv)
{
	struct out o = { .kind = OUT_NONE, .fd = -1, .stride = OW * 4 };
	const char *audio_dev = NULL, *dump = NULL, *fbpath = NULL, *planarpath = NULL;
	long max_frames = -1;
	int  force_part = -1, fps = 30;   /* 30 fps content: one A53 core cannot
	                                   * sustain 60 for the heavier parts, and
	                                   * the scanout is 60 Hz regardless. */
	static uint32_t canvas[IW * IH];
	struct synth sy;
	FILE *dumpf = NULL;
	int audio_fd = -1;
	double t0;
	long frame = 0;
	float total = 0.0f;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--dump") && i + 1 < argc)        dump = argv[++i];
		else if (!strcmp(argv[i], "--frames") && i + 1 < argc) max_frames = atol(argv[++i]);
		else if (!strcmp(argv[i], "--fb") && i + 1 < argc)     fbpath = argv[++i];
		else if (!strcmp(argv[i], "--planar") && i + 1 < argc) planarpath = argv[++i];
		else if (!strcmp(argv[i], "--audio") && i + 1 < argc)  audio_dev = argv[++i];
		else if (!strcmp(argv[i], "--part") && i + 1 < argc)   force_part = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--fps") && i + 1 < argc)    fps = atoi(argv[++i]);
		else { fprintf(stderr, "usage: %s [--dump f] [--frames n] [--fb dev] [--planar dev] [--audio dev]\n", argv[0]); return 2; }
	}

	signal(SIGINT, on_sig);
	signal(SIGTERM, on_sig);

	trig_init();
	pal_init();
	tunnel_init();
	plasma_init();
	raymarch_init();
	stars_init();
	synth_init(&sy, &SONG);
	for (int i = 0; i < NPARTS; i++)
		total += PARTS[i].secs;

	if (dump) {
		dumpf = fopen(dump, "wb");
		if (!dumpf) { perror("dump"); return 1; }
		o.kind = OUT_DUMP;
	} else if (planarpath || fbpath) {
		const char *p = planarpath ? planarpath : fbpath;

		o.fd = open(p, O_RDWR);
		if (o.fd < 0) { perror(p); return 1; }
		o.len = planarpath ? (size_t)OW * OH * 3 : (size_t)OW * OH * 4;
		o.mem = mmap(NULL, o.len, PROT_READ | PROT_WRITE, MAP_SHARED, o.fd, 0);
		if (o.mem == MAP_FAILED) { perror("mmap"); return 1; }
		o.kind = planarpath ? OUT_PLANAR : OUT_PACKED;
	}

	if (audio_dev) {
		audio_fd = open(audio_dev, O_WRONLY);
		if (audio_fd < 0)
			fprintf(stderr, "audio: %s: %s (continuing silent)\n", audio_dev, strerror(errno));
	}

	fprintf(stderr, "badgedemo: %d parts, %.0fs loop, %s out%s\n", NPARTS, total,
		o.kind == OUT_DUMP ? "dump" : o.kind == OUT_PLANAR ? "planar" :
		o.kind == OUT_PACKED ? "packed" : "null",
		audio_fd >= 0 ? ", audio on" : "");

	t0 = now_s();
	while (!stop && (max_frames < 0 || frame < max_frames)) {
		double wall = (o.kind == OUT_DUMP) ? (double)frame / (double)fps : now_s() - t0;
		float  show = (float)fmod(wall, (double)total);
		int    pi = 0;
		float  acc = 0.0f, beat, punch;
		int16_t abuf[(SR / 15) * 2];   /* enough for fps >= 15 */

		if (force_part >= 0) {
			pi = force_part % NPARTS;
		} else {
			while (pi < NPARTS - 1 && show >= acc + PARTS[pi].secs) { acc += PARTS[pi].secs; pi++; }
		}

		/* beat phase from the song clock, so visuals punch with the kick */
		beat  = (float)fmod(wall * ((double)SONG.bpm / 60.0), 1.0);
		punch = 1.0f - beat;
		punch *= punch * punch;

		if (frame % PARTS[pi].div == 0)
			PARTS[pi].fn(canvas, show - acc, punch);
		if (PARTS[pi].scroll)
			draw_scroller(canvas, show, IH - 46, 0x00ffffff);

		switch (o.kind) {
		case OUT_PLANAR: blit_planar(canvas, &o); break;
		case OUT_PACKED: blit_packed(canvas, &o); break;
		case OUT_DUMP:   fwrite(canvas, sizeof(canvas), 1, dumpf); break;
		default: break;
		}

		/* 800 frames @48k == one 60 Hz video frame */
		synth_render(&sy, abuf, SR / fps);
		if (audio_fd >= 0)
			(void)!write(audio_fd, abuf, sizeof(abuf));

		frame++;
		if (o.kind != OUT_DUMP) {
			double target = t0 + (double)frame / (double)fps, d = target - now_s();

			if (d > 0.0) {
				struct timespec ts = { (time_t)d, (long)((d - (double)(time_t)d) * 1e9) };
				nanosleep(&ts, NULL);
			}
		}
		if ((frame % 300) == 0)
			fprintf(stderr, "  %5ld frames  t=%6.1fs  part=%-10s\n", frame, wall, PARTS[pi].name);
	}

	if (dumpf) fclose(dumpf);
	if (o.mem) munmap(o.mem, o.len);
	if (o.fd >= 0) close(o.fd);
	if (audio_fd >= 0) close(audio_fd);
	fprintf(stderr, "badgedemo: %ld frames\n", frame);
	return 0;
}
