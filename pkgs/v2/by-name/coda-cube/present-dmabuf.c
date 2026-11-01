/*
 * NV12 dma-bufs on an SDL window's wl_surface (see present-dmabuf.h).
 *
 * Everything the presenter creates lives on its own wl_event_queue, so SDL's
 * event pump never dispatches it and the presenter never dispatches SDL's
 * events. Requests on SDL's wl_surface (attach, damage, commit, the opaque
 * region) go straight through SDL's proxy; the frame callback is made through
 * a wrapper of it, so its done event lands on the private queue.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <drm/drm_fourcc.h>
#include <wayland-client.h>

#include "linux-dmabuf-v1-client-protocol.h"
#include "present-dmabuf.h"

#define MAXBUF 32

struct pbuf {
	struct dmabuf_presenter *p;
	struct wl_buffer *wl;
	void *tag;
};

struct dmabuf_presenter {
	struct wl_display *display;       /* SDL's */
	struct wl_surface *surface;       /* SDL's */
	struct wl_event_queue *queue;
	struct wl_display *display_wrapper;
	struct wl_surface *surface_wrapper;
	struct wl_registry *registry;
	struct wl_compositor *compositor;
	struct zwp_linux_dmabuf_v1 *dmabuf;
	struct wl_callback *frame_cb;
	unsigned frames;
	int width, height, dead, nbuf;
	void (*on_release)(void *tag, void *data);
	void *data;
	struct pbuf buf[MAXBUF];
};

/* The connection is unusable from here on: say why, once. */
static int lost(struct dmabuf_presenter *p, const char *what)
{
	if (!p->dead) {
		int e = wl_display_get_error(p->display);
		if (e == EPROTO) {
			const struct wl_interface *iface = NULL;
			uint32_t id = 0, code = wl_display_get_protocol_error(p->display, &iface, &id);
			fprintf(stderr, "present-dmabuf: %s: protocol error %u on %s@%u\n", what, code,
				iface ? iface->name : "?", id);
		} else {
			fprintf(stderr, "present-dmabuf: %s: %s\n", what, strerror(e ? e : errno));
		}
		p->dead = 1;
	}
	return -1;
}

static void reg_global(void *data, struct wl_registry *reg, uint32_t name, const char *iface, uint32_t version)
{
	struct dmabuf_presenter *p = data;

	if (!strcmp(iface, zwp_linux_dmabuf_v1_interface.name) && version >= 4 && !p->dmabuf)
		p->dmabuf = wl_registry_bind(reg, name, &zwp_linux_dmabuf_v1_interface, 4);
	else if (!strcmp(iface, wl_compositor_interface.name) && !p->compositor)
		p->compositor = wl_registry_bind(reg, name, &wl_compositor_interface, 1);
}

static void reg_global_remove(void *data, struct wl_registry *reg, uint32_t name)
{
	(void)data; (void)reg; (void)name;
}

static const struct wl_registry_listener reg_listener = { reg_global, reg_global_remove };

/* v4 sends no format or modifier events (formats come with feedback) */
static void dmabuf_format(void *data, struct zwp_linux_dmabuf_v1 *d, uint32_t format)
{
	(void)data; (void)d; (void)format;
}

static void dmabuf_modifier(void *data, struct zwp_linux_dmabuf_v1 *d, uint32_t format, uint32_t hi, uint32_t lo)
{
	(void)data; (void)d; (void)format; (void)hi; (void)lo;
}

static const struct zwp_linux_dmabuf_v1_listener dmabuf_listener = { dmabuf_format, dmabuf_modifier };

static void buf_release(void *data, struct wl_buffer *wl)
{
	struct pbuf *b = data;

	(void)wl;
	b->p->on_release(b->tag, b->p->data);
}

static const struct wl_buffer_listener buf_listener = { buf_release };

static void frame_done(void *data, struct wl_callback *cb, uint32_t ms)
{
	struct dmabuf_presenter *p = data;

	(void)ms;
	wl_callback_destroy(cb);
	p->frame_cb = NULL;
	p->frames++;
}

