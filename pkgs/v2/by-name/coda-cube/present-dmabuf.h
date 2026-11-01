/*
 * NV12 dma-bufs on an SDL window's wl_surface, through zwp_linux_dmabuf_v1.
 *
 * SDL keeps the window, its events and the cursor. The presenter binds
 * linux-dmabuf (v4) and wl_compositor on a private event queue, through a
 * proxy wrapper of SDL's wl_display, and attaches its own wl_buffers to SDL's
 * wl_surface. It never sets a colour representation, so a fullscreen surface
 * stays eligible for direct scanout, and it marks the surface opaque.
 */
#ifndef PRESENT_DMABUF_H
#define PRESENT_DMABUF_H

#include <stdint.h>
#include <SDL3/SDL.h>

struct dmabuf_presenter;

/*
 * NULL if the window is not a Wayland window or the compositor offers no
 * linux-dmabuf v4. on_release(tag, data) runs from dmabuf_presenter_dispatch()
 * or dmabuf_presenter_wait() when the compositor has stopped reading a buffer.
 */
struct dmabuf_presenter *dmabuf_presenter_create(SDL_Window *win, int width, int height,
						 void (*on_release)(void *tag, void *data), void *data);

/*
 * A width x height NV12 buffer: Y at offset 0 and interleaved UV at uv_offset
 * of the dma-buf fd, both planes with the same stride, linear. The fd stays
 * the caller's; the compositor gets its own copy. Returns the buffer's index,
 * or -1.
 */
int dmabuf_presenter_add_buffer(struct dmabuf_presenter *p, int fd, uint32_t uv_offset, uint32_t stride, void *tag);

/*
 * Attach buffer `index`, damage all of it and commit. The compositor reads
 * the buffer until its on_release; the caller keeps track of that and must
 * not write or present it again before. Returns 0, or -1 if the connection
 * is gone or the index is invalid.
 */
int dmabuf_presenter_present(struct dmabuf_presenter *p, int index);

/* Read and dispatch the private queue without blocking. */
void dmabuf_presenter_dispatch(struct dmabuf_presenter *p);

/*
 * Wait up to timeout_ms for the socket, read it once and dispatch the private
 * queue. Returns the number of events dispatched, or -1 if the connection is
 * gone. 0 means a timeout, a signal, or a read that brought only other
 * queues' (SDL's) events: callers loop until what they wait for has happened.
 */
int dmabuf_presenter_wait(struct dmabuf_presenter *p, int timeout_ms);

/*
 * Wait up to timeout_ms until the compositor has shown the last present
 * (its wl_surface.frame), which paces a client on the display. Returns 1
 * once it has, or if nothing was presented yet; 0 on a timeout, as when the
 * compositor is not drawing the surface; -1 if the connection is gone.
 */
int dmabuf_presenter_wait_frame(struct dmabuf_presenter *p, int timeout_ms);

/* Frames in which the compositor showed the surface so far (wl_surface.frame). */
unsigned dmabuf_presenter_frames(const struct dmabuf_presenter *p);

/* Destroys the presenter's wl_buffers and proxies; SDL's surface stays. */
void dmabuf_presenter_destroy(struct dmabuf_presenter *p);

#endif
