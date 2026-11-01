/*
 * badge-graphics-check: draws three vertical bars into an SDL window surface
 * and reports what the window framebuffer turned out to be.
 *
 * Even frames draw red|green|blue, odd frames blue|green|red, so a screenshot
 * tells which frame is on screen. Output, one line each:
 *
 *   format=<SDL pixel format name> pitch=<bytes> w=<pixels> h=<pixels>
 *   pointer-swaps=<updates after which the surface's pixels pointer changed>
 *   persist=ok|bad    (copy mode only: pixel (0,0) survives an update)
 *   ready
 *
 * It then holds the window for --hold seconds and exits. A resize meanwhile
 * redraws the last frame at the new size and prints
 *
 *   redraw format=<name> pitch=<bytes> w=<pixels> h=<pixels>
 *
 * --fullscreen-mode WxH goes exclusive fullscreen in the display mode closest
 * to WxH before drawing, and leaves fullscreen after the hold. It adds
 *
 *   mode-before=WxH       (the display's current mode before)
 *   fullscreen-mode=WxH   (the mode picked)
 *   mode-during=WxH       (the current mode in fullscreen)
 *   desktop-mode=WxH      (the desktop mode in fullscreen)
 *   mode-after=WxH        (the current mode after leaving fullscreen)
 *
 * A failed self-check prints the reason and exits 1.
 */
#include <SDL3/SDL.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The SDL Wayland shm framebuffer hints. Headers without them simply ignore
 * the hints, and the window framebuffer is whatever SDL provides. */
#ifndef SDL_HINT_VIDEO_WAYLAND_SHM_FORMAT
#define SDL_HINT_VIDEO_WAYLAND_SHM_FORMAT "SDL_VIDEO_WAYLAND_SHM_FORMAT"
#endif
#ifndef SDL_HINT_VIDEO_WAYLAND_FRAMEBUFFER_NO_COPY
#define SDL_HINT_VIDEO_WAYLAND_FRAMEBUFFER_NO_COPY "SDL_VIDEO_WAYLAND_FRAMEBUFFER_NO_COPY"
#endif

#define APP_ID "badge-graphics-check"

struct options {
    const char *format;
    int width;
    int height;
    bool fullscreen;
    int mode_width;
    int mode_height;
    bool no_copy;
    int frames;
    double hold;
};

static void usage(void)
{
    fprintf(stderr,
            "usage: " APP_ID " [--format NAME] [--size WxH] [--fullscreen]\n"
            "       [--fullscreen-mode WxH] [--no-copy] [--frames N] [--hold S]\n");
    exit(2);
}

static void fail(const char *what, const char *why)
{
    fprintf(stderr, APP_ID ": %s: %s\n", what, why);
    fflush(stdout);
    exit(1);
}

static void parse(int argc, char **argv, struct options *o)
{
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        const char *v = i + 1 < argc ? argv[i + 1] : NULL;

        if (!strcmp(a, "--fullscreen")) {
            o->fullscreen = true;
        } else if (!strcmp(a, "--no-copy")) {
            o->no_copy = true;
        } else if (!v) {
            usage();
        } else if (!strcmp(a, "--format")) {
            o->format = v;
            i++;
        } else if (!strcmp(a, "--size")) {
            if (sscanf(v, "%dx%d", &o->width, &o->height) != 2 || o->width <= 0 || o->height <= 0) {
                usage();
            }
            i++;
        } else if (!strcmp(a, "--fullscreen-mode")) {
            if (sscanf(v, "%dx%d", &o->mode_width, &o->mode_height) != 2 || o->mode_width <= 0 || o->mode_height <= 0) {
                usage();
            }
            i++;
        } else if (!strcmp(a, "--frames")) {
            o->frames = atoi(v);
            if (o->frames <= 0) {
                usage();
            }
            i++;
        } else if (!strcmp(a, "--hold")) {
            o->hold = atof(v);
            if (o->hold < 0) {
                usage();
            }
            i++;
        } else {
            usage();
        }
    }
}