static const struct wl_callback_listener frame_listener = { frame_done };

struct dmabuf_presenter *dmabuf_presenter_create(SDL_Window *win, int width, int height,
						 void (*on_release)(void *tag, void *data), void *data)
{
	SDL_PropertiesID props = SDL_GetWindowProperties(win);
	struct wl_display *d = SDL_GetPointerProperty(props, SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, NULL);
	struct wl_surface *s = SDL_GetPointerProperty(props, SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, NULL);
	struct dmabuf_presenter *p;
	struct wl_region *region;

	if (!d || !s) {
		const char *drv = SDL_GetCurrentVideoDriver();
		fprintf(stderr, "present-dmabuf: not a Wayland window (SDL video driver %s)\n", drv ? drv : "none");
		return NULL;
	}
	p = calloc(1, sizeof(*p));
	if (!p)
		return NULL;
	p->display = d;
	p->surface = s;
	p->width = width;
	p->height = height;
	p->on_release = on_release;
	p->data = data;
	p->queue = wl_display_create_queue(d);
	p->display_wrapper = wl_proxy_create_wrapper(d);
	p->surface_wrapper = wl_proxy_create_wrapper(s);
	if (!p->queue || !p->display_wrapper || !p->surface_wrapper) {
		fprintf(stderr, "present-dmabuf: cannot create the private queue\n");
		goto fail;
	}
	wl_proxy_set_queue((struct wl_proxy *)p->display_wrapper, p->queue);
	wl_proxy_set_queue((struct wl_proxy *)p->surface_wrapper, p->queue);
	p->registry = wl_display_get_registry(p->display_wrapper);
	wl_registry_add_listener(p->registry, &reg_listener, p);
	if (wl_display_roundtrip_queue(d, p->queue) < 0) {
		lost(p, "registry");
		goto fail;
	}
	if (!p->dmabuf || !p->compositor) {
		fprintf(stderr, "present-dmabuf: the compositor offers no %s\n",
			p->dmabuf ? "wl_compositor" : "zwp_linux_dmabuf_v1 v4");
		goto fail;
	}
	zwp_linux_dmabuf_v1_add_listener(p->dmabuf, &dmabuf_listener, p);
	region = wl_compositor_create_region(p->compositor);
	wl_region_add(region, 0, 0, width, height);
	wl_surface_set_opaque_region(s, region);
	wl_region_destroy(region);
	return p;
fail:
	dmabuf_presenter_destroy(p);
	return NULL;
}

int dmabuf_presenter_add_buffer(struct dmabuf_presenter *p, int fd, uint32_t uv_offset, uint32_t stride, void *tag)
{
	const uint64_t mod = DRM_FORMAT_MOD_LINEAR;
	struct zwp_linux_buffer_params_v1 *params;
	struct pbuf *b;

	if (p->dead || p->nbuf == MAXBUF)
		return -1;
	params = zwp_linux_dmabuf_v1_create_params(p->dmabuf);
	zwp_linux_buffer_params_v1_add(params, fd, 0, 0, stride, (uint32_t)(mod >> 32), (uint32_t)mod);
	zwp_linux_buffer_params_v1_add(params, fd, 1, uv_offset, stride, (uint32_t)(mod >> 32), (uint32_t)mod);
	b = &p->buf[p->nbuf];
	*b = (struct pbuf){ p, NULL, tag };
	b->wl = zwp_linux_buffer_params_v1_create_immed(params, p->width, p->height, DRM_FORMAT_NV12, 0);
	zwp_linux_buffer_params_v1_destroy(params);
	wl_buffer_add_listener(b->wl, &buf_listener, b);
	/* a refused import is a protocol error: find out here, not at the first commit */
	if (wl_display_roundtrip_queue(p->display, p->queue) < 0) {
		lost(p, "zwp_linux_buffer_params_v1.create_immed");
		wl_buffer_destroy(b->wl);
		b->wl = NULL;
		return -1;
	}
	return p->nbuf++;
}

