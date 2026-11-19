/*
 * badge-camera: the camera's live picture in a window on the panel, which also reads
 * QR codes. A Wi-Fi code (WIFI:S:...;P:...;;) offers to join that network on a tap.
 *
 *   badge-camera [--user USER]
 *   badge-camera --cleanup                       free a pool a killed run left behind
 *
 * It starts as root for the camera devices and, with --user, drops to USER before it
 * connects to the compositor; the descriptors it opened keep working.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <grp.h>
#include <pthread.h>
#include <pwd.h>
#include <signal.h>
#include <systemd/sd-daemon.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <dlfcn.h>
#include <execinfo.h>

#include <SDL3/SDL.h>

#include "convert.h"
#include "pipeline.h"
#include "qrread.h"
#include "wifiqr.h"

/*
 * The QR reader works from a gray copy of the frame, or from the whole frame when the
 * channel is already giving us something smaller. These are the limits one buffer is
 * kept for; the size actually used follows the frame's shape.
 *
 * Half the sensor each way, so every gray pixel is the mean of four: the frames that
 * read at this size and not from a thinner copy are the ones taken in a moving hand,
 * where the averaging is what quiets them enough. The copy is 0.9 MB.
 */
#define QR_MAX_W 1280
#define QR_MAX_H 720

static double now(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

/* Set by SIGTERM or SIGINT; the capture loops check it and tear the pipeline down. */
static volatile sig_atomic_t terminate;

static void on_terminate(int sig)
{
	(void)sig;
	terminate = 1;
}


/* ------------------------------------------------------------ QR worker */

static struct {
	pthread_mutex_t lock;
	pthread_cond_t cond;
	uint8_t *image;        /* w x h, owned by the worker while busy */
	unsigned w, h;         /* the size of the picture in it */
	bool busy, quit;
	char text[256];        /* last decoded payload, NUL-terminated */
	size_t len;
	unsigned seq;          /* bumped per decoded code */
} qr = { .lock = PTHREAD_MUTEX_INITIALIZER, .cond = PTHREAD_COND_INITIALIZER };

static void *qr_worker(void *arg)
{
	char text[sizeof(qr.text)];

	(void)arg;
	pthread_mutex_lock(&qr.lock);
	for (;;) {
		while (!qr.busy && !qr.quit)
			pthread_cond_wait(&qr.cond, &qr.lock);
		if (qr.quit)
			break;
		pthread_mutex_unlock(&qr.lock);

		/* The picture and its size are the worker's while busy is set. */
		double t0 = now();
		size_t n = qr_read(qr.image, qr.w, qr.h, text, sizeof(text));
		double ms = (now() - t0) * 1000;

		/* Never the text itself: a Wi-Fi code carries the network's password. */
		if (n)
			fprintf(stderr, "@qr read a code of %zu bytes in %.0f ms\n", n, ms);

		pthread_mutex_lock(&qr.lock);
		if (n) {
			memcpy(qr.text, text, n + 1);
			qr.len = n;
			qr.seq++;
		}
		qr.busy = false;
	}
	pthread_mutex_unlock(&qr.lock);
	return NULL;
}

/* ------------------------------------------------------------ joining */

enum join_state { JOIN_NONE, JOIN_RUNNING, JOIN_DONE, JOIN_FAILED };
static _Atomic int join_state = JOIN_NONE;
/* How far a running join has got, for the strip, and why a failed one failed. */
enum join_stage { STAGE_RADIO, STAGE_LOOKING, STAGE_CONNECTING };
static _Atomic int join_stage = STAGE_RADIO;
static _Atomic bool join_unseen;
static struct wifi_qr join_net;

static int run(char *const argv[])
{
	pid_t pid = fork();
	int status;

	if (pid < 0)
		return -1;
	if (!pid) {
		execvp(argv[0], argv);
		_exit(127);
	}
	while (waitpid(pid, &status, 0) < 0 && errno == EINTR)
		;
	return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

/* Turns the Wi-Fi setting on (the same unit Settings starts) and joins with nmcli,
 * retrying while the radio comes up. */
static void *join_worker(void *arg)
{
	(void)arg;
	char *start[] = { "systemctl", "--no-ask-password", "start", "nix-badge-wifi.service", NULL };
	char *connect[12];
	int n = 0;

	join_stage = STAGE_RADIO;
	run(start);
	connect[n++] = "nmcli";
	connect[n++] = "--wait";
	connect[n++] = "30";
	connect[n++] = "device";
	connect[n++] = "wifi";
	connect[n++] = "connect";
	connect[n++] = join_net.ssid;
	if (join_net.password[0]) {
		connect[n++] = "password";
		connect[n++] = join_net.password;
	}
	if (join_net.hidden) {
		connect[n++] = "hidden";
		connect[n++] = "yes";
	}
	connect[n] = NULL;

	/*
	 * NetworkManager connects only to a network in its scan list, and that list can be
	 * a minute or two old: a phone's hotspot switched on a moment ago is not in it, and
	 * every attempt fails at once with "no network with SSID" until NetworkManager next
	 * scans by itself. So each attempt asks for a scan aimed at this network first, and
	 * gives the answer a few seconds to arrive.
	 */
	char *rescan[] = { "nmcli", "device", "wifi", "rescan", "ssid", join_net.ssid, NULL };
	double until = now() + 60;
	int r;

	join_unseen = false;
	do {
		join_stage = STAGE_LOOKING;
		run(rescan);
		sleep(4);
		join_stage = STAGE_CONNECTING;
		r = run(connect);
		/* nmcli's exit status 10: no such network, as against a join that failed. */
		join_unseen = r == 10;
		if (r)
			sleep(1);
	} while (r && now() < until);
	join_state = r ? JOIN_FAILED : JOIN_DONE;
	return NULL;
}

/* ------------------------------------------------------------ privileges */

static int drop_to(const char *user)
{
	struct passwd *pw = getpwnam(user);
	char dir[64], bus[96];

	if (!pw || !pw->pw_uid) {
		fprintf(stderr, "badge-camera: --user %s: %s\n", user, pw ? "that is root" : "no such user");
		return -1;
	}
	if (initgroups(pw->pw_name, pw->pw_gid) || setresgid(pw->pw_gid, pw->pw_gid, pw->pw_gid) ||
	    setresuid(pw->pw_uid, pw->pw_uid, pw->pw_uid)) {
		fprintf(stderr, "badge-camera: --user %s: %s\n", user, strerror(errno));
		return -1;
	}
	if (!setuid(0) || prctl(PR_SET_DUMPABLE, 0, 0, 0, 0)) {
		fprintf(stderr, "badge-camera: --user %s: root not dropped\n", user);
		return -1;
	}
	snprintf(dir, sizeof(dir), "/run/user/%u", (unsigned)pw->pw_uid);
	snprintf(bus, sizeof(bus), "unix:path=%s/bus", dir);
	setenv("XDG_RUNTIME_DIR", dir, 1);
	setenv("DBUS_SESSION_BUS_ADDRESS", bus, 1);
	setenv("HOME", pw->pw_dir, 1);
	return 0;
}

/* ------------------------------------------------------------ window */

/* Copy write-combined rows into cached memory before averaging. `step` thins
 * luma and chroma equally; callers account for the resulting vertical scale.
 * Return the original frame if allocation fails. */
static struct cam_frame frame_cache(const struct cam_frame *f, unsigned step)
{
	static uint8_t *buf;
	static size_t cap;
	unsigned rows = f->height / step, crows = f->height / 2 / step;
	size_t ysz = (size_t)f->stride * rows, csz = (size_t)f->stride * crows;
	struct cam_frame c = *f;
	unsigned i;

	if (cap < ysz + csz) {
		uint8_t *n = realloc(buf, ysz + csz);

		if (!n)
			return c;
		buf = n;
		cap = ysz + csz;
	}
	if (step == 1) {
		memcpy(buf, f->y, ysz);
#if !CAMERA_GRAYSCALE
		memcpy(buf + ysz, f->vu, csz);
#endif
	} else {
		for (i = 0; i < rows; i++)
			memcpy(buf + (size_t)i * f->stride, f->y + (size_t)i * step * f->stride,
			       f->stride);
#if !CAMERA_GRAYSCALE
		for (i = 0; i < crows; i++)
			memcpy(buf + ysz + (size_t)i * f->stride,
			       f->vu + (size_t)i * step * f->stride, f->stride);
#endif
	}
#if CAMERA_GRAYSCALE
	/* The gray preview: neutral chroma, so the frame's is not read. */
	memset(buf + ysz, 128, csz);
#endif
	c.y = buf;
	c.vu = buf + ysz;
	c.height = rows;
	return c;
}

static void text(SDL_Renderer *r, float scale, float x, float y, const char *s)
{
	SDL_SetRenderScale(r, scale, scale);
	SDL_SetRenderDrawColor(r, 255, 255, 255, 255);
	SDL_RenderDebugText(r, x / scale, y / scale, s);
	SDL_SetRenderScale(r, 1, 1);
}

/*
 * The strip along the bottom of the picture: what the scanner wants, or what it found.
 * Returns where it drew, which is also where a tap is taken.
 */
static SDL_FRect draw_banner(SDL_Renderer *ren, int tw, int th, const char *first,
			     const char *second, bool opaque)
{
	float s = tw < 400 ? 1 : 2, lh = 10 * s; /* the half display size */
	float h = (second[0] ? 2.5f : 1.3f) * lh + 4;
	SDL_FRect bg = { 0, th - h, (float)tw, h };

	/* Opaque over a picture that is not being redrawn, or old text shows through. */
	SDL_SetRenderDrawBlendMode(ren, opaque ? SDL_BLENDMODE_NONE : SDL_BLENDMODE_BLEND);
	SDL_SetRenderDrawColor(ren, 0, 0, 0, opaque ? 255 : 170);
	SDL_RenderFillRect(ren, &bg);
	text(ren, s, 6, bg.y + 4, first);
	if (second[0])
		text(ren, s, 6, bg.y + 4 + lh * 1.2f, second);
	/* The renderer only queues; this is what puts the strip on the surface. */
	SDL_FlushRenderer(ren);
	return bg;
}

static int window_loop(void)
{
	SDL_Window *win;
	SDL_Renderer *ren = NULL;
	SDL_Surface *surf = NULL;
	int tw = 0, th = 0;
	pthread_t qt;
	unsigned seen = 0;
	double last_qr = 0, shown_until = 0;

	struct cam_frame fc = { 0 };
	char banner[2][96] = { "", "" };
	bool offer = false, paused = false;
	int drawn_stage = -1;
	SDL_FRect offer_rect = { 0 };

	qr.w = QR_MAX_W;
	qr.h = QR_MAX_H;
	qr.image = malloc((size_t)QR_MAX_W * QR_MAX_H);
	if (!qr.image || pthread_create(&qt, NULL, qr_worker, NULL)) {
		fprintf(stderr, "badge-camera: QR reader thread failed\n");
		return 1;
	}

	SDL_SetAppMetadata("Scan QR", "1.0", "badge-camera");
	SDL_SetHint(SDL_HINT_APP_ID, "badge-camera");
	SDL_SetHintWithPriority(SDL_HINT_FRAMEBUFFER_ACCELERATION, "0", SDL_HINT_OVERRIDE);
	SDL_SetHintWithPriority("SDL_VIDEO_WAYLAND_SHM_FORMAT", "SDL_PIXELFORMAT_XRGB8888",
				SDL_HINT_OVERRIDE);
	if (!SDL_Init(SDL_INIT_VIDEO)) {
		fprintf(stderr, "badge-camera: SDL: %s\n", SDL_GetError());
		return 1;
	}
	/* Draw the preview into the window surface to avoid streaming-texture copies.
 * The software renderer draws only the banner. */
	win = SDL_CreateWindow("Scan QR", 552, 320, SDL_WINDOW_RESIZABLE);
	if (!win) {
		fprintf(stderr, "badge-camera: window: %s\n", SDL_GetError());
		return 1;
	}

	sd_notify(0, "READY=1");
	bool quit = false;
	while (!quit && !terminate) {
		SDL_Event e;
		while (SDL_PollEvent(&e)) {
			float x = -1, y = -1;
			if (e.type == SDL_EVENT_QUIT ||
			    (e.type == SDL_EVENT_KEY_DOWN && e.key.key == SDLK_ESCAPE))
				quit = true;
			else if (e.type == SDL_EVENT_MOUSE_BUTTON_DOWN) {
				x = e.button.x;
				y = e.button.y;
			} else if (e.type == SDL_EVENT_FINGER_DOWN) {
				int ww, wh;
				SDL_GetWindowSize(win, &ww, &wh);
				x = e.tfinger.x * ww;
				y = e.tfinger.y * wh;
			}
			if (x >= 0 && offer && join_state != JOIN_RUNNING && y >= offer_rect.y) {
				pthread_t jt;
				join_state = JOIN_RUNNING;
				if (pthread_create(&jt, NULL, join_worker, NULL))
					join_state = JOIN_FAILED;
				else
					pthread_detach(jt);
			}
		}

		/* Pause capture during Wi-Fi startup to avoid CPU contention with driver loading
 * and NetworkManager. Keep the last frame visible. */
		if (join_state == JOIN_RUNNING) {
			static const char *const doing[] = {
				[STAGE_RADIO] = "Turning Wi-Fi on",
				[STAGE_LOOKING] = "Looking for the network",
				[STAGE_CONNECTING] = "Connecting",
			};
			int stage = join_stage;

			if (ren && (!paused || stage != drawn_stage)) {
				char line[96];

				snprintf(line, sizeof(line), "Joining %.40s...", join_net.ssid);
				draw_banner(ren, tw, th, line, doing[stage], true);
				SDL_UpdateWindowSurface(win);
				drawn_stage = stage;
			}
			paused = true;
			SDL_Delay(100);
			continue;
		}
		if (paused) {
			/* Long enough to read how it went. */
			paused = false;
			shown_until = now() + 8;
		}

		struct cam_frame f = { 0 };

		if (cam_get(&f, 200))
			continue;

		/* The compositor hands back a new surface whenever the window changes size. */
		SDL_Surface *s = SDL_GetWindowSurface(win);

		if (!s) {
			fprintf(stderr, "badge-camera: window surface: %s\n", SDL_GetError());
			cam_release(&f);
			break;
		}
		if ((s->format != SDL_PIXELFORMAT_XRGB8888 && s->format != SDL_PIXELFORMAT_ARGB8888) ||
		    s->pitch < s->w * 4 || s->pitch % 4) {
			fprintf(stderr, "badge-camera: unsupported window surface format\n");
			cam_release(&f);
			break;
		}
		if (s != surf || s->w != tw || s->h != th) {
			if (ren)
				SDL_DestroyRenderer(ren);
			ren = SDL_CreateSoftwareRenderer(s);
			if (!ren) {
				fprintf(stderr, "badge-camera: renderer: %s\n", SDL_GetError());
				cam_release(&f);
				break;
			}
			surf = s;
			tw = s->w;
			th = s->h;
		}

		/*
		 * Four or more sensor rows to a panel row leaves plenty to average over
		 * even taking every second one, and halves what has to cross the bus.
		 */
		unsigned step = th > 0 && f.height / (unsigned)th >= 4 ? 2 : 1;

		/* Cache all luma rows for a reader frame; both consumers then reuse
		 * that copy instead of reading the uncached sensor mapping twice. */
		pthread_mutex_lock(&qr.lock);
		bool read_qr = !qr.busy && now() - last_qr > 0.5;
		pthread_mutex_unlock(&qr.lock);
		if (read_qr)
			step = 1;
		fc = frame_cache(&f, step);

		if (!SDL_MUSTLOCK(s) || SDL_LockSurface(s)) {
			nv21_cover_box(fc.y, fc.vu, fc.stride, fc.width, fc.height, step,
				       s->pixels, (unsigned)s->pitch / 4, (unsigned)tw,
				       (unsigned)th);
			if (SDL_MUSTLOCK(s))
				SDL_UnlockSurface(s);
		}

		/* Hand the worker a new picture twice a second when it is idle. */
		double t = now();
		pthread_mutex_lock(&qr.lock);
		if (read_qr) {
			/* Half the sensor's size, or the whole frame if it is already
			 * smaller. */
			unsigned qw = f.width > QR_MAX_W ? QR_MAX_W : f.width;
			unsigned qh = (unsigned)((uint64_t)qw * f.height / f.width);

			if (qh > QR_MAX_H)
				qh = QR_MAX_H;
			qr.w = qw;
			qr.h = qh;
			nv21_luma_box(fc.y, fc.stride, fc.width, fc.height, qr.image, qr.w, qr.h);
			qr.busy = true;
			last_qr = t;
			pthread_cond_signal(&qr.cond);
		}
		if (qr.seq != seen) {
			struct wifi_qr net;
			seen = qr.seq;
			if (wifiqr_parse(qr.text, qr.len, &net)) {
				/* The same code still in view must not wipe how its join went. */
				if (join_state == JOIN_NONE ||
				    (join_state != JOIN_RUNNING && strcmp(net.ssid, join_net.ssid))) {
					join_net = net;
					join_state = JOIN_NONE;
				}
				offer = true;
			} else if (!offer) {
				snprintf(banner[0], sizeof(banner[0]), "QR code:");
				snprintf(banner[1], sizeof(banner[1]), "%.60s", qr.text);
			}
			shown_until = t + 8;
		}
		pthread_mutex_unlock(&qr.lock);
		cam_release(&f);

		if (offer) {
			switch (join_state) {
			case JOIN_NONE:
				snprintf(banner[0], sizeof(banner[0]), "Wi-Fi: %.40s", join_net.ssid);
				snprintf(banner[1], sizeof(banner[1]), "Tap here to join");
				break;
			case JOIN_RUNNING:
				snprintf(banner[0], sizeof(banner[0]), "Joining %.40s...", join_net.ssid);
				banner[1][0] = 0;
				shown_until = t + 8;
				break;
			case JOIN_DONE:
				snprintf(banner[0], sizeof(banner[0]), "Connected to %.36s", join_net.ssid);
				banner[1][0] = 0;
				break;
			case JOIN_FAILED:
				snprintf(banner[0], sizeof(banner[0]),
					 join_unseen ? "%.34s is not in range" : "Could not join %.34s",
					 join_net.ssid);
				snprintf(banner[1], sizeof(banner[1]), "Tap here to retry");
				break;
			}
		}
		if (t > shown_until && join_state != JOIN_RUNNING) {
			offer = false;
			banner[0][0] = banner[1][0] = 0;
			if (join_state != JOIN_RUNNING)
				join_state = JOIN_NONE;
		}


		if (banner[0][0])
			offer_rect = draw_banner(ren, tw, th, banner[0], banner[1], false);
		else
			draw_banner(ren, tw, th, "Point the camera at a QR code", "", false);
		SDL_UpdateWindowSurface(win);
	}

	pthread_mutex_lock(&qr.lock);
	qr.quit = true;
	pthread_cond_signal(&qr.cond);
	pthread_mutex_unlock(&qr.lock);
	pthread_join(qt, NULL);
	if (ren)
		SDL_DestroyRenderer(ren);
	SDL_DestroyWindow(win);
	SDL_Quit();
	return 0;
}

int main(int argc, char **argv)
{
	struct cam_options opt = { .i2c_bus = -1, .i2c_controller = "4040000.i2c", .tnr = true };
	const char *user = NULL;
	int r;

	for (int i = 1; i < argc; i++) {
		const char *a = argv[i];
		if (!strcmp(a, "--user") && i + 1 < argc)
			user = argv[++i];
		else if (!strcmp(a, "--cleanup"))
			return cam_cleanup() ? 1 : 0;
		else {
			fprintf(stderr, "usage: badge-camera [--user USER]\n"
					"       badge-camera --cleanup\n");
			return 2;
		}
	}

	/*
	 * Check termination while waiting for capture as well as in SDL's event loop,
	 * so a stop releases the vendor buffer pool even before a window opens.
	 */
	signal(SIGTERM, on_terminate);
	signal(SIGINT, on_terminate);
	signal(SIGPIPE, SIG_IGN);
	if (cam_open(&opt))
		return 1;
	fprintf(stderr, "@camera up\n");
	if (user && drop_to(user)) {
		cam_close();
		return 1;
	}
	r = window_loop();
	cam_close();
	return r;
}