static void draw_bars(SDL_Surface *s, int frame)
{
    static const Uint8 rgb[3][3] = { { 255, 0, 0 }, { 0, 255, 0 }, { 0, 0, 255 } };

    for (int i = 0; i < 3; i++) {
        const int c = frame % 2 == 0 ? i : 2 - i;
        const SDL_Rect r = { s->w * i / 3, 0, s->w * (i + 1) / 3 - s->w * i / 3, s->h };

        SDL_FillSurfaceRect(s, &r, SDL_MapSurfaceRGB(s, rgb[c][0], rgb[c][1], rgb[c][2]));
    }
}

/* Fetches the window surface, draws frame `frame` into it and presents it.
 * Returns the surface the frame was drawn into. */
static SDL_Surface *present(SDL_Window *window, int frame, int *pointer_swaps, bool *persist_ok)
{
    SDL_Surface *s = SDL_GetWindowSurface(window);
    Uint8 drawn[4];
    void *before;
    int bpp;

    if (!s) {
        fail("SDL_GetWindowSurface", SDL_GetError());
    }
    bpp = SDL_BYTESPERPIXEL(s->format);

    draw_bars(s, frame);
    SDL_memcpy(drawn, s->pixels, bpp);
    before = s->pixels;

    if (!SDL_UpdateWindowSurface(window)) {
        fail("SDL_UpdateWindowSurface", SDL_GetError());
    }

    if (s->pixels != before) {
        (*pointer_swaps)++;
    } else if (SDL_memcmp(drawn, s->pixels, bpp) != 0) {
        *persist_ok = false;
    }
    return s;
}

/* Gives a fullscreen window up to two seconds to grow to width x height
 * pixels. The compositor may configure it at its windowed size first and
 * only make it fullscreen once it is mapped, so a first frame maps it. */
static void wait_for_size(SDL_Window *window, int width, int height)
{
    const Uint64 deadline = SDL_GetTicks() + 2000;
    int pointer_swaps = 0;
    bool persist_ok = true;
    int w, h;

    present(window, 0, &pointer_swaps, &persist_ok);
    while (SDL_GetTicks() < deadline) {
        SDL_GetWindowSizeInPixels(window, &w, &h);
        if (w == width && h == height) {
            break;
        }
        SDL_PumpEvents();
        SDL_Delay(10);
    }
}

/* Handles events for a quarter of a second, so that the display's events
 * after a fullscreen change have arrived. */
static void settle(void)
{
    const Uint64 deadline = SDL_GetTicks() + 250;

    while (SDL_GetTicks() < deadline) {
        SDL_PumpEvents();
        SDL_Delay(10);
    }
}

static void print_mode(const char *key, const SDL_DisplayMode *mode)
{
    if (!mode) {
        fail(key, SDL_GetError());
    }
    printf("%s=%dx%d\n", key, mode->w, mode->h);
    fflush(stdout);
}

/* The display's fullscreen mode closest to width x height. */
static SDL_DisplayMode closest_mode(SDL_DisplayID display, int width, int height)
{
    int count = 0;
    SDL_DisplayMode **modes = SDL_GetFullscreenDisplayModes(display, &count);
    SDL_DisplayMode best;

    if (!modes || count == 0) {
        fail("SDL_GetFullscreenDisplayModes", modes ? "no modes" : SDL_GetError());
    }
    best = *modes[0];
    for (int i = 1; i < count; i++) {
        if (abs(modes[i]->w - width) + abs(modes[i]->h - height) <
            abs(best.w - width) + abs(best.h - height)) {
            best = *modes[i];
        }
    }
    SDL_free(modes);
    return best;
}

/* Handles pending events. Returns false once the window should close. */
static bool handle_event(const SDL_Event *e, bool *redraw)
{
    switch (e->type) {
    case SDL_EVENT_QUIT:
    case SDL_EVENT_WINDOW_CLOSE_REQUESTED:
        return false;
    case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
        *redraw = true;
        break;
    default:
        break;
    }
    return true;
}