int dmabuf_presenter_present(struct dmabuf_presenter *p, int index)
{
	struct pbuf *b;

	if (p->dead)
		return -1;
	if (index < 0 || index >= p->nbuf) {
		fprintf(stderr, "present-dmabuf: no buffer %d\n", index);
		return -1;
	}
	b = &p->buf[index];
	if (!p->frame_cb) {
		p->frame_cb = wl_surface_frame(p->surface_wrapper);
		wl_callback_add_listener(p->frame_cb, &frame_listener, p);
	}
	wl_surface_attach(p->surface, b->wl, 0, 0);
	if (wl_proxy_get_version((struct wl_proxy *)p->surface) >= WL_SURFACE_DAMAGE_BUFFER_SINCE_VERSION)
		wl_surface_damage_buffer(p->surface, 0, 0, p->width, p->height);
	else
		wl_surface_damage(p->surface, 0, 0, p->width, p->height);
	wl_surface_commit(p->surface);
	if (wl_display_flush(p->display) < 0 && errno != EAGAIN)
		return lost(p, "flush");
	return 0;
}

/* dispatch the private queue, reading the socket for up to timeout_ms if it is empty */
static int pump(struct dmabuf_presenter *p, int timeout_ms)
{
	struct pollfd pfd;
	int n, r;

	if (p->dead)
		return -1;
	while (wl_display_prepare_read_queue(p->display, p->queue) != 0) {
		n = wl_display_dispatch_queue_pending(p->display, p->queue);
		if (n < 0)
			return lost(p, "dispatch");
		if (n > 0)
			return n;
	}
	if (wl_display_flush(p->display) < 0 && errno != EAGAIN) {
		wl_display_cancel_read(p->display);
		return lost(p, "flush");
	}
	pfd = (struct pollfd){ wl_display_get_fd(p->display), POLLIN, 0 };
	r = poll(&pfd, 1, timeout_ms);
	if (r <= 0) {
		wl_display_cancel_read(p->display);
		if (r < 0 && errno != EINTR)
			return lost(p, "poll");
		return 0;
	}
	if (wl_display_read_events(p->display) < 0)
		return lost(p, "read");
	n = wl_display_dispatch_queue_pending(p->display, p->queue);
	return n < 0 ? lost(p, "dispatch") : n;
}

void dmabuf_presenter_dispatch(struct dmabuf_presenter *p)
{
	pump(p, 0);
}

int dmabuf_presenter_wait(struct dmabuf_presenter *p, int timeout_ms)
{
	return pump(p, timeout_ms);
}

static long long now_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

int dmabuf_presenter_wait_frame(struct dmabuf_presenter *p, int timeout_ms)
{
	long long end = now_ms() + timeout_ms;

	while (p->frame_cb) {
		long long left = end - now_ms();

		if (left <= 0)
			return 0;
		if (pump(p, (int)left) < 0)
			return -1;
	}
	return 1;
}

unsigned dmabuf_presenter_frames(const struct dmabuf_presenter *p)
{
	return p->frames;
}

void dmabuf_presenter_destroy(struct dmabuf_presenter *p)
{
	if (!p)
		return;
	for (int i = 0; i < p->nbuf; i++)
		if (p->buf[i].wl)
			wl_buffer_destroy(p->buf[i].wl);
	if (p->frame_cb)
		wl_callback_destroy(p->frame_cb);
	if (p->dmabuf)
		zwp_linux_dmabuf_v1_destroy(p->dmabuf);
	if (p->compositor)
		wl_compositor_destroy(p->compositor);
	if (p->registry)
		wl_registry_destroy(p->registry);
	if (p->surface_wrapper)
		wl_proxy_wrapper_destroy(p->surface_wrapper);
	if (p->display_wrapper)
		wl_proxy_wrapper_destroy(p->display_wrapper);
	if (!p->dead)
		wl_display_flush(p->display);
	if (p->queue)
		wl_event_queue_destroy(p->queue);
	free(p);
}
