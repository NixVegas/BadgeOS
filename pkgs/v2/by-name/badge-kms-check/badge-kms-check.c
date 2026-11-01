/*
 * badge-kms-check: drives soph_drm's primary plane directly, through atomic
 * KMS, to check which framebuffer layouts it scans and how they look.
 *
 *   badge-kms-check [--device /dev/dri/card1] <command> [options]
 *
 * The KMS commands below need DRM master, so the compositor must not be
 * running.
 *
 * reject
 *     Test-commits (TEST_ONLY) one framebuffer layout per row and prints
 *     whether the driver accepted it. A layout the driver cannot scan must
 *     pass AddFB2 and fail the test commit: a compositor drops back to
 *     composition on a failed test, but a failed AddFB2 poisons the client
 *     buffer for good. Exits 0 only if every row behaves as expected.
 *
 * bars --format nv12|rgb888 [--range limited|full] [--encoding bt601|bt709]
 *      [--seconds N]
 *     Shows vertical colour bars over a horizontal grey ramp at 1280x720 for
 *     N seconds (default 30). --range and --encoding pick the YCbCr range
 *     and encoding of the NV12 buffer and of the plane's COLOR_RANGE and
 *     COLOR_ENCODING (default limited, BT.601). Every format, range and
 *     encoding shows the same picture.
 *
 * flip --count N --hz H [--pair formats|nv12] [--pitch2 P]
 *      [--range limited|full] [--encoding bt601|bt709] [--settle S]
 *     Shows the picture, then flips the plane between two framebuffers, N
 *     flips at H flips a second, starting S seconds (default 3) after the
 *     modeset. Each flip is a plane update without a modeset.
 *     --pair formats (the default) alternates an RGB888 and an NV12
 *     framebuffer of the same picture, so a frame that shows garbage or
 *     wrong colours is a format change the display did not take atomically.
 *     --pair nv12 alternates two NV12 framebuffers; the second adds a white
 *     block in the middle of the grey ramp, so the flips can be seen, and has
 *     pitches P (default 1280, the first one's). With equal pitches each flip
 *     is a new pair of plane addresses; with different ones, a new layer.
 *
 * The plane's COLOR_ENCODING and COLOR_RANGE outlive the DRM master that set
 * them, and wlroots never sets them, so every KMS command puts back the
 * values it found before it exits, on SIGINT, SIGTERM and SIGHUP too.
 *
 * ion-reject [--live PHYS]
 *     Not a KMS command: it needs root but no DRM master, so the compositor
 *     can run. Asks /dev/soph-ion to export memory it must refuse with
 *     EINVAL: physical address 0, the start of DRAM (0x80000000, kernel
 *     memory), and flags other than O_CLOEXEC and SOPH_ION_EXPORT_RDONLY
 *     (0x1). With --live, PHYS is an address inside a live ION allocation, a
 *     decoder frame say: the bad flags are tried on it, and an export with
 *     O_CLOEXEC must then give a read-write, close-on-exec dma-buf of the
 *     allocation's size. With SOPH_ION_EXPORT_RDONLY too, the dma-buf must
 *     be read-only: it maps PROT_READ, and neither a writable map nor
 *     mprotect() to writable is allowed. Then the end bound: the
 *     allocation's last byte must export, and the byte after it must fail
 *     with EINVAL; where another allocation starts there, its end is tried
 *     instead, and so on. Exits 0 only if every case behaves as expected.
 *
 * A failed setup step prints the reason and exits 2.
 */
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <math.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include <drm_fourcc.h>
#include <soph_ion.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

#define NATIVE_W 1280
#define NATIVE_H 720

/* The CODA980's 1280x720 NV12 frame buffer: stride 1280 for both planes,
 * the luma plane padded to 736 lines, so UV starts at 1280 * 736. */
#define DECODER_PITCH 1280
#define DECODER_UV_OFFSET 942080
#define DECODER_SIZE 1413120

/* Dumb buffers are allocated as lines of this many bytes. */
#define DUMB_LINE 1280

enum range { RANGE_LIMITED, RANGE_FULL };

/* How an NV12 buffer's YCbCr is to be read. */
struct yuv {
    enum range range;
    bool bt709;
};

/* Property ids, looked up once. */
struct props {
    uint32_t conn_crtc_id;
    uint32_t crtc_mode_id, crtc_active;
    uint32_t fb_id, crtc_id;
    uint32_t src_x, src_y, src_w, src_h;
    uint32_t crtc_x, crtc_y, crtc_w, crtc_h;
    /* 0 when the plane has no colour properties. */
    uint32_t color_encoding, color_range;
    uint64_t enc_bt601, enc_bt709, range_limited, range_full;
    /* Their values when the device was opened, put back at close. */
    uint64_t encoding_found, range_found;
};

struct kms {
    int fd;
    uint32_t conn, crtc, plane;
    drmModeModeInfo native, gop;
    uint32_t native_blob, gop_blob;
    struct props p;
};

/* A framebuffer layout: up to two planes, each in its own dumb buffer when
 * size[1] is set, else both in the first. */
struct layout {
    uint32_t fourcc;
    unsigned int w, h;
    uint32_t pitch[2];
    uint32_t offset[2];
    uint32_t size[2];
};

struct dumb {
    uint32_t handle;
    uint64_t size;
    uint8_t *map;
};

struct fb {
    struct layout l;
    struct dumb obj[2];
    unsigned int nobj;
    uint32_t id;
};

static volatile sig_atomic_t stop;

static void on_signal(int sig)
{
    (void)sig;
    stop = 1;
}

/* Sleeps for `s` seconds or until a signal; false if interrupted. */
static bool sleep_s(double s)
{
    struct timespec ts = { (time_t)s, (long)((s - (time_t)s) * 1e9) };

    while (!stop && nanosleep(&ts, &ts) == -1 && errno == EINTR)
        ;
    return !stop;
}