int main(int argc, char **argv)
{
    struct options o = { .width = 640, .height = 360, .frames = 60 };
    SDL_WindowFlags flags = SDL_WINDOW_RESIZABLE;
    SDL_Window *window;
    SDL_DisplayID display = 0;
    SDL_Surface *s = NULL;
    int pointer_swaps = 0;
    bool persist_ok = true;
    bool running = true;
    bool redraw = false;
    SDL_Event e;

    parse(argc, argv, &o);

    SDL_SetHint(SDL_HINT_APP_ID, APP_ID);
    SDL_SetHint(SDL_HINT_FRAMEBUFFER_ACCELERATION, "0");
    if (o.format) {
        SDL_SetHint(SDL_HINT_VIDEO_WAYLAND_SHM_FORMAT, o.format);
    }
    if (o.no_copy) {
        SDL_SetHint(SDL_HINT_VIDEO_WAYLAND_FRAMEBUFFER_NO_COPY, "1");
    }

    if (!SDL_Init(SDL_INIT_VIDEO)) {
        fail("SDL_Init", SDL_GetError());
    }
    if (o.fullscreen) {
        flags |= SDL_WINDOW_FULLSCREEN;
    }
    window = SDL_CreateWindow(APP_ID, o.width, o.height, flags);
    if (!window) {
        fail("SDL_CreateWindow", SDL_GetError());
    }
    if (o.fullscreen) {
        const SDL_DisplayMode *mode = SDL_GetCurrentDisplayMode(SDL_GetDisplayForWindow(window));

        if (mode) {
            wait_for_size(window, mode->w, mode->h);
        }
    }
    if (o.mode_width) {
        SDL_DisplayMode mode;

        display = SDL_GetDisplayForWindow(window);
        print_mode("mode-before", SDL_GetCurrentDisplayMode(display));
        mode = closest_mode(display, o.mode_width, o.mode_height);
        print_mode("fullscreen-mode", &mode);
        if (!SDL_SetWindowFullscreenMode(window, &mode) || !SDL_SetWindowFullscreen(window, true)) {
            fail("SDL_SetWindowFullscreen", SDL_GetError());
        }
        SDL_SyncWindow(window);
        wait_for_size(window, mode.w, mode.h);
        settle();
        print_mode("mode-during", SDL_GetCurrentDisplayMode(display));
        print_mode("desktop-mode", SDL_GetDesktopDisplayMode(display));
    }

    for (int frame = 0; frame < o.frames && running; frame++) {
        while (SDL_PollEvent(&e)) {
            running = handle_event(&e, &redraw) && running;
        }
        s = present(window, frame, &pointer_swaps, &persist_ok);

        if (frame == 0) {
            const int bpp = SDL_BYTESPERPIXEL(s->format);

            printf("format=%s pitch=%d w=%d h=%d\n", SDL_GetPixelFormatName(s->format), s->pitch, s->w, s->h);
            fflush(stdout);
            if (s->pitch < s->w * bpp) {
                fail("pitch", "shorter than a row of pixels");
            }
            if (o.format && SDL_strcmp(o.format, SDL_GetPixelFormatName(s->format)) != 0) {
                fail("format", "not the one asked for");
            }
        }
    }

    printf("pointer-swaps=%d\n", pointer_swaps);
    if (!o.no_copy) {
        printf("persist=%s\n", persist_ok ? "ok" : "bad");
        if (!persist_ok) {
            fail("persist", "pixel (0,0) changed across an update");
        }
    }
    printf("ready\n");
    fflush(stdout);

    {
        const Uint64 end = SDL_GetTicks() + (Uint64)(o.hold * 1000.0);
        Uint64 now;

        redraw = false;
        while (running && (now = SDL_GetTicks()) < end) {
            if (SDL_WaitEventTimeout(&e, (Sint32)(end - now))) {
                running = handle_event(&e, &redraw);
                while (running && SDL_PollEvent(&e)) {
                    running = handle_event(&e, &redraw);
                }
            }
            if (running && redraw) {
                redraw = false;
                s = present(window, o.frames - 1, &pointer_swaps, &persist_ok);
                printf("redraw format=%s pitch=%d w=%d h=%d\n", SDL_GetPixelFormatName(s->format), s->pitch, s->w, s->h);
                fflush(stdout);
            }
        }
    }

    if (o.mode_width) {
        if (!SDL_SetWindowFullscreen(window, false)) {
            fail("SDL_SetWindowFullscreen", SDL_GetError());
        }
        SDL_SyncWindow(window);
        settle();
        print_mode("mode-after", SDL_GetCurrentDisplayMode(display));
    }

    SDL_DestroyWindow(window);
    SDL_Quit();
    return 0;
}