static double now_s(void)
{
    struct timespec ts;

    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static const char *fourcc_name(uint32_t f)
{
    switch (f) {
    case DRM_FORMAT_RGB888:
        return "RGB888";
    case DRM_FORMAT_NV12:
        return "NV12";
    case DRM_FORMAT_XRGB8888:
        return "XRGB8888";
    default:
        return "?";
    }
}

/* setup */

static uint32_t prop_id(int fd, uint32_t obj, uint32_t type, const char *name,
                        drmModePropertyRes **out)
{
    drmModeObjectProperties *props = drmModeObjectGetProperties(fd, obj, type);
    uint32_t id = 0;

    if (!props)
        return 0;
    for (uint32_t i = 0; i < props->count_props && !id; i++) {
        drmModePropertyRes *p = drmModeGetProperty(fd, props->props[i]);

        if (!p)
            continue;
        if (!strcmp(p->name, name)) {
            id = p->prop_id;
            if (out) {
                *out = p;
                p = NULL;
            }
        }
        drmModeFreeProperty(p);
    }
    drmModeFreeObjectProperties(props);
    return id;
}

static bool enum_value(const drmModePropertyRes *p, const char *name,
                       uint64_t *v)
{
    for (int i = 0; p && i < p->count_enums; i++) {
        if (!strcmp(p->enums[i].name, name)) {
            *v = p->enums[i].value;
            return true;
        }
    }
    return false;
}

/* The current value of an object's property, false if it has none. */
static bool prop_value(int fd, uint32_t obj, uint32_t type, uint32_t id,
                       uint64_t *v)
{
    drmModeObjectProperties *props = drmModeObjectGetProperties(fd, obj, type);
    bool found = false;

    for (uint32_t i = 0; props && i < props->count_props && !found; i++) {
        if (props->props[i] == id) {
            *v = props->prop_values[i];
            found = true;
        }
    }
    drmModeFreeObjectProperties(props);
    return found;
}

static int plane_type(int fd, uint32_t plane)
{
    drmModeObjectProperties *props =
        drmModeObjectGetProperties(fd, plane, DRM_MODE_OBJECT_PLANE);
    int type = -1;

    if (!props)
        return -1;
    for (uint32_t i = 0; i < props->count_props; i++) {
        drmModePropertyRes *p = drmModeGetProperty(fd, props->props[i]);

        if (p && !strcmp(p->name, "type"))
            type = (int)props->prop_values[i];
        drmModeFreeProperty(p);
    }
    drmModeFreeObjectProperties(props);
    return type;
}

static int kms_lookup_props(struct kms *k)
{
    struct props *p = &k->p;
    drmModePropertyRes *enc = NULL, *range = NULL;

    p->conn_crtc_id = prop_id(k->fd, k->conn, DRM_MODE_OBJECT_CONNECTOR, "CRTC_ID", NULL);
    p->crtc_mode_id = prop_id(k->fd, k->crtc, DRM_MODE_OBJECT_CRTC, "MODE_ID", NULL);
    p->crtc_active = prop_id(k->fd, k->crtc, DRM_MODE_OBJECT_CRTC, "ACTIVE", NULL);
#define PLANE_PROP(field, name) \
    p->field = prop_id(k->fd, k->plane, DRM_MODE_OBJECT_PLANE, name, NULL)
    PLANE_PROP(fb_id, "FB_ID");
    PLANE_PROP(crtc_id, "CRTC_ID");
    PLANE_PROP(src_x, "SRC_X");
    PLANE_PROP(src_y, "SRC_Y");
    PLANE_PROP(src_w, "SRC_W");
    PLANE_PROP(src_h, "SRC_H");
    PLANE_PROP(crtc_x, "CRTC_X");
    PLANE_PROP(crtc_y, "CRTC_Y");
    PLANE_PROP(crtc_w, "CRTC_W");
    PLANE_PROP(crtc_h, "CRTC_H");
#undef PLANE_PROP
    if (!p->conn_crtc_id || !p->crtc_mode_id || !p->crtc_active || !p->fb_id ||
        !p->crtc_id || !p->src_x || !p->src_y || !p->src_w || !p->src_h ||
        !p->crtc_x || !p->crtc_y || !p->crtc_w || !p->crtc_h) {
        fprintf(stderr, "missing an atomic property on the connector, CRTC or plane\n");
        return -1;
    }

    p->color_encoding = prop_id(k->fd, k->plane, DRM_MODE_OBJECT_PLANE,
                                "COLOR_ENCODING", &enc);
    p->color_range = prop_id(k->fd, k->plane, DRM_MODE_OBJECT_PLANE,
                             "COLOR_RANGE", &range);
    if (p->color_encoding && p->color_range &&
        (!enum_value(enc, "ITU-R BT.601 YCbCr", &p->enc_bt601) ||
         !enum_value(enc, "ITU-R BT.709 YCbCr", &p->enc_bt709) ||
         !enum_value(range, "YCbCr limited range", &p->range_limited) ||
         !enum_value(range, "YCbCr full range", &p->range_full)))
        p->color_encoding = p->color_range = 0;
    if (p->color_encoding &&
        (!prop_value(k->fd, k->plane, DRM_MODE_OBJECT_PLANE, p->color_encoding,
                     &p->encoding_found) ||
         !prop_value(k->fd, k->plane, DRM_MODE_OBJECT_PLANE, p->color_range,
                     &p->range_found)))
        p->color_encoding = p->color_range = 0;
    drmModeFreeProperty(enc);
    drmModeFreeProperty(range);
    return 0;
}

/* Puts back the colour properties kms_open() found. */
static void kms_restore_color(struct kms *k)
{
    const struct props *p = &k->p;
    drmModeAtomicReq *req;
    int ret;

    if (!p->color_encoding)
        return;
    req = drmModeAtomicAlloc();
    if (!req) {
        fprintf(stderr, "cannot restore the plane's colour properties: out of memory\n");
        return;
    }
    drmModeAtomicAddProperty(req, k->plane, p->color_encoding, p->encoding_found);
    drmModeAtomicAddProperty(req, k->plane, p->color_range, p->range_found);
    ret = drmModeAtomicCommit(k->fd, req, 0, NULL);
    drmModeAtomicFree(req);
    if (ret)
        fprintf(stderr, "cannot restore the plane's colour properties: %s\n",
                strerror(-ret));
    else
        printf("plane colour properties back to %s, %s\n",
               p->encoding_found == p->enc_bt709 ? "BT.709" : "BT.601",
               p->range_found == p->range_full ? "full range" : "limited range");
}

static int kms_open(struct kms *k, const char *path)
{
    drmModeRes *res = NULL;
    drmModePlaneRes *pres = NULL;
    drmModeConnector *conn = NULL;
    drmModeEncoder *enc = NULL;
    int crtc_index = -1, ret = -1;
    bool have_native = false, have_gop = false;

    memset(k, 0, sizeof(*k));
    k->fd = open(path, O_RDWR | O_CLOEXEC);
    if (k->fd < 0) {
        fprintf(stderr, "%s: %s\n", path, strerror(errno));
        return -1;
    }
    if (drmSetClientCap(k->fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1) ||
        drmSetClientCap(k->fd, DRM_CLIENT_CAP_ATOMIC, 1)) {
        fprintf(stderr, "%s: no atomic modesetting\n", path);
        goto out;
    }
    if (!drmIsMaster(k->fd) && drmSetMaster(k->fd)) {
        fprintf(stderr, "%s: cannot become DRM master (%s); stop the compositor first\n",
                path, strerror(errno));
        goto out;
    }

    res = drmModeGetResources(k->fd);
    if (!res)
        goto out;
    for (int i = 0; i < res->count_connectors && !k->conn; i++) {
        conn = drmModeGetConnector(k->fd, res->connectors[i]);
        if (conn && conn->connection == DRM_MODE_CONNECTED && conn->count_modes)
            k->conn = conn->connector_id;
        else {
            drmModeFreeConnector(conn);
            conn = NULL;
        }
    }
    if (!conn) {
        fprintf(stderr, "no connected connector\n");
        goto out;
    }
    for (int i = 0; i < conn->count_modes; i++) {
        const drmModeModeInfo *m = &conn->modes[i];

        if (m->hdisplay == NATIVE_W && m->vdisplay == NATIVE_H && !have_native) {
            k->native = *m;
            have_native = true;
        } else if (m->hdisplay == NATIVE_W / 2 && m->vdisplay == NATIVE_H / 2 &&
                   !have_gop) {
            k->gop = *m;
            have_gop = true;
        }
    }
    if (!have_native || !have_gop) {
        fprintf(stderr, "the connector does not offer both 1280x720 and 640x360\n");
        goto out;
    }

    if (conn->count_encoders)
        enc = drmModeGetEncoder(k->fd, conn->encoders[0]);
    for (int i = 0; enc && i < res->count_crtcs; i++) {
        if (enc->possible_crtcs & (1u << i)) {
            k->crtc = res->crtcs[i];
            crtc_index = i;
            break;
        }
    }
    if (crtc_index < 0) {
        fprintf(stderr, "no CRTC for the connector\n");
        goto out;
    }

    pres = drmModeGetPlaneResources(k->fd);
    for (uint32_t i = 0; pres && i < pres->count_planes && !k->plane; i++) {
        drmModePlane *pl = drmModeGetPlane(k->fd, pres->planes[i]);

        if (pl && (pl->possible_crtcs & (1u << crtc_index)) &&
            plane_type(k->fd, pl->plane_id) == DRM_PLANE_TYPE_PRIMARY)
            k->plane = pl->plane_id;
        drmModeFreePlane(pl);
    }
    if (!k->plane) {
        fprintf(stderr, "no primary plane for the CRTC\n");
        goto out;
    }

    if (kms_lookup_props(k))
        goto out;
    if (drmModeCreatePropertyBlob(k->fd, &k->native, sizeof(k->native), &k->native_blob) ||
        drmModeCreatePropertyBlob(k->fd, &k->gop, sizeof(k->gop), &k->gop_blob)) {
        fprintf(stderr, "cannot create mode blobs\n");
        goto out;
    }
    ret = 0;
out:
    drmModeFreeEncoder(enc);
    drmModeFreeConnector(conn);
    drmModeFreePlaneResources(pres);
    drmModeFreeResources(res);
    if (ret) {
        close(k->fd);
        k->fd = -1;
    }
    return ret;
}

static void kms_close(struct kms *k)
{
    kms_restore_color(k);
    if (k->native_blob)
        drmModeDestroyPropertyBlob(k->fd, k->native_blob);
    if (k->gop_blob)
        drmModeDestroyPropertyBlob(k->fd, k->gop_blob);
    close(k->fd);
}

/* buffers */

static int dumb_create(struct kms *k, uint32_t size, struct dumb *d)
{
    struct drm_mode_create_dumb c = {
        .width = DUMB_LINE,
        .height = (size + DUMB_LINE - 1) / DUMB_LINE,
        .bpp = 8,
    };
    struct drm_mode_map_dumb m = {0};

    memset(d, 0, sizeof(*d));
    if (drmIoctl(k->fd, DRM_IOCTL_MODE_CREATE_DUMB, &c))
        return -errno;
    d->handle = c.handle;
    d->size = c.size;
    m.handle = c.handle;
    if (drmIoctl(k->fd, DRM_IOCTL_MODE_MAP_DUMB, &m))
        return -errno;
    d->map = mmap(NULL, d->size, PROT_READ | PROT_WRITE, MAP_SHARED, k->fd, m.offset);
    if (d->map == MAP_FAILED) {
        d->map = NULL;
        return -errno;
    }
    return 0;
}

static void dumb_destroy(struct kms *k, struct dumb *d)
{
    struct drm_mode_destroy_dumb x = { .handle = d->handle };

    if (d->map)
        munmap(d->map, d->size);
    if (d->handle)
        drmIoctl(k->fd, DRM_IOCTL_MODE_DESTROY_DUMB, &x);
    memset(d, 0, sizeof(*d));
}

static void fb_destroy(struct kms *k, struct fb *f)
{
    if (f->id)
        drmModeRmFB(k->fd, f->id);
    for (unsigned int i = 0; i < f->nobj; i++)
        dumb_destroy(k, &f->obj[i]);
    memset(f, 0, sizeof(*f));
}

/* Allocates the layout's buffers; 0 or -errno. */
static int fb_alloc(struct kms *k, const struct layout *l, struct fb *f)
{
    int ret;

    memset(f, 0, sizeof(*f));
    f->l = *l;
    f->nobj = l->size[1] ? 2 : 1;
    for (unsigned int i = 0; i < f->nobj; i++) {
        ret = dumb_create(k, l->size[i], &f->obj[i]);
        if (ret) {
            fb_destroy(k, f);
            return ret;
        }
    }
    return 0;
}

/* AddFB2 for the allocated buffers; 0 or -errno. */
static int fb_add(struct kms *k, struct fb *f)
{
    const struct layout *l = &f->l;
    uint32_t handles[4] = {0}, pitches[4] = {0}, offsets[4] = {0};
    unsigned int planes = l->fourcc == DRM_FORMAT_NV12 ? 2 : 1;

    for (unsigned int i = 0; i < planes; i++) {
        handles[i] = f->obj[f->nobj > 1 ? i : 0].handle;
        pitches[i] = l->pitch[i];
        offsets[i] = l->offset[i];
    }
    return drmModeAddFB2(k->fd, l->w, l->h, l->fourcc, handles, pitches,
                         offsets, &f->id, 0);
}

/* commits */

/*
 * Commits the whole pipe: the connector on the CRTC, the CRTC on `blob`'s
 * mode, the plane scanning `fb` 1:1 over it. A non-NULL `yuv` also sets the
 * plane's YCbCr encoding and range.
 */
static int commit(struct kms *k, uint32_t fb, unsigned int w, unsigned int h,
                  uint32_t blob, const struct yuv *yuv, uint32_t flags)
{
    const struct props *p = &k->p;
    drmModeAtomicReq *req = drmModeAtomicAlloc();
    int ret;

    if (!req)
        return -ENOMEM;
    if (flags & DRM_MODE_ATOMIC_ALLOW_MODESET) {
        drmModeAtomicAddProperty(req, k->conn, p->conn_crtc_id, k->crtc);
        drmModeAtomicAddProperty(req, k->crtc, p->crtc_mode_id, blob);
        drmModeAtomicAddProperty(req, k->crtc, p->crtc_active, 1);
    }
    drmModeAtomicAddProperty(req, k->plane, p->fb_id, fb);
    drmModeAtomicAddProperty(req, k->plane, p->crtc_id, k->crtc);
    drmModeAtomicAddProperty(req, k->plane, p->src_x, 0);
    drmModeAtomicAddProperty(req, k->plane, p->src_y, 0);
    drmModeAtomicAddProperty(req, k->plane, p->src_w, (uint64_t)w << 16);
    drmModeAtomicAddProperty(req, k->plane, p->src_h, (uint64_t)h << 16);
    drmModeAtomicAddProperty(req, k->plane, p->crtc_x, 0);
    drmModeAtomicAddProperty(req, k->plane, p->crtc_y, 0);
    drmModeAtomicAddProperty(req, k->plane, p->crtc_w, w);
    drmModeAtomicAddProperty(req, k->plane, p->crtc_h, h);
    if (yuv && p->color_encoding) {
        drmModeAtomicAddProperty(req, k->plane, p->color_encoding,
                                 yuv->bt709 ? p->enc_bt709 : p->enc_bt601);
        drmModeAtomicAddProperty(req, k->plane, p->color_range,
                                 yuv->range == RANGE_FULL ? p->range_full : p->range_limited);
    }
    ret = drmModeAtomicCommit(k->fd, req, flags, NULL);
    drmModeAtomicFree(req);
    return ret;
}

/* reject */

struct reject_case {
    const char *what;
    bool accept;
    bool gop_mode;
    struct layout l;
};

static const struct reject_case reject_cases[] = {
    { "RGB888 1280x720, pitch 3840", true, false,
      { DRM_FORMAT_RGB888, 1280, 720, { 3840 }, { 0 }, { 2764800 } } },
    { "NV12 1280x720, pitches 1280/1280, UV at 942080 in the same object", true, false,
      { DRM_FORMAT_NV12, 1280, 720, { 1280, 1280 }, { 0, 942080 }, { DECODER_SIZE } } },
    { "NV12 1280x720, UV in a second object", true, false,
      { DRM_FORMAT_NV12, 1280, 720, { 1280, 1280 }, { 0, 0 }, { 921600, 460800 } } },
    { "NV12 1280x720, Y pitch 1288", false, false,
      { DRM_FORMAT_NV12, 1280, 720, { 1288, 1280 }, { 0, 942080 }, { DECODER_SIZE } } },
    { "NV12 1280x720, UV offset 942096", false, false,
      { DRM_FORMAT_NV12, 1280, 720, { 1280, 1280 }, { 0, 942096 }, { DECODER_SIZE } } },
    /* The positive control for the 640x360 modeset of the next row. */
    { "XRGB8888 640x360 with the CRTC at 640x360", true, true,
      { DRM_FORMAT_XRGB8888, 640, 360, { 2560 }, { 0 }, { 921600 } } },
    { "NV12 640x360 with the CRTC at 640x360", false, true,
      { DRM_FORMAT_NV12, 640, 360, { 640, 640 }, { 0, 245760 }, { 368640 } } },
    { "XRGB8888 1280x720", false, false,
      { DRM_FORMAT_XRGB8888, 1280, 720, { 5120 }, { 0 }, { 3686400 } } },
};

static int cmd_reject(struct kms *k, int argc, char **argv)
{
    unsigned int failed = 0;

    (void)argv;
    if (argc > 1) {
        fprintf(stderr, "reject takes no options\n");
        return 2;
    }

    for (size_t i = 0; i < sizeof(reject_cases) / sizeof(reject_cases[0]); i++) {
        const struct reject_case *c = &reject_cases[i];
        const drmModeModeInfo *m = c->gop_mode ? &k->gop : &k->native;
        struct fb f;
        int add, test = 0;
        bool ok;
        char why[96];

        add = fb_alloc(k, &c->l, &f);
        if (add) {
            fprintf(stderr, "%s: cannot allocate buffers: %s\n", c->what, strerror(-add));
            return 2;
        }
        add = fb_add(k, &f);
        if (!add)
            test = commit(k, f.id, m->hdisplay, m->vdisplay,
                          c->gop_mode ? k->gop_blob : k->native_blob, NULL,
                          DRM_MODE_ATOMIC_TEST_ONLY | DRM_MODE_ATOMIC_ALLOW_MODESET);
        fb_destroy(k, &f);

        if (add) {
            ok = false;
            snprintf(why, sizeof(why), "AddFB2 failed: %s", strerror(-add));
        } else if (test) {
            /* The driver's atomic check says EINVAL; anything else is a
             * failure of the commit, not a rejection of the layout. */
            ok = !c->accept && test == -EINVAL;
            snprintf(why, sizeof(why), "test commit rejected: %s", strerror(-test));
        } else {
            ok = c->accept;
            snprintf(why, sizeof(why), "test commit accepted");
        }
        if (!ok)
            failed++;
        printf("%-4s %-6s %-66s %s\n", ok ? "PASS" : "FAIL",
               c->accept ? "accept" : "reject", c->what, why);
    }
    printf("%s: %u of %zu rows as expected\n", failed ? "FAIL" : "PASS",
           (unsigned int)(sizeof(reject_cases) / sizeof(reject_cases[0])) - failed,
           sizeof(reject_cases) / sizeof(reject_cases[0]));
    return failed ? 1 : 0;
}

/* the test picture */

struct rgb {
    uint8_t r, g, b;
};

/* Top two thirds: eight bars, 160 px each. Bottom third: a 16-step grey
 * ramp, 80 px a step, black to white. Every edge falls on an even pixel, so
 * no 2x2 chroma block straddles two colours. */
static struct rgb picture(unsigned int x, unsigned int y, bool marker)
{
    static const struct rgb bars[8] = {
        { 255, 255, 255 }, { 255, 255, 0 }, { 0, 255, 255 }, { 0, 255, 0 },
        { 255, 0, 255 }, { 255, 0, 0 }, { 0, 0, 255 }, { 0, 0, 0 },
    };
    uint8_t v;

    if (y < NATIVE_H * 2 / 3)
        return bars[x / (NATIVE_W / 8)];
    /* The second picture of a flip pair: a white block over ramp steps
     * 6..9, near the top of the ramp. */
    if (marker && x >= 480 && x < 800 && y >= 500 && y < 580)
        return (struct rgb){ 255, 255, 255 };
    v = (uint8_t)(x / (NATIVE_W / 16) * 17);
    return (struct rgb){ v, v, v };
}

static uint8_t clamp8(double v)
{
    return v < 0 ? 0 : v > 255 ? 255 : (uint8_t)lround(v);
}

/* RGB -> YCbCr, BT.601 or BT.709, in the given range. */
static void to_ycbcr(struct rgb c, const struct yuv *yuv, uint8_t *y,
                     uint8_t *u, uint8_t *v)
{
    double kr = yuv->bt709 ? 0.2126 : 0.299;
    double kb = yuv->bt709 ? 0.0722 : 0.114;
    double yy = kr * c.r + (1 - kr - kb) * c.g + kb * c.b;
    double cb = (c.b - yy) / (2 * (1 - kb));
    double cr = (c.r - yy) / (2 * (1 - kr));

    if (yuv->range == RANGE_FULL) {
        *y = clamp8(yy);
        *u = clamp8(128 + cb);
        *v = clamp8(128 + cr);
    } else {
        *y = clamp8(16 + yy * 219 / 255);
        *u = clamp8(128 + cb * 224 / 255);
        *v = clamp8(128 + cr * 224 / 255);
    }
}

static uint8_t *plane_ptr(struct fb *f, unsigned int plane)
{
    return f->obj[f->nobj > 1 ? plane : 0].map + f->l.offset[plane];
}

static void paint(struct fb *f, const struct yuv *yuv, bool marker)
{
    const struct layout *l = &f->l;

    if (l->fourcc == DRM_FORMAT_RGB888) {
        for (unsigned int y = 0; y < l->h; y++) {
            uint8_t *row = plane_ptr(f, 0) + (size_t)y * l->pitch[0];

            for (unsigned int x = 0; x < l->w; x++) {
                struct rgb c = picture(x, y, marker);

                /* DRM RGB888 is B, G, R in memory. */
                row[3 * x] = c.b;
                row[3 * x + 1] = c.g;
                row[3 * x + 2] = c.r;
            }
        }
        return;
    }

    for (unsigned int y = 0; y < l->h; y++) {
        uint8_t *ry = plane_ptr(f, 0) + (size_t)y * l->pitch[0];
        uint8_t *ruv = plane_ptr(f, 1) + (size_t)(y / 2) * l->pitch[1];

        for (unsigned int x = 0; x < l->w; x++) {
            uint8_t yy, u, v;

            to_ycbcr(picture(x, y, marker), yuv, &yy, &u, &v);
            ry[x] = yy;
            /* NV12: U at the lower address. */
            if (!(x & 1) && !(y & 1)) {
                ruv[x] = u;
                ruv[x + 1] = v;
            }
        }
    }
}

static const struct layout rgb888_layout = {
    DRM_FORMAT_RGB888, NATIVE_W, NATIVE_H, { NATIVE_W * 3 }, { 0 },
    { NATIVE_W * 3 * NATIVE_H },
};

static const struct layout nv12_layout = {
    DRM_FORMAT_NV12, NATIVE_W, NATIVE_H, { DECODER_PITCH, DECODER_PITCH },
    { 0, DECODER_UV_OFFSET }, { DECODER_SIZE },
};

/* The decoder's NV12 layout with another pitch for both planes. */
static struct layout nv12_layout_pitch(uint32_t pitch)
{
    struct layout l = nv12_layout;

    l.pitch[0] = l.pitch[1] = pitch;
    l.offset[1] = pitch * (DECODER_UV_OFFSET / DECODER_PITCH);
    l.size[0] = pitch * (DECODER_SIZE / DECODER_PITCH);
    return l;
}

/* Allocates, paints and adds a 1280x720 framebuffer of the test picture. */
static int picture_fb(struct kms *k, const struct layout *l,
                      const struct yuv *yuv, bool marker, struct fb *f)
{
    int ret = fb_alloc(k, l, f);

    if (ret) {
        fprintf(stderr, "cannot allocate %s buffers: %s\n", fourcc_name(l->fourcc),
                strerror(-ret));
        return ret;
    }
    paint(f, yuv, marker);
    ret = fb_add(k, f);
    if (ret) {
        fprintf(stderr, "AddFB2 %s: %s\n", fourcc_name(l->fourcc), strerror(-ret));
        fb_destroy(k, f);
    }
    return ret;
}

static bool parse_range(const char *s, enum range *r)
{
    if (!strcmp(s, "limited"))
        *r = RANGE_LIMITED;
    else if (!strcmp(s, "full"))
        *r = RANGE_FULL;
    else
        return false;
    return true;
}

static bool parse_encoding(const char *s, bool *bt709)
{
    if (!strcmp(s, "bt601"))
        *bt709 = false;
    else if (!strcmp(s, "bt709"))
        *bt709 = true;
    else
        return false;
    return true;
}

static bool parse_number(const char *s, double min, double *out)
{
    char *end;
    double v = strtod(s, &end);

    if (end == s || *end || !(v >= min))
        return false;
    *out = v;
    return true;
}

static const char *yuv_name(const struct yuv *yuv)
{
    static const char *names[2][2] = {
        { "BT.601 limited", "BT.601 full" },
        { "BT.709 limited", "BT.709 full" },
    };

    return names[yuv->bt709][yuv->range == RANGE_FULL];
}

/* bars */

#define BARS_ARGS "--format nv12|rgb888 [--range limited|full] " \
                  "[--encoding bt601|bt709] [--seconds N]"

static int cmd_bars(struct kms *k, int argc, char **argv)
{
    static const struct option opts[] = {
        { "format", required_argument, NULL, 'f' },
        { "range", required_argument, NULL, 'r' },
        { "encoding", required_argument, NULL, 'e' },
        { "seconds", required_argument, NULL, 's' },
        { 0 },
    };
    const struct layout *l = NULL;
    struct yuv yuv = { RANGE_LIMITED, false };
    double seconds = 30;
    bool nv12;
    struct fb f;
    int c, ret;

    while ((c = getopt_long(argc, argv, "", opts, NULL)) != -1) {
        bool ok = true;

        if (c == 'f' && !strcmp(optarg, "nv12"))
            l = &nv12_layout;
        else if (c == 'f' && !strcmp(optarg, "rgb888"))
            l = &rgb888_layout;
        else if (c == 'r')
            ok = parse_range(optarg, &yuv.range);
        else if (c == 'e')
            ok = parse_encoding(optarg, &yuv.bt709);
        else if (c == 's')
            ok = parse_number(optarg, 0, &seconds);
        else
            ok = false;
        if (!ok)
            break;
        c = 0;
    }
    if (c > 0 || !l || optind != argc) {
        fprintf(stderr, "usage: bars %s\n", BARS_ARGS);
        return 2;
    }
    nv12 = l->fourcc == DRM_FORMAT_NV12;
    if (nv12 && !k->p.color_range)
        fprintf(stderr, "warning: the plane has no colour properties; the driver picks the matrix\n");

    if (picture_fb(k, l, &yuv, false, &f))
        return 2;
    ret = commit(k, f.id, NATIVE_W, NATIVE_H, k->native_blob, nv12 ? &yuv : NULL,
                 DRM_MODE_ATOMIC_ALLOW_MODESET);
    if (ret) {
        fprintf(stderr, "commit %s: %s\n", fourcc_name(l->fourcc), strerror(-ret));
        fb_destroy(k, &f);
        return 1;
    }
    printf("bars %s%s%s at 1280x720 for %g s\n", fourcc_name(l->fourcc),
           nv12 ? " " : "", nv12 ? yuv_name(&yuv) : "", seconds);
    fflush(stdout);
    sleep_s(seconds);
    fb_destroy(k, &f);
    return 0;
}

/* flip */

#define FLIP_ARGS "--count N --hz H [--pair formats|nv12] [--pitch2 P] " \
                  "[--range limited|full] [--encoding bt601|bt709] [--settle S]"

static int cmd_flip(struct kms *k, int argc, char **argv)
{
    static const struct option opts[] = {
        { "count", required_argument, NULL, 'n' },
        { "hz", required_argument, NULL, 'z' },
        { "pair", required_argument, NULL, 'p' },
        { "pitch2", required_argument, NULL, 'w' },
        { "range", required_argument, NULL, 'r' },
        { "encoding", required_argument, NULL, 'e' },
        { "settle", required_argument, NULL, 's' },
        { 0 },
    };
    struct yuv yuv = { RANGE_LIMITED, false };
    double count = -1, hz = -1, settle = 3, pitch2 = DECODER_PITCH;
    double t0, next, worst = 0;
    bool nv12_pair = false;
    unsigned int n, done, failed = 0;
    struct layout second;
    struct fb fbs[2];
    int c, ret;

    while ((c = getopt_long(argc, argv, "", opts, NULL)) != -1) {
        bool ok = true;

        if (c == 'n')
            ok = parse_number(optarg, 1, &count);
        else if (c == 'z')
            ok = parse_number(optarg, 0.01, &hz);
        else if (c == 'p' && !strcmp(optarg, "formats"))
            nv12_pair = false;
        else if (c == 'p' && !strcmp(optarg, "nv12"))
            nv12_pair = true;
        else if (c == 'w')
            ok = parse_number(optarg, NATIVE_W, &pitch2) && pitch2 <= 65535;
        else if (c == 'r')
            ok = parse_range(optarg, &yuv.range);
        else if (c == 'e')
            ok = parse_encoding(optarg, &yuv.bt709);
        else if (c == 's')
            ok = parse_number(optarg, 0, &settle);
        else
            ok = false;
        if (!ok)
            break;
        c = 0;
    }
    if (c > 0 || count < 1 || hz <= 0 || optind != argc ||
        (!nv12_pair && pitch2 != DECODER_PITCH)) {
        fprintf(stderr, "usage: flip %s\n", FLIP_ARGS);
        return 2;
    }
    n = (unsigned int)count;
    second = nv12_layout_pitch((uint32_t)pitch2);

    if (picture_fb(k, nv12_pair ? &nv12_layout : &rgb888_layout, &yuv, false, &fbs[0]))
        return 2;
    if (picture_fb(k, nv12_pair ? &second : &nv12_layout, &yuv, nv12_pair, &fbs[1])) {
        fb_destroy(k, &fbs[0]);
        return 2;
    }

    /* The colour properties go in with the modeset and stay in the plane
     * state, so every flip below is a plain FB_ID change. */
    ret = commit(k, fbs[0].id, NATIVE_W, NATIVE_H, k->native_blob, &yuv,
                 DRM_MODE_ATOMIC_ALLOW_MODESET);
    if (ret) {
        fprintf(stderr, "modeset: %s\n", strerror(-ret));
        goto out;
    }
    printf("flip: %s pitch %u on screen, flipping with %s pitch %u (%s) in %g s\n",
           fourcc_name(fbs[0].l.fourcc), fbs[0].l.pitch[0],
           fourcc_name(fbs[1].l.fourcc), fbs[1].l.pitch[0], yuv_name(&yuv), settle);
    fflush(stdout);
    if (!sleep_s(settle)) {
        ret = -EINTR;
        goto out;
    }

    t0 = next = now_s();
    for (done = 0; done < n && !stop; done++) {
        struct fb *f = &fbs[(done + 1) & 1];
        double t = now_s();

        ret = commit(k, f->id, NATIVE_W, NATIVE_H, 0, NULL, 0);
        t = now_s() - t;
        if (t > worst)
            worst = t;
        if (ret) {
            failed++;
            fprintf(stderr, "flip %u to %s: %s\n", done, fourcc_name(f->l.fourcc),
                    strerror(-ret));
        }
        next += 1 / hz;
        if (next > now_s())
            sleep_s(next - now_s());
    }
    printf("flip: %u flips in %.2f s, %u failed, slowest commit %.1f ms\n", done,
           now_s() - t0, failed, worst * 1e3);
    ret = failed || done < n ? 1 : 0;
out:
    fb_destroy(k, &fbs[1]);
    fb_destroy(k, &fbs[0]);
    return ret ? 1 : 0;
}

/* ion-reject */

#define ION_DEVICE "/dev/soph-ion"
#define ION_REJECT_ARGS "[--live PHYS]"

/* The start of DRAM on the SG2000: kernel memory, never an ION allocation. */
#define DRAM_BASE 0x80000000ull

/* 0 with the new dma-buf in *ex, or -errno. */
static int ion_export(int ion, uint64_t phys, uint32_t flags,
                      struct soph_ion_export *ex)
{
    *ex = (struct soph_ion_export){ .phys = phys, .flags = flags, .fd = -1 };
    return ioctl(ion, SOPH_ION_IOC_EXPORT, ex) ? -errno : 0;
}

/* An export the driver must refuse with EINVAL. */
static bool ion_refused(int ion, const char *what, uint64_t phys, uint32_t flags)
{
    struct soph_ion_export ex;
    int ret = ion_export(ion, phys, flags, &ex);

    if (!ret) {
        printf("FAIL %s: exported as fd %d, offset %llu, size %llu\n", what, ex.fd,
               (unsigned long long)ex.offset, (unsigned long long)ex.size);
        close(ex.fd);
        return false;
    }
    printf("%s %s: %s\n", ret == -EINVAL ? "PASS" : "FAIL", what, strerror(-ret));
    return ret == -EINVAL;
}

/* An export of a live allocation: a read-write, close-on-exec dma-buf of it. */
static bool ion_exported(int ion, uint64_t phys)
{
    struct soph_ion_export ex;
    int ret = ion_export(ion, phys, O_CLOEXEC, &ex), fdflags, flflags;
    off_t end;
    bool ok;

    if (ret) {
        printf("FAIL export of %#llx: %s\n", (unsigned long long)phys, strerror(-ret));
        return false;
    }
    end = lseek(ex.fd, 0, SEEK_END);
    fdflags = fcntl(ex.fd, F_GETFD);
    flflags = fcntl(ex.fd, F_GETFL);
    ok = ex.size > 0 && ex.offset < ex.size && end >= 0 && (uint64_t)end == ex.size &&
         fdflags >= 0 && (fdflags & FD_CLOEXEC) && flflags >= 0 &&
         (flflags & O_ACCMODE) == O_RDWR;
    printf("%s export of %#llx: fd %d, offset %llu, size %llu, dma-buf size %lld, %s, %s\n",
           ok ? "PASS" : "FAIL", (unsigned long long)phys, ex.fd,
           (unsigned long long)ex.offset, (unsigned long long)ex.size, (long long)end,
           flflags >= 0 && (flflags & O_ACCMODE) == O_RDWR ? "read-write" : "not read-write",
           fdflags >= 0 && (fdflags & FD_CLOEXEC) ? "close-on-exec" : "not close-on-exec");
    close(ex.fd);
    return ok;
}

/* A read-only export of a live allocation: it maps PROT_READ, and never
 * writable, not even through mprotect(). */
static bool ion_exported_rdonly(int ion, uint64_t phys)
{
    struct soph_ion_export ex;
    int ret = ion_export(ion, phys, O_CLOEXEC | SOPH_ION_EXPORT_RDONLY, &ex);
    int flflags, wr_errno = 0, ro_errno = 0, mp_errno = 0;
    void *ro, *rw;
    bool ok;

    if (ret) {
        printf("FAIL read-only export of %#llx: %s\n", (unsigned long long)phys,
               strerror(-ret));
        return false;
    }
    flflags = fcntl(ex.fd, F_GETFL);
    rw = mmap(NULL, ex.size, PROT_READ | PROT_WRITE, MAP_SHARED, ex.fd, 0);
    if (rw == MAP_FAILED)
        wr_errno = errno;
    else
        munmap(rw, ex.size);
    ro = mmap(NULL, ex.size, PROT_READ, MAP_SHARED, ex.fd, 0);
    if (ro != MAP_FAILED) {
        if (mprotect(ro, ex.size, PROT_READ | PROT_WRITE))
            mp_errno = errno;
        munmap(ro, ex.size);
    } else {
        ro_errno = errno;
    }
    ok = flflags >= 0 && (flflags & O_ACCMODE) == O_RDONLY && rw == MAP_FAILED &&
         ro != MAP_FAILED && mp_errno != 0;
    printf("%s read-only export of %#llx: fd %d, %s, writable mmap %s, read-only mmap %s, mprotect to writable %s\n",
           ok ? "PASS" : "FAIL", (unsigned long long)phys, ex.fd,
           flflags >= 0 && (flflags & O_ACCMODE) == O_RDONLY ? "O_RDONLY" : "not O_RDONLY",
           rw == MAP_FAILED ? strerror(wr_errno) : "ALLOWED",
           ro != MAP_FAILED ? "ok" : strerror(ro_errno),
           mp_errno ? strerror(mp_errno) : "ALLOWED");
    close(ex.fd);
    return ok;
}

/*
 * The end bound, from the live allocation on: its last byte must export as
 * part of it, and the byte after it must fail, unless the next allocation
 * starts right there. Such neighbours are walked until an end that nothing
 * follows, which must then fail with EINVAL.
 */
static bool ion_end_bound(int ion, uint64_t phys)
{
    struct soph_ion_export ex;
    uint64_t base, size, last;
    int ret;

    for (int hop = 0; hop < 64; hop++) {
        ret = ion_export(ion, phys, O_CLOEXEC, &ex);
        if (ret) {
            printf("FAIL export of %#llx: %s\n", (unsigned long long)phys, strerror(-ret));
            return false;
        }
        close(ex.fd);
        base = phys - ex.offset;
        size = ex.size;
        last = base + size - 1;

        ret = ion_export(ion, last, O_CLOEXEC, &ex);
        if (ret || ex.offset != size - 1 || ex.size != size) {
            printf("FAIL last byte %#llx of the allocation at %#llx: %s\n",
                   (unsigned long long)last, (unsigned long long)base,
                   ret ? strerror(-ret) : "a different allocation");
            if (!ret)
                close(ex.fd);
            return false;
        }
        close(ex.fd);
        printf("PASS last byte %#llx of the allocation at %#llx (%llu B): offset %llu\n",
               (unsigned long long)last, (unsigned long long)base,
               (unsigned long long)size, (unsigned long long)ex.offset);

        ret = ion_export(ion, last + 1, O_CLOEXEC, &ex);
        if (ret == -EINVAL) {
            printf("PASS %#llx, the byte after it: Invalid argument\n",
                   (unsigned long long)(last + 1));
            return true;
        }
        if (ret) {
            printf("FAIL %#llx, the byte after it: %s\n", (unsigned long long)(last + 1),
                   strerror(-ret));
            return false;
        }
        close(ex.fd);
        if (ex.offset != 0) {
            printf("FAIL %#llx, the byte after it, exported at offset %llu\n",
                   (unsigned long long)(last + 1), (unsigned long long)ex.offset);
            return false;
        }
        printf("     %#llx, the byte after it, starts the next allocation: trying its end\n",
               (unsigned long long)(last + 1));
        phys = last + 1;
    }
    printf("FAIL no allocation end without a neighbour in 64 allocations\n");
    return false;
}

static int cmd_ion_reject(struct kms *k, int argc, char **argv)
{
    static const struct option opts[] = {
        { "live", required_argument, NULL, 'l' },
        { 0 },
    };
    unsigned long long live = 0;
    bool have_live = false, ok = true;
    char *end;
    int c, ion;

    (void)k;
    while ((c = getopt_long(argc, argv, "", opts, NULL)) != -1) {
        if (c != 'l')
            break;
        errno = 0;
        live = strtoull(optarg, &end, 0);
        if (errno || end == optarg || *end)
            break;
        have_live = true;
        c = 0;
    }
    if (c > 0 || optind != argc) {
        fprintf(stderr, "usage: ion-reject %s\n", ION_REJECT_ARGS);
        return 2;
    }

    ion = open(ION_DEVICE, O_RDWR | O_CLOEXEC);
    if (ion < 0) {
        fprintf(stderr, "open %s: %s\n", ION_DEVICE, strerror(errno));
        return 2;
    }

    ok &= ion_refused(ion, "phys 0", 0, O_CLOEXEC);
    ok &= ion_refused(ion, "phys 0x80000000 (the start of DRAM)", DRAM_BASE, O_CLOEXEC);
    /* On a live allocation only the flags can make the export fail. */
    ok &= ion_refused(ion, have_live ? "flags 0x1 on the live allocation" : "flags 0x1",
                      have_live ? live : DRAM_BASE, 0x1);
    if (have_live) {
        ok &= ion_exported(ion, live);
        ok &= ion_exported_rdonly(ion, live);
        ok &= ion_end_bound(ion, live);
    }

    close(ion);
    printf("ion-reject: %s\n", ok ? "every case as expected" : "FAILED");
    return ok ? 0 : 1;
}

/* dispatch */

struct command {
    const char *name;
    /* Opens the device as DRM master before run(); else run() gets NULL. */
    bool needs_kms;
    int (*run)(struct kms *k, int argc, char **argv);
    const char *args;
};

static const struct command commands[] = {
    { "reject", true, cmd_reject, "" },
    { "bars", true, cmd_bars, BARS_ARGS },
    { "flip", true, cmd_flip, FLIP_ARGS },
    { "ion-reject", false, cmd_ion_reject, ION_REJECT_ARGS },
};

static void usage(void)
{
    fprintf(stderr, "usage: badge-kms-check [--device PATH] <command> [options]\n");
    for (size_t i = 0; i < sizeof(commands) / sizeof(commands[0]); i++)
        fprintf(stderr, "  %s%s%s\n", commands[i].name, *commands[i].args ? " " : "",
                commands[i].args);
}

int main(int argc, char **argv)
{
    const char *device = "/dev/dri/card1";
    const struct command *cmd = NULL;
    struct sigaction sa = { .sa_handler = on_signal };
    struct kms k;
    int i = 1, ret;

    if (i + 1 < argc && !strcmp(argv[i], "--device")) {
        device = argv[i + 1];
        i += 2;
    }
    for (size_t j = 0; i < argc && j < sizeof(commands) / sizeof(commands[0]); j++)
        if (!strcmp(argv[i], commands[j].name))
            cmd = &commands[j];
    if (!cmd) {
        usage();
        return 2;
    }

    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);

    if (cmd->needs_kms && kms_open(&k, device))
        return 2;
    /* The command sees its own name as argv[0]. */
    optind = 1;
    ret = cmd->run(cmd->needs_kms ? &k : NULL, argc - i, argv + i);
    if (cmd->needs_kms)
        kms_close(&k);
    return ret;
}
