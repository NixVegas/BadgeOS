/*
 * "Nix Fixes This" -- a software-rendered demoscene prod for the badge.
 *
 * Target: Milk-V Duo S / SG2000, a single ~1GHz Cortex-A53, no GPU, 351MB RAM.
 * Every pixel here is drawn by the CPU into a WxH ARGB framebuffer. The last
 * pass, nft_pack, writes it with the scene fade straight into the window
 * surface's pixel format (24bpp B,G,R on the badge's desktop, what the display
 * scans out) and SDL_UpdateWindowSurface presents it: no texture, no renderer,
 * no GL. When the window surface is not WxH (the 640x360 output mode), SDL's
 * software renderer scales the frame onto the window instead.
 *
 * Music is a procedural Virus-style supersaw trance track generated in the SDL
 * audio callback: 7-voice detuned supersaw lead + a 3-note supersaw pad + a fat
 * supersaw bass, all through resonant state-variable lowpass filters swept by a
 * slow LFO and per-note envelopes, over a 4-on-floor kick + offbeat hats, soft-
 * saturated for drive. The visuals read the audio sample counter as the master
 * clock AND a per-beat kick envelope (g_kick) for beat-reactive punch.
 *
 * Nine scenes: plasma title, rotozoomer, metaballs, tunnel, fire, torus, voxel
 * flyby, the NixOS logo (six filled lambdas in a 3D pinwheel) over a starfield,
 * and copper bars behind a sine scroller -- all beat-reactive. Loops forever.
 *
 * --dump SCENE:TIME:PATH writes one frame as a PPM, the same bytes every run;
 * --selftest checks nft_pack.
 * NFT_STATS=1 prints per-scene timing, NFT_CYCLES=n quits after n cycles, and
 * NFT_FPS sets the present-rate cap.
 */
#include <SDL3/SDL.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "font8x8_basic.h"

/* Output resolution: the desktop's 1280x720. The whole prod is
 * resolution-independent (layout and effect geometry derive from W/H), so
 * -DW=640 -DH=360 builds a quarter of the per-pixel work, which the renderer
 * then scales up to the window. */
#ifndef W
#define W 1280
#endif
#ifndef H
#define H 720
#endif
#define US (H / 360)              /* UI/font scale unit: 1 at 360p, 2 at 720p */
/* 48 kHz: the badge's only audio sink is the LT8912B HDMI I2S DIT (hw:0,0, which
 * PipeWire owns and ALSA's default routes to), fixed at 48000 S16_LE. Matching
 * it here means the chiptune hits HDMI audio with no resample. */
#define SR 48000
#define PI 3.14159265358979f
#define TWO_PI 6.28318530717959f

/* ---- framebuffer + lookup tables ------------------------------------- */
/* Frame-sized buffers and tables start on a cache line, so no row of them
   straddles one more line than it needs. */
#define LINE_ALIGNED __attribute__((aligned(64)))
static uint32_t fb[W * H] LINE_ALIGNED;
static uint8_t  sin8[256];                       /* 0..255 sine */
static uint32_t pal[256] LINE_ALIGNED;           /* cyclic colour palette */
static uint8_t  tex[256 * 256] LINE_ALIGNED;     /* rotozoom texture, as tex_pal indices */
static uint32_t tex_pal[256] LINE_ALIGNED;       /* pal, but TEX_GRID is the grid colour */
static uint64_t tex_stamp[256 * 4] LINE_ALIGNED; /* its texels under a "NIX" stamp, one bit each */
static uint32_t tex2[256 * 256] LINE_ALIGNED;    /* tunnel texture */
static uint8_t  tun_d[W * H] LINE_ALIGNED;       /* tunnel depth map */
static uint8_t  tun_a[W * H] LINE_ALIGNED;       /* tunnel angle map */
static uint16_t tun_b[W * H] LINE_ALIGNED;       /* tunnel brightness map (0..256) */

static inline int clamp8(int v) { return v < 0 ? 0 : (v > 255 ? 255 : v); }
static inline uint32_t rgb(int r, int g, int b) {
    return 0xff000000u | ((uint32_t)clamp8(r) << 16)
         | ((uint32_t)clamp8(g) << 8) | (uint32_t)clamp8(b);
}

/* The rotozoom texture holds 8-bit indices: 64 KB stays in the cache, where
   256 KB of 32-bit texels would not. The weave alone uses all 256 indices
   and the grid and stamps add two colours, so two of the weave's rarest
   indices are taken over (any two would do; rarer is faster). Grid texels
   hold TEX_GRID, which tex_pal maps to the grid colour. The texels no index
   can say -- the stamps, and the few weave texels whose own index is
   TEX_GRID or TEX_ODD -- hold TEX_ODD, and tex_odd works out what they show. */
#define TEX_GRID 228
#define TEX_ODD  218
static inline unsigned tex_weave(unsigned x, unsigned y) { return ((x ^ y) + sin8[x] / 2 + sin8[y] / 2) & 255; }
static inline int tex_grid(unsigned x, unsigned y) { return (x & 31) == 0 || (y & 31) == 0; }
static __attribute__((noinline)) uint32_t tex_odd(unsigned x, unsigned y) {
    if ((tex_stamp[y * 4 + x / 64] >> (x % 64)) & 1) return rgb(15, 20, 35);
    return pal[tex_weave(x, y)];
}

/* ---- audio: a Virus-style supersaw trance engine --------------------- */
#define BPM 140.0
static volatile uint64_t g_samples = 0;   /* master clock, advanced per sample */
static double samp_per_step;              /* samples per 1/16 note */
static long   song_step = -1;

/* shared with the visuals for beat-reactivity (written by the audio thread) */
static volatile float g_kick = 0.0f;      /* kick envelope 0..1 (the beat pulse) */
static volatile float g_energy = 0.0f;    /* arrangement energy 0..1 */
static volatile float g_fenv = 0.0f;      /* lead/filter brightness 0..1 */

/* i-VI-III-VII-ish in A minor, one chord per bar, 8-bar loop. */
static const int prog[8]      = { 57, 53, 60, 55, 57, 53, 55, 55 }; /* Am F C G Am F G G */
static const int progMajor[8] = { 0,  1,  1,  1,  0,  1,  1,  1 };

/* 2-bar lead motif (1/16), A-minor; -1 = rest. */
static const int lead[32] = {
    69, -1, 72, -1, 76, -1, 72, -1, 74, -1, 72, 69, 67, -1, 69, -1,
    69, -1, 72, 74, 76, -1, 79, 76, 74, -1, 72, -1, 69, -1, -1, -1
};
/* trance drum patterns (16 steps/bar): 4-on-floor kick, offbeat open hats */
static const int kickP[16]  = { 1,0,0,0, 1,0,0,0, 1,0,0,0, 1,0,0,0 };
static const int snareP[16] = { 0,0,0,0, 1,0,0,0, 0,0,0,0, 1,0,0,0 };
static const int ohatP[16]  = { 0,0,1,0, 0,0,1,0, 0,0,1,0, 0,0,1,0 };
static const int chatP[16]  = { 1,1,1,1, 1,1,1,1, 1,1,1,1, 1,1,1,1 };

/* 7-voice supersaw detune (fractional freq offsets around the note) */
static const float sdet[7] = { -0.019f, -0.0115f, -0.0045f, 0.0f, 0.0045f, 0.0115f, 0.019f };

static float ph_lead[7], ph_bass[5], ph_pad[3][5];
static float f_lead = 440, f_bass = 110, f_pad[3] = { 440, 440, 440 };
static float env_lead = 0, env_pad = 0, env_bass = 0, env_snare = 0, env_hat = 0;
static float kick_f = 0, ph_kick = 0, env_kick = 0, ph_click = 0, env_click = 0;
static uint32_t nz_lfsr = 0x7a39u;
/* Chamberlin SVF states (resonant lowpass), one pair per voice group */
static float svf_ll = 0, svf_lb = 0;   /* lead */
static float svf_pl = 0, svf_pb = 0;   /* pad  */
static float svf_bl = 0, svf_bb = 0;   /* bass */

static float m2f(int m) { return 440.0f * powf(2.0f, (m - 69) / 12.0f); }
static inline float sawv(float p) { return 2.0f * p - 1.0f; }

/* resonant lowpass (cut in Hz, res>1 = resonance); clamped for stability */
static inline float svf_lp(float in, float *lp, float *bp, float cut, float res) {
    if (cut < 40.0f) cut = 40.0f;
    if (cut > 9000.0f) cut = 9000.0f;
    float f = 2.0f * sinf(PI * cut / SR);
    if (f > 0.99f) f = 0.99f;
    float q = 1.0f / res;
    float hp = in - *lp - q * (*bp);
    *bp += f * hp;  if (*bp > 6) *bp = 6; if (*bp < -6) *bp = -6;
    *lp += f * (*bp); if (*lp > 6) *lp = 6; if (*lp < -6) *lp = -6;
    return *lp;
}

static void trigger(long step) {
    int bar   = (int)((step / 16) % 8);
    int s16   = (int)(step % 16);
    int root  = prog[bar];
    int third = progMajor[bar] ? 4 : 3;
    double mt = step * (samp_per_step / (double)SR);

    /* bass: rolling 8ths one octave down, through the filter */
    if ((s16 % 2) == 0) { f_bass = m2f(root - 12); env_bass = 1.0f; }
    /* pad: a new supersaw chord each bar */
    if (s16 == 0) {
        f_pad[0] = m2f(root);
        f_pad[1] = m2f(root + third);
        f_pad[2] = m2f(root + 7);
        env_pad = 1.0f;
    }
    /* lead melody (octave up), reopens the filter env on each note */
    int ln = lead[step % 32];
    if (ln >= 0) { f_lead = m2f(ln + 12); env_lead = 1.0f; g_fenv = 1.0f; }

    /* drums: kick from ~3.5 s so the intro breathes; snare/hats scale w/ energy */
    int full = mt > 12.0;
    if (mt > 3.5 && kickP[s16]) { env_kick = 1.0f; kick_f = 155.0f; env_click = 1.0f; g_kick = 1.0f; }
    if (full && snareP[s16]) env_snare = 1.0f;
    if (ohatP[s16]) env_hat = full ? 0.6f : 0.25f;
    else if (full && chatP[s16]) env_hat = 0.16f;
}

/* Writes the next n samples of the track (mono, SR) to out. */
static void synth(int16_t *out, int n) {
    for (int i = 0; i < n; i++) {
        long step = (long)(g_samples / samp_per_step);
        if (step != song_step) { song_step = step; trigger(step); }
        double mt = g_samples / (double)SR;

        /* arrangement energy ramps in over the intro, then full */
        float etgt = mt > 12.0 ? 1.0f : (float)(mt / 12.0);
        g_energy += (etgt - g_energy) * 0.0005f;

        /* envelopes */
        env_lead  *= 0.99960f;
        env_pad   *= 0.999985f;
        env_bass  *= 0.99955f;
        env_snare *= 0.99150f;
        env_hat   *= 0.99000f;
        env_kick  *= 0.99930f;
        env_click *= 0.99500f;
        g_kick    *= 0.99930f;
        g_fenv    *= 0.99965f;
        kick_f    += (48.0f - kick_f) * 0.0010f;

        /* the Virus move: a resonant filter swept by a slow LFO + the note env */
        float lfo = 0.5f + 0.5f * sinf((float)mt * 0.9f);
        float lead_cut = 300.0f + g_energy * (900.0f + 3200.0f * lfo) + g_fenv * 3800.0f;
        float pad_cut  = 220.0f + g_energy * (500.0f + 1700.0f * lfo);
        float bass_cut = 420.0f + g_energy * 500.0f;

        float s = 0.0f;

        /* lead: 7-saw supersaw through a resonant lowpass */
        float ls = 0.0f;
        for (int v = 0; v < 7; v++) {
            ph_lead[v] += f_lead * (1.0f + sdet[v]) / SR; if (ph_lead[v] >= 1) ph_lead[v] -= 1;
            ls += sawv(ph_lead[v]);
        }
        ls = svf_lp(ls * (1.0f / 7.0f), &svf_ll, &svf_lb, lead_cut, 2.6f);
        s += ls * 0.26f * env_lead * (0.4f + 0.6f * g_energy);

        /* pad: 3-note supersaw stack (5 saws each), softer filter */
        float ps = 0.0f;
        for (int nn = 0; nn < 3; nn++)
            for (int v = 0; v < 5; v++) {
                ph_pad[nn][v] += f_pad[nn] * (1.0f + sdet[v]) / SR; if (ph_pad[nn][v] >= 1) ph_pad[nn][v] -= 1;
                ps += sawv(ph_pad[nn][v]);
            }
        ps = svf_lp(ps * (1.0f / 15.0f), &svf_pl, &svf_pb, pad_cut, 1.5f);
        s += ps * 0.20f * env_pad * g_energy;

        /* bass: 5-saw detuned supersaw, filtered */
        float bs = 0.0f;
        for (int v = 0; v < 5; v++) {
            ph_bass[v] += f_bass * (1.0f + sdet[v] * 0.4f) / SR; if (ph_bass[v] >= 1) ph_bass[v] -= 1;
            bs += sawv(ph_bass[v]);
        }
        bs = svf_lp(bs * (1.0f / 5.0f), &svf_bl, &svf_bb, bass_cut, 1.2f);
        s += bs * 0.26f * env_bass;

        /* kick: punchy sine with a fast pitch drop + a saw click transient */
        ph_kick += kick_f / SR; if (ph_kick >= 1) ph_kick -= 1;
        s += sinf(ph_kick * TWO_PI) * 0.80f * env_kick;
        ph_click += 1800.0f / SR; if (ph_click >= 1) ph_click -= 1;
        s += sawv(ph_click) * 0.25f * env_click;

        /* noise -> snare + hats */
        nz_lfsr = (nz_lfsr >> 1) ^ (uint32_t)((-(int32_t)(nz_lfsr & 1)) & 0xB400u);
        float nz = ((nz_lfsr & 0xffff) / 32768.0f) - 1.0f;
        s += nz * 0.24f * env_snare;
        s += nz * 0.10f * env_hat;

        /* soft saturation (Virus-ish drive) + output */
        s = tanhf(s * 1.25f) * 0.72f;
        out[i] = (int16_t)(s * 32767.0f);
        g_samples++;
    }
}

/* The device stream asks for bytes; synth them in blocks the size the device
   was opened with. g_samples, the visuals' clock, counts every one. */
#define AUDIO_FRAMES 1024
static void SDLCALL audio_cb(void *ud, SDL_AudioStream *stream, int additional, int total) {
    (void)ud; (void)total;
    static int16_t buf[AUDIO_FRAMES];
    while (additional > 0) {
        int n = additional / (int)sizeof(buf[0]);
        if (n > AUDIO_FRAMES) n = AUDIO_FRAMES;
        if (n < 1) n = 1;
        synth(buf, n);
        SDL_PutAudioStreamData(stream, buf, n * (int)sizeof(buf[0]));
        additional -= n * (int)sizeof(buf[0]);
    }
}

/* ---- text -------------------------------------------------------------- */
static void draw_char(int px, int py, int scale, char ch, uint32_t col) {
    unsigned c = (unsigned char)ch;
    if (c >= 128) c = '?';
    const char *g = font8x8_basic[c];
    for (int row = 0; row < 8; row++) {
        unsigned bits = (unsigned char)g[row];
        for (int cx = 0; cx < 8; cx++) {
            if (!(bits & (1u << cx))) continue;
            for (int sy = 0; sy < scale; sy++)
                for (int sx = 0; sx < scale; sx++) {
                    int x = px + cx * scale + sx;
                    int y = py + row * scale + sy;
                    if ((unsigned)x < W && (unsigned)y < H) fb[y * W + x] = col;
                }
        }
    }
}
static void draw_text(int x, int y, int scale, const char *s, uint32_t col) {
    for (; *s; s++) { draw_char(x, y, scale, *s, col); x += 8 * scale; }
}
static int text_w(int scale, const char *s) { return (int)strlen(s) * 8 * scale; }

/* ---- palette + textures (built once) ---------------------------------- */
static void build_tables(void) {
    for (int i = 0; i < 256; i++)
        sin8[i] = (uint8_t)(128 + 127 * sinf(i / 256.0f * TWO_PI));

    /* a vivid cyclic palette, biased toward Nix blues/cyans/violets */
    for (int i = 0; i < 256; i++) {
        float a = i / 256.0f * TWO_PI;
        int r = (int)(90 + 90 * sinf(a + 0.0f));
        int g = (int)(120 + 110 * sinf(a + 2.1f));
        int b = (int)(150 + 105 * sinf(a + 4.0f));
        pal[i] = rgb(r, g, b);
    }

    /* rotozoom texture: coloured XOR weave + a grid + tiled "NIX" */
    for (int i = 0; i < 256; i++) tex_pal[i] = pal[i];
    tex_pal[TEX_GRID] = rgb(230, 240, 255);
    for (int y = 0; y < 256; y++)
        for (int x = 0; x < 256; x++) {
            unsigned w = tex_weave(x, y);
            tex[y * 256 + x] = tex_grid(x, y) ? TEX_GRID : (w == TEX_GRID || w == TEX_ODD) ? TEX_ODD : w;
        }
    /* render-time glue cannot call draw_char into tex (it targets fb), so inline
       a couple of "NIX" stamps straight into the texture using the font. */
    for (int ty = 0; ty < 4; ty++)
        for (int tx = 0; tx < 4; tx++) {
            int ox = tx * 64 + 20, oy = ty * 64 + 28;
            const char *s = "NIX";
            for (int k = 0; s[k]; k++) {
                const char *gl = font8x8_basic[(unsigned char)s[k]];
                for (int r = 0; r < 8; r++)
                    for (int cc = 0; cc < 8; cc++)
                        if (((unsigned char)gl[r]) & (1u << cc)) {
                            int X = (ox + k * 9 + cc) & 255, Y = (oy + r) & 255;
                            tex[Y * 256 + X] = TEX_ODD;
                            tex_stamp[Y * 4 + X / 64] |= 1ull << (X % 64);
                        }
            }
        }

    /* tunnel texture: bright/dark tiled cells so motion is obvious */
    for (int y = 0; y < 256; y++)
        for (int x = 0; x < 256; x++) {
            int cell = ((x >> 4) + (y >> 4)) & 1;
            tex2[y * 256 + x] = cell ? pal[(x + y) & 255] : rgb(14, 16, 30);
        }

    /* tunnel geometry maps (depth + brightness scale with resolution) */
    float maxr  = sqrtf((W / 2.0f) * (W / 2.0f) + (H / 2.0f) * (H / 2.0f));
    float depthk = 2.65f * W;                      /* 640->1696, 1280->3392 */
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++) {
            float dx = x - W / 2.0f, dy = y - H / 2.0f;
            float dist = sqrtf(dx * dx + dy * dy);
            float ang  = atan2f(dy, dx);
            int i = y * W + x;
            tun_d[i] = (uint8_t)(depthk / (dist + 1.0f));
            tun_a[i] = (uint8_t)((int)((ang / TWO_PI + 0.5f) * 256.0f) & 255);
            int br = (int)(dist / maxr * 333.0f);  /* centre dark (far), edges bright */
            tun_b[i] = (uint16_t)(br > 256 ? 256 : br);
        }
}

/* Each channel times f, shifted down 8. Red and blue share one multiply:
   with f <= 256 each product stays below 2^16, so the two cannot meet. */
static inline uint32_t scale_rgb(uint32_t c, int f /*0..256*/) {
    uint32_t rb = (c & 0xff00ffu) * (uint32_t)f >> 8 & 0xff00ffu;
    uint32_t g = (c & 0xff00u) * (uint32_t)f >> 8 & 0xff00u;
    return 0xff000000u | rb | g;
}

/* ---- the final pass ---------------------------------------------------- */
/* One row of 24bpp pixels; red goes to byte r_at and blue to byte 2 - r_at.
   Inlined with a constant r_at, so each format gets its own loop. */
static inline __attribute__((always_inline))
void pack24(const uint32_t *src, uint8_t *dst, int n, int r_at, int fade) {
    if (fade >= 256) {
        for (int i = 0; i < n; i++, dst += 3) {
            uint32_t p = src[i];
            dst[r_at]     = (uint8_t)(p >> 16);
            dst[1]        = (uint8_t)(p >> 8);
            dst[2 - r_at] = (uint8_t)p;
        }
    } else {
        for (int i = 0; i < n; i++, dst += 3) {
            uint32_t p = src[i];
            dst[r_at]     = (uint8_t)((((p >> 16) & 255) * fade) >> 8);
            dst[1]        = (uint8_t)((((p >> 8) & 255) * fade) >> 8);
            dst[2 - r_at] = (uint8_t)(((p & 255) * fade) >> 8);
        }
    }
}

/* Packs n 0xFFRRGGBB pixels from src into dst in fmt -- SDL_PIXELFORMAT_BGR24
   (bytes B,G,R), RGB24 (R,G,B) or XRGB8888 -- scaled by fade (0..256) as
   scale_rgb scales. XRGB8888 may pack in place. Any other format writes
   nothing. */
static void nft_pack(const uint32_t *src, uint8_t *dst, int n, SDL_PixelFormat fmt, int fade) {
    if (fade < 0) fade = 0;
    if (fade > 256) fade = 256;
    switch (fmt) {
        case SDL_PIXELFORMAT_BGR24: pack24(src, dst, n, 2, fade); break;
        case SDL_PIXELFORMAT_RGB24: pack24(src, dst, n, 0, fade); break;
        case SDL_PIXELFORMAT_XRGB8888: {
            uint32_t *d = (uint32_t *)dst;
            if (fade < 256)
                for (int i = 0; i < n; i++) d[i] = scale_rgb(src[i], fade);
            else if (d != src)
                memcpy(d, src, (size_t)n * sizeof(*d));
            break;
        }
        default:
            break;
    }
}

/* ---- scenes ------------------------------------------------------------ */
static void scene_plasma_title(double mt) {
    int t  = (int)(mt * 42);
    int t2 = (int)(mt * 28);
    static uint8_t colv[W], rowv[H], diag[W + H];
    for (int x = 0; x < W; x++) colv[x] = sin8[(x + t) & 255];
    for (int y = 0; y < H; y++) rowv[y] = sin8[(y - t + 512) & 255];
    for (int d = 0; d < W + H; d++) diag[d] = sin8[((d >> 1) + t2) & 255];
    for (int y = 0; y < H; y++) {
        uint32_t *row = &fb[y * W];
        uint8_t rv = rowv[y];
        const uint8_t *dg = &diag[y];
        for (int x = 0; x < W; x++) {
            int v = (colv[x] + rv + dg[x]) / 3;
            row[x] = pal[(v + t2) & 255];
        }
    }
    /* "NIX FIXES THIS": blocky, per-letter sine bounce + shadow, palette-cycled */
    const char *title = "NIX FIXES THIS";
    int scale = 4 * US, n = (int)strlen(title);
    int tw = n * 8 * scale;
    int x0 = (W - tw) / 2, baseY = (int)(H * 0.40f);
    float kick = g_kick;
    int sh = 2 * US, amp = (int)((10.0f + 16.0f * kick) * US);
    int tb = (int)(kick * 95);   /* beat-brighten the letters toward white */
    for (int k = 0; k < n; k++) {
        int yo = (int)(sinf(mt * 3.0f + k * 0.55f) * amp);
        int cx = x0 + k * 8 * scale;
        uint32_t col = pal[(k * 14 + (int)(mt * 60)) & 255];
        col = rgb(((col >> 16) & 255) + tb, ((col >> 8) & 255) + tb, (col & 255) + tb);
        draw_char(cx + sh, baseY + yo + sh, scale, title[k], rgb(10, 12, 24));
        draw_char(cx, baseY + yo, scale, title[k], col);
    }
    /* a thin tagline */
    const char *sub = "SOFTWARE RENDERED. NO GPU.";
    draw_text((W - text_w(2 * US, sub)) / 2, (int)(H * 0.64f), 2 * US, sub, rgb(200, 220, 255));
}

/* Rotozoom draws in strips this wide, so the texels one row of a strip reads
   are still cached when the next row reads their neighbours. */
#define ROTO_STRIP 128
_Static_assert(W % ROTO_STRIP == 0 && ROTO_STRIP % 4 == 0, "rotozoom draws whole strips, four pixels per step");

/* n pixels of one rotozoom row from 16.16 texture coordinates (u, v),
   stepping (du, dv) per pixel, wrapping mod 2^32. Four texels per step, all
   loaded before any is stored, so the in-order core overlaps the loads. */
static void roto_row(uint32_t *restrict row, int n, uint32_t u, uint32_t v, uint32_t du, uint32_t dv) {
    for (int x = 0; x < n; x += 4) {
        unsigned t[4], i[4];
        uint32_t c[4];
        for (int j = 0; j < 4; j++) {
            t[j] = (v >> 16 & 255) << 8 | (u >> 16 & 255);
            u += du; v += dv;
        }
        for (int j = 0; j < 4; j++) i[j] = tex[t[j]];
        if (__builtin_expect((i[0] == TEX_ODD) | (i[1] == TEX_ODD) | (i[2] == TEX_ODD) | (i[3] == TEX_ODD), 0))
            for (int j = 0; j < 4; j++) c[j] = i[j] == TEX_ODD ? tex_odd(t[j] & 255, t[j] >> 8) : tex_pal[i[j]];
        else
            for (int j = 0; j < 4; j++) c[j] = tex_pal[i[j]];
        for (int j = 0; j < 4; j++) row[x + j] = c[j];
    }
}

static void scene_rotozoom(double mt) {
    float a = mt * 0.7f;
    float zoom = 1.25f + 0.8f * sinf(mt * 0.9f) + 0.55f * g_kick;  /* punch on the beat */
    int cs = (int)(cosf(a) * zoom * 65536.0f);
    int sn = (int)(sinf(a) * zoom * 65536.0f);
    int offx = (int)(mt * 42.0f * 65536.0f);
    int offy = (int)(mt * 26.0f * 65536.0f);
    for (int x0 = 0; x0 < W; x0 += ROTO_STRIP)
        for (int y = 0; y < H; y++) {
            /* 16.16 texture coordinates of pixel (x0, y) */
            uint32_t u = (uint32_t)((x0 - W / 2) * (int64_t)cs - (int64_t)(y - H / 2) * sn) + (uint32_t)offx;
            uint32_t v = (uint32_t)((x0 - W / 2) * (int64_t)sn + (int64_t)(y - H / 2) * cs) + (uint32_t)offy;
            roto_row(&fb[y * W + x0], ROTO_STRIP, u, v, (uint32_t)cs, (uint32_t)sn);
        }
    const char *s = "ROTOZOOMER";
    draw_text((W - text_w(2 * US, s)) / 2, (int)(H * 0.05f), 2 * US, s, rgb(255, 255, 255));
}

static void scene_tunnel(double mt) {
    int t1 = (int)(mt * 70);
    int t2 = (int)(mt * 40);
    int kb = (int)(g_kick * 80);   /* beat brightness, read once per frame */
    for (int i = 0; i < W * H; i++) {
        uint8_t d = (uint8_t)(tun_d[i] + t1);
        uint8_t a = (uint8_t)(tun_a[i] + t2);
        uint32_t c = tex2[((unsigned)a << 8) | d];
        int bb = (int)tun_b[i] + kb; if (bb > 256) bb = 256;
        fb[i] = scale_rgb(c, bb);
    }
    const char *s = "INTO THE TUNNEL";
    draw_text((W - text_w(2 * US, s)) / 2, (int)(H * 0.05f), 2 * US, s, rgb(235, 245, 255));
}

static void put_add(int x, int y, uint32_t c) {
    if ((unsigned)x >= W || (unsigned)y >= H) return;
    fb[y * W + x] = c;
}

/* ---- the NixOS logo (filled 3D lambdas) over a perspective starfield --- */
#define NSTARS 420
static float st_x[NSTARS], st_y[NSTARS], st_z[NSTARS];

/* The OFFICIAL NixOS logomark, straight from the source polygon of
   brand.nixos.org/logos/nixos-logomark-default-gradient-minimal.svg: ONE
   9-vertex lambda polygon, replicated at six angles (the SVG is six <polygon>s
   rotated 0/60/120/180/240/300 deg, the two gradient families alternating). */
#define NLAM 6
#define NLV  9
static float lamx[NLAM][NLV], lamy[NLAM][NLV];
static uint32_t lam_col[NLAM];
static const uint32_t NIX_DK = 0xff4564a5u;  /* dark-blue gradient family (mid) */
static const uint32_t NIX_LT = 0xff72a9cfu;  /* light-blue gradient family (mid) */

static void logo_init(void) {
    for (int i = 0; i < NSTARS; i++) {
        st_x[i] = (rand() / (float)RAND_MAX - 0.5f) * 2.0f;
        st_y[i] = (rand() / (float)RAND_MAX - 0.5f) * 2.0f;
        st_z[i] = (rand() / (float)RAND_MAX) * 0.98f + 0.02f;
    }
    /* the SVG polygon's nine points with the SVG rotate-centre (320, -554.256)
       subtracted -- which, because the SVG's translate maps that centre to the
       origin, leaves the mark centred on (0,0). Normalised to ~unit radius and
       spun to 0/60/.../300 deg (SVG y is down, matching our screen y). */
    static const float base[NLV][2] = {
        { -624.0f, 249.4153f }, { -496.0f,  27.7128f }, {   64.0f, 997.6613f },
        { -192.0f, 997.6613f }, { -320.0f, 775.9588f }, { -448.0f, 997.6613f },
        { -576.0f, 997.6613f }, { -640.0f, 886.8100f }, { -448.0f, 554.2563f }
    };
    const float norm = 1150.0f;
    for (int k = 0; k < NLAM; k++) {
        float a = k * (TWO_PI / 6.0f), c = cosf(a), s = sinf(a);
        for (int i = 0; i < NLV; i++) {
            float bx = base[i][0] / norm, by = base[i][1] / norm;
            lamx[k][i] = bx * c - by * s;
            lamy[k][i] = bx * s + by * c;
        }
        lam_col[k] = (k & 1) ? NIX_LT : NIX_DK;
    }
}

/* flat-shaded convex-OR-concave polygon fill (scanline, even-odd), clipped */
static void fill_poly(const int *px, const int *py, int n, uint32_t c) {
    int ymin = H, ymax = -1;
    for (int i = 0; i < n; i++) { if (py[i] < ymin) ymin = py[i]; if (py[i] > ymax) ymax = py[i]; }
    if (ymin < 0) ymin = 0;
    if (ymax >= H) ymax = H - 1;
    for (int y = ymin; y <= ymax; y++) {
        float xc[24]; int nc = 0;
        for (int i = 0; i < n; i++) {
            int j = (i + 1 == n) ? 0 : i + 1;
            int y0 = py[i], y1 = py[j];
            if ((y0 <= y && y1 > y) || (y1 <= y && y0 > y)) {
                float t = (float)(y - y0) / (float)(y1 - y0);
                if (nc < 24) xc[nc++] = px[i] + t * (px[j] - px[i]);
            }
        }
        for (int a = 1; a < nc; a++) { float v = xc[a]; int b = a - 1; while (b >= 0 && xc[b] > v) { xc[b+1]=xc[b]; b--; } xc[b+1]=v; }
        uint32_t *row = &fb[y * W];
        for (int a = 0; a + 1 < nc; a += 2) {
            int l = (int)xc[a], r = (int)xc[a + 1];
            if (l < 0) l = 0;
            if (r >= W) r = W - 1;
            for (int x = l; x <= r; x++) row[x] = c;
        }
    }
}

static void scene_nixlogo(double mt, float dt) {
    for (int i = 0; i < W * H; i++) fb[i] = rgb(5, 6, 14);
    float kick = g_kick;                 /* 0..1 beat pulse */
    /* starfield (accelerates on the beat) */
    for (int i = 0; i < NSTARS; i++) {
        st_z[i] -= dt * (0.5f + 0.9f * kick);
        if (st_z[i] < 0.02f) {
            st_x[i] = (rand() / (float)RAND_MAX - 0.5f) * 2.0f;
            st_y[i] = (rand() / (float)RAND_MAX - 0.5f) * 2.0f;
            st_z[i] = 1.0f;
        }
        float pf = 0.47f * W;
        int sx = (int)(W / 2 + st_x[i] / st_z[i] * pf);
        int sy = (int)(H / 2 + st_y[i] / st_z[i] * pf);
        int b = (int)((1.0f - st_z[i]) * 220.0f);
        for (int ty = 0; ty < US; ty++)
            for (int tx = 0; tx < US; tx++)
                put_add(sx + tx, sy + ty, rgb(b, b, clamp8(b + 30)));
    }
    /* mostly face-on so it reads as the logo: a steady in-plane spin (the mark
       is already a pinwheel) plus a gentle depth wobble; beat-pulse the size. */
    float az = mt * 0.45f;
    float ax = sinf(mt * 0.5f) * 0.30f;
    float ay = sinf(mt * 0.38f) * 0.34f;
    float cx = cosf(ax), sxx = sinf(ax), cy = cosf(ay), syy = sinf(ay), cz = cosf(az), sz = sinf(az);
    float scale = (340.0f + 45.0f * kick) * US, zcam = 2.8f;
    static float pz[NLAM]; static int order[NLAM];
    static int pxs[NLAM][NLV], pys[NLAM][NLV];
    for (int k = 0; k < NLAM; k++) {
        float zsum = 0;
        for (int i = 0; i < NLV; i++) {
            float x = lamx[k][i], y = lamy[k][i], z = 0.0f;
            float x1 = x * cz - y * sz, y1 = x * sz + y * cz;
            float x2 = x1 * cy + z * syy, z2 = -x1 * syy + z * cy;
            float y3 = y1 * cx - z2 * sxx, z3 = y1 * sxx + z2 * cx;
            float Z = z3 + zcam;
            pxs[k][i] = (int)(W / 2 + x2 / Z * scale);
            pys[k][i] = (int)(H / 2 + y3 / Z * scale);
            zsum += z3;
        }
        pz[k] = zsum; order[k] = k;
    }
    for (int a = 1; a < NLAM; a++) {   /* insertion sort: far (larger z) first */
        int k = order[a]; float kv = pz[k]; int b = a - 1;
        while (b >= 0 && pz[order[b]] < kv) { order[b + 1] = order[b]; b--; }
        order[b + 1] = k;
    }
    int glow = (int)(185 + 70 * kick);
    for (int oi = 0; oi < NLAM; oi++) {
        int k = order[oi];
        fill_poly(pxs[k], pys[k], NLV, scale_rgb(lam_col[k], glow));
    }
    const char *s = "POWERED BY NIXOS";
    draw_text((W - text_w(2 * US, s)) / 2, (int)(H * 0.05f), 2 * US, s, rgb(180, 210, 245));
    const char *s2 = "ONE CORE  NO GPU";
    draw_text((W - text_w(US, s2)) / 2, H - (int)(H * 0.07f), US, s2, rgb(120, 160, 210));
}

/* ======== extra scenes: fire, metaballs, 3D torus, voxel terrain ========= */
static uint8_t  firebuf[W * H] LINE_ALIGNED;
static int      fire_top = H;                    /* firebuf rows above this are all zero */
static uint32_t firepal[256] LINE_ALIGNED;
#define MB_BS 200
static uint8_t  mb_blob[MB_BS * MB_BS] LINE_ALIGNED;
static uint16_t mb_acc[W] LINE_ALIGNED;          /* one row of blob sums */
static uint32_t mb_pal[256] LINE_ALIGNED;
#define TMJ 18
#define TMI 11
static float tor_x[TMJ * TMI], tor_y[TMJ * TMI], tor_z[TMJ * TMI];
static uint8_t  vox_h[256 * 256] LINE_ALIGNED;
static uint32_t vox_pal[256] LINE_ALIGNED;       /* terrain colour by height */
static uint32_t vox_sky[H] LINE_ALIGNED;         /* sky gradient by row */

static void extra_init(void) {
    /* fire palette: black -> red -> orange -> light orange (no white: this is a
       full-screen bright scene and badge #1's HDMI link is marginal). */
    for (int i = 0; i < 256; i++) {
        int r, g, b;
        if (i < 100)      { r = i * 255 / 100; g = 0; b = 0; }
        else if (i < 200) { r = 255; g = (i - 100) * 170 / 100; b = 0; }
        else              { r = 255; g = 170 + (i - 200) * 40 / 55; b = (i - 200) * 70 / 55; }
        firepal[i] = rgb(r, g, b);
    }
    /* metaball additive blob + a gooey blue palette */
    for (int y = 0; y < MB_BS; y++)
        for (int x = 0; x < MB_BS; x++) {
            float dx = x - MB_BS / 2.0f, dy = y - MB_BS / 2.0f;
            float v = 1.0f / (1.0f + (dx * dx + dy * dy) / 500.0f);
            mb_blob[y * MB_BS + x] = (uint8_t)(v * 200.0f);
        }
    for (int i = 0; i < 256; i++) {
        int r, g, b;
        if (i < 150)      { r = 6 + i / 7; g = 10 + i / 5; b = 26 + i / 3; }
        else if (i < 212) { int t = i - 150; r = 27 + t / 2; g = 40 + t * 2; b = 71 + t; }
        else              { int t = i - 212; r = 58 + t * 3; g = 164 + t; b = 114 + t * 2; }
        mb_pal[i] = rgb(r, g, b);
    }
    /* torus mesh */
    for (int i = 0; i < TMJ; i++)
        for (int j = 0; j < TMI; j++) {
            float u = i / (float)TMJ * TWO_PI, v = j / (float)TMI * TWO_PI;
            float R = 0.68f, rr = 0.30f;
            int n = i * TMI + j;
            tor_x[n] = (R + rr * cosf(v)) * cosf(u);
            tor_y[n] = (R + rr * cosf(v)) * sinf(u);
            tor_z[n] = rr * sinf(v);
        }
    /* voxel heightmap + Nix-blue terrain colourmap */
    for (int y = 0; y < 256; y++)
        for (int x = 0; x < 256; x++) {
            float fx = x / 256.0f * TWO_PI, fy = y / 256.0f * TWO_PI;
            float h = 0.5f + 0.24f * sinf(fx * 2) * cosf(fy * 2)
                    + 0.15f * sinf(fx * 5 + 1.3f) * sinf(fy * 3)
                    + 0.08f * cosf(fx * 9) * cosf(fy * 7);
            if (h < 0) h = 0;
            if (h > 1) h = 1;
            vox_h[y * 256 + x] = (uint8_t)(h * 255);
        }
    for (int hh = 0; hh < 256; hh++) {
        int r, g, b;
        if (hh < 90)       { r = 10; g = 20; b = 55 + hh / 2; }
        else if (hh < 160) { int t = hh - 90; r = 28 + t / 2; g = 58 + t; b = 118 + t / 2; }
        else if (hh < 210) { int t = hh - 160; r = 58 + t; g = 118 + t; b = 168 + t / 2; }
        else               { int t = hh - 210; r = 120 + t * 2; g = 178 + t; b = 205 + t; }
        vox_pal[hh] = rgb(r, g, b);
    }
    for (int y = 0; y < H; y++) vox_sky[y] = rgb(10 + y * 24 / H, 16 + y * 34 / H, 46 + y * 70 / H);
}

static void scene_fire(double mt) {
    (void)mt;
    for (int x = 0; x < W; x++) {         /* seed embers along the bottom */
        firebuf[(H - 1) * W + x] = (uint8_t)(rand() & 255);
        firebuf[(H - 2) * W + x] = (uint8_t)(rand() & 255);
    }
    /* A row takes its heat from the two below it, so in one frame the fire
       climbs at most two rows above fire_top (or the embers just seeded);
       the rows above that are still zero and keep their palette colour. */
    int lit = fire_top < H - 2 ? fire_top : H - 2;
    int top = H - 2;
    for (int y = lit - 2 < 0 ? 0 : lit - 2; y < H - 2; y++) {   /* propagate up (cooling 32/129) */
        unsigned any = 0;
        for (int x = 1; x < W - 1; x++) {
            int s = firebuf[(y + 1) * W + x - 1] + firebuf[(y + 1) * W + x]
                  + firebuf[(y + 1) * W + x + 1] + firebuf[(y + 2) * W + x];
            uint8_t v = (uint8_t)((s * 32) / 129);
            firebuf[y * W + x] = v;
            any |= v;
        }
        if (any && y < top) top = y;
    }
    fire_top = top;
    for (int i = 0; i < top * W; i++) fb[i] = firepal[0];
    for (int i = top * W; i < W * H; i++) fb[i] = firepal[firebuf[i]];
    const char *s = "NIX FIXES THIS";
    draw_text((W - text_w(3 * US, s)) / 2, (int)(H * 0.10f), 3 * US, s, rgb(255, 248, 230));
}

static void scene_metaballs(double mt) {
    float kick = g_kick, amp = 0.33f + 0.05f * kick;
    int ox[6], oy[6];                     /* each blob's top-left corner */
    /* Scalar cosf and sinf: vectorised, this loop would call the vector
       versions, which round differently and move a blob by a pixel. */
#pragma GCC novector
    for (int i = 0; i < 6; i++) {
        float sp = 0.5f + i * 0.17f;
        int bx = (int)(W / 2 + cosf(mt * sp + i * 1.7f) * W * amp);
        int by = (int)(H / 2 + sinf(mt * sp * 0.8f + i * 2.3f) * H * amp);
        ox[i] = bx - MB_BS / 2; oy[i] = by - MB_BS / 2;
    }
    /* Row by row, summing the blobs only between the leftmost and rightmost
       column any of them reaches; elsewhere the sum is 0. */
    uint32_t none = mb_pal[0];
    for (int y = 0; y < H; y++) {
        uint32_t *row = &fb[y * W];
        int lo = W, hi = 0;
        for (int i = 0; i < 6; i++) {
            if (y < oy[i] || y >= oy[i] + MB_BS) continue;
            int a = ox[i] < 0 ? 0 : ox[i], b = ox[i] + MB_BS > W ? W : ox[i] + MB_BS;
            if (a < lo) lo = a;
            if (b > hi) hi = b;
        }
        if (lo >= hi) {
            for (int x = 0; x < W; x++) row[x] = none;
            continue;
        }
        for (int x = lo; x < hi; x++) mb_acc[x] = 0;
        for (int i = 0; i < 6; i++) {
            if (y < oy[i] || y >= oy[i] + MB_BS) continue;
            const uint8_t *brow = &mb_blob[(y - oy[i]) * MB_BS];
            int a = ox[i] < 0 ? -ox[i] : 0, b = ox[i] + MB_BS > W ? W - ox[i] : MB_BS;
            for (int xx = a; xx < b; xx++) mb_acc[ox[i] + xx] += brow[xx];
        }
        for (int x = 0; x < lo; x++) row[x] = none;
        for (int x = lo; x < hi; x++) { int a = mb_acc[x]; row[x] = mb_pal[a > 255 ? 255 : a]; }
        for (int x = hi; x < W; x++) row[x] = none;
    }
    const char *s = "METABALLS";
    draw_text((W - text_w(2 * US, s)) / 2, (int)(H * 0.05f), 2 * US, s, rgb(200, 230, 255));
}

static void scene_torus(double mt) {
    for (int y = 0; y < H; y++) {         /* dark vertical backdrop */
        uint32_t c = rgb(4, 5, 10 + y * 16 / H);
        uint32_t *row = &fb[y * W];
        for (int x = 0; x < W; x++) row[x] = c;
    }
    float kick = g_kick;
    float ax = mt * 0.7f, ay = mt * 0.9f, az = mt * 0.4f;
    float cx = cosf(ax), sxx = sinf(ax), cy = cosf(ay), syy = sinf(ay), cz = cosf(az), sz = sinf(az);
    float scale = (290.0f + 30.0f * kick) * US, zcam = 3.2f;
    static float rx[TMJ * TMI], ry[TMJ * TMI], rz[TMJ * TMI];
    static int sx[TMJ * TMI], sy[TMJ * TMI];
    for (int n = 0; n < TMJ * TMI; n++) {
        float x = tor_x[n], y = tor_y[n], z = tor_z[n];
        float x1 = x * cz - y * sz, y1 = x * sz + y * cz;
        float x2 = x1 * cy + z * syy, z2 = -x1 * syy + z * cy;
        float y3 = y1 * cx - z2 * sxx, z3 = y1 * sxx + z2 * cx;
        rx[n] = x2; ry[n] = y3; rz[n] = z3;
        float Z = z3 + zcam;
        sx[n] = (int)(W / 2 + x2 / Z * scale);
        sy[n] = (int)(H / 2 + y3 / Z * scale);
    }
    /* all faces, two-sided shaded, painter's z-sort (robust vs winding) */
    static float fz[TMJ * TMI]; static float fsh[TMJ * TMI]; static int fa[TMJ * TMI], ford[TMJ * TMI];
    int nf = 0;
    float lx = 0.40f, ly = 0.50f, lz = -0.77f;
    for (int i = 0; i < TMJ; i++)
        for (int j = 0; j < TMI; j++) {
            int a = i * TMI + j, b = ((i + 1) % TMJ) * TMI + j, d = i * TMI + ((j + 1) % TMI);
            float e1x = rx[b] - rx[a], e1y = ry[b] - ry[a], e1z = rz[b] - rz[a];
            float e2x = rx[d] - rx[a], e2y = ry[d] - ry[a], e2z = rz[d] - rz[a];
            float nx = e1y * e2z - e1z * e2y, ny = e1z * e2x - e1x * e2z, nz = e1x * e2y - e1y * e2x;
            float len = sqrtf(nx * nx + ny * ny + nz * nz); if (len < 1e-5f) len = 1e-5f;
            float in = (nx * lx + ny * ly + nz * lz) / len; if (in < 0) in = -in;
            if (in < 0.18f) in = 0.18f;
            if (in > 1) in = 1;
            fa[nf] = a; fz[nf] = rz[a]; fsh[nf] = in; ford[nf] = nf; nf++;
        }
    for (int a = 1; a < nf; a++) { int k = ford[a]; float kv = fz[k]; int b = a - 1; while (b >= 0 && fz[ford[b]] < kv) { ford[b+1]=ford[b]; b--; } ford[b+1]=k; }
    for (int oi = 0; oi < nf; oi++) {
        int f = ford[oi], a = fa[f];
        int i = a / TMI, j = a % TMI;
        int b = ((i + 1) % TMJ) * TMI + j, c = ((i + 1) % TMJ) * TMI + ((j + 1) % TMI), d = i * TMI + ((j + 1) % TMI);
        int px[4] = { sx[a], sx[b], sx[c], sx[d] }, py[4] = { sy[a], sy[b], sy[c], sy[d] };
        float sh = fsh[f];
        fill_poly(px, py, 4, rgb((int)(84 * sh), (int)(138 * sh), (int)(240 * sh)));
    }
    const char *s = "TORUS";
    draw_text((W - text_w(2 * US, s)) / 2, (int)(H * 0.05f), 2 * US, s, rgb(200, 220, 255));
}

/* Voxel draws this many columns per pass into a column-major buffer, then
   copies the pass into fb a row at a time. Drawn straight into fb, a span's
   pixels sit a row apart, map to a few cache sets and evict each other. */
#define VOX_COLS 16
#define VOX_ROWS 160   /* depth rows of the frustum: 145 from z = 4 to zfar */
_Static_assert(W % VOX_COLS == 0, "voxel draws whole passes");

static void scene_voxel(double mt, float dt) {
    (void)dt;
    float kick = g_kick;
    float camx = mt * 26.0f, camy = mt * 34.0f;
    float yaw = sinf(mt * 0.18f) * 0.5f;
    float camh = 170.0f + 28.0f * kick;
    float horizon = H * 0.40f, scaleh = 150.0f * US, zfar = 210.0f;
    float sy_ = sinf(yaw), cy_ = cosf(yaw);
    int skr = 10 + (int)(horizon) * 24 / H, skg = 16 + (int)(horizon) * 34 / H, skb = 46 + (int)(horizon) * 70 / H;
    /* Each depth row's map position at the next column to draw, its step per
       column, and scaleh / z (the compiler hoists that division out of the
       column loop either way; spelt out, every loop below rounds it the
       same). A pass leaves the position where the next pass starts, so every
       column gets the same additions as in one pass across the width. */
    static float rs[VOX_ROWS], rx[VOX_ROWS], ry[VOX_ROWS], rdx[VOX_ROWS], rdy[VOX_ROWS];
    static int rfog[VOX_ROWS];
    int nr = 0;
    for (float z = 4.0f, dz = 0.5f; z < zfar && nr < VOX_ROWS; z += dz, dz += 0.013f, nr++) {
        float plx = (-cy_ - sy_) * z + camx, ply = (sy_ - cy_) * z + camy;
        float prx = (cy_ - sy_) * z + camx, pry = (-sy_ - cy_) * z + camy;
        float ddx = (prx - plx) / W, ddy = (pry - ply) / W;
        int fog = (int)(z / zfar * 256.0f); if (fog > 256) fog = 256;
        rs[nr] = scaleh / z; rx[nr] = plx; ry[nr] = ply; rdx[nr] = ddx; rdy[nr] = ddy; rfog[nr] = fog;
    }
    static uint32_t cols[VOX_COLS][H] LINE_ALIGNED;
    for (int x0 = 0; x0 < W; x0 += VOX_COLS) {
        int ybuf[VOX_COLS];
        for (int i = 0; i < VOX_COLS; i++) ybuf[i] = H;
        for (int k = 0; k < nr; k++) {
            float s = rs[k], ddx = rdx[k], ddy = rdy[k];
            int fog = rfog[k];
            /* The pass's map positions on this depth row, one addition per
               column. Written as a recurrence through px so the compiler keeps
               the additions in order (under -ffast-math it would vectorise a
               running sum as px[0] + i * ddx, which rounds differently). */
            float px[VOX_COLS + 1], py[VOX_COLS + 1];
            px[0] = rx[k]; py[0] = ry[k];
            for (int i = 1; i <= VOX_COLS; i++) { px[i] = px[i - 1] + ddx; py[i] = py[i - 1] + ddy; }
            rx[k] = px[VOX_COLS]; ry[k] = py[VOX_COLS];
            /* every column's height and top first, so their latencies overlap */
            int hs[VOX_COLS], yt[VOX_COLS];
            for (int i = 0; i < VOX_COLS; i++) {
                int mx = ((int)px[i]) & 255, my = ((int)py[i]) & 255;
                hs[i] = vox_h[my * 256 + mx];
                yt[i] = (int)((camh - hs[i]) * s + horizon);
            }
            for (int i = 0; i < VOX_COLS; i++) {
                int ytop = yt[i];
                if (ytop < ybuf[i]) {
                    uint32_t cc = vox_pal[hs[i]];
                    int r = (cc >> 16) & 255, g = (cc >> 8) & 255, b = cc & 255;
                    r += (skr - r) * fog >> 8; g += (skg - g) * fog >> 8; b += (skb - b) * fog >> 8;
                    uint32_t col = rgb(r, g, b);
                    for (int yy = ytop < 0 ? 0 : ytop; yy < ybuf[i]; yy++) cols[i][yy] = col;
                    ybuf[i] = ytop;
                }
            }
        }
        for (int i = 0; i < VOX_COLS; i++)    /* the sky above the terrain */
            for (int y = 0; y < ybuf[i]; y++) cols[i][y] = vox_sky[y];
        /* a size_t row: under -fno-strict-overflow (nixpkgs hardening) an int
           y * W must wrap, and that cost 2 ms per frame here */
        for (size_t y = 0; y < H; y++) {
            uint32_t *row = &fb[y * W + x0];
            for (int i = 0; i < VOX_COLS; i++) row[i] = cols[i][y];
        }
    }
    const char *s = "VOXEL FLYBY";
    draw_text((W - text_w(2 * US, s)) / 2, (int)(H * 0.05f), 2 * US, s, rgb(220, 235, 255));
}

static void scene_scroller(double mt) {
    /* copper bars */
    float kick = g_kick;
    float camp = H * (0.33f + 0.05f * kick);   /* swing wider on the beat (motion, not brightness) */
    float c1 = H / 2 + camp * sinf(mt * 1.3f);
    float c2 = H / 2 + camp * sinf(mt * 0.9f + 2.0f);
    float c3 = H / 2 + camp * sinf(mt * 1.7f + 4.0f);
    float bh = H * 0.13f;
    /* Copper-bar intensity is deliberately held down (~0.5 of the obvious
       values). This scene is the brightest, most-active full-screen content in
       the prod, and on badge #1's marginal HDMI link (in HDMI mode for audio)
       the near-white version reliably tripped a TMDS re-sync -- a ~2.7 s panel
       blank mid-scroller (no DISP-starved log, so a link drop, not a FIFO
       underrun). Deep copper bars both avoid that and read more classically. */
    for (int y = 0; y < H; y++) {
        float r = 8, g = 8, b = 20;
        float d1 = fabsf(y - c1), d2 = fabsf(y - c2), d3 = fabsf(y - c3);
        if (d1 < bh) { float t = (bh - d1) / bh; r += 120 * t; g += 30 * t; b += 48 * t; }
        if (d2 < bh) { float t = (bh - d2) / bh; r += 26 * t;  g += 95 * t; b += 115 * t; }
        if (d3 < bh) { float t = (bh - d3) / bh; r += 62 * t;  g += 52 * t; b += 120 * t; }
        uint32_t c = rgb((int)r, (int)g, (int)b);
        uint32_t *row = &fb[y * W];
        for (int x = 0; x < W; x++) row[x] = c;
    }
    /* sine scroller */
    static const char *msg =
        "   NIX FIXES THIS ... 720P FULL MOTION ON ONE CORTEX-A53 ... "
        "NO GPU, JUST A SOFTWARE RENDERER AND A LOT OF NIX ... "
        "GREETINGS FROM THE BENCH ... CHIPTUNE AND PIXELS FROM A 351 MEG BADGE ... "
        "REPRODUCIBLE DOWN TO THE LAST BYTE ... WRAPPING ... ";
    int scale = 4 * US, cw = 8 * scale;
    int len = (int)strlen(msg);
    float total = len * cw;
    float scroll = fmodf(mt * (W * 0.23f), total);
    int baseline = (int)(H * 0.42f);
    float amp = H * 0.16f;
    for (int k = 0; k < len; k++) {
        float cxp = k * cw - scroll;
        if (cxp < -cw || cxp > W) {
            /* also draw the wrap-around copy */
            float cxp2 = cxp + total;
            if (cxp2 < -cw || cxp2 > W) continue;
            cxp = cxp2;
        }
        int yo = (int)(sinf(cxp * 0.012f + mt * 2.2f) * amp);
        int tb = (int)(kick * 70);
        uint32_t col = pal[((int)cxp + (int)(mt * 50)) & 255];
        col = rgb(((col >> 16) & 255) + tb, ((col >> 8) & 255) + tb, (col & 255) + tb);
        draw_char((int)cxp, baseline + yo, scale, msg[k], col);
    }
    const char *s = "NIX FIXES THIS";
    draw_text((W - text_w(3 * US, s)) / 2, (int)(H * 0.04f), 3 * US, s, rgb(255, 255, 255));
}

/* ---- timeline ------------------------------------------------------------ */
#ifndef SCENE_LEN
#define SCENE_LEN 12.0
#endif
#define NSCENES 9
#define TOTAL (SCENE_LEN * NSCENES)
#define DUMP_FPS 30

/* The kick envelope the audio thread holds at song time mt: 1 on every beat
   once the first 3.5 s are past, then a 0.9993 decay per sample. Without an
   audio device, and in --dump, the visuals take their beat from here. */
static float kick_at(double mt) {
    long n = (long)(mt * SR);                     /* samples played */
    if (n <= 0) return 0.0f;
    long step = (long)((n - 1) / samp_per_step);  /* step of the last sample */
    long beat = step - step % 4;                  /* its beat's first step */
    if (beat * (samp_per_step / (double)SR) <= 3.5) return 0.0f;
    long first = (long)ceil(beat * samp_per_step);  /* the sample that kicked */
    return powf(0.99930f, (float)(n - first));
}

static int scene_at(double mt) { return (int)(fmod(mt, TOTAL) / SCENE_LEN); }

/* Draws the frame for song time mt into fb. Returns its scene-edge fade
   (0..256), which the final pass applies. */
static int render_frame(double mt, float dt) {
    double tt = fmod(mt, TOTAL);
    int scene = scene_at(mt);
    double local = tt - scene * SCENE_LEN;

    switch (scene) {
        case 0: scene_plasma_title(mt); break;
        case 1: scene_rotozoom(mt);     break;
        case 2: scene_metaballs(mt);    break;
        case 3: scene_tunnel(mt);       break;
        case 4: scene_fire(mt);         break;
        case 5: scene_torus(mt);        break;
        case 6: scene_voxel(mt, dt);    break;
        case 7: scene_nixlogo(mt, dt);  break;   /* the climax */
        default: scene_scroller(mt);    break;
    }

    /* fade in/out at scene edges */
    float fade = 1.0f;
    if (local < 0.8) fade = (float)(local / 0.8);
    else if (local > SCENE_LEN - 0.8) fade = (float)((SCENE_LEN - local) / 0.8);
    if (fade >= 0.999f) return 256;
    int fi = (int)(fade * 256.0f);
    return fi < 0 ? 0 : (fi > 256 ? 256 : fi);
}

/* ---- --dump SCENE:TIME:PATH ---------------------------------------------- */
/* Steps SCENE from its start to the frame nearest TIME seconds into it, at
   DUMP_FPS on the silent timeline, then writes that frame, fade included, to
   PATH as a binary PPM. Same build, same arguments, same bytes. */
static int dump_frame(const char *arg) {
    char *end;
    long scene = strtol(arg, &end, 10);
    if (end == arg || *end != ':' || scene < 0 || scene >= NSCENES) goto usage;
    /* TIME is digits and a point only: no sign, exponent, inf or nan, which
       -ffast-math would not catch later. */
    const char *ts = end + 1;
    size_t tlen = strspn(ts, "0123456789.");
    if (tlen == 0 || ts[tlen] != ':' || ts[tlen + 1] == '\0') goto usage;
    double t = strtod(ts, &end);
    if (end != ts + tlen) goto usage;                 /* "." or "1.2.3" */
    const char *path = end + 1;
    double nearest = t * DUMP_FPS + 0.5;              /* +0.5: round to a frame */
    if (!(nearest < SCENE_LEN * DUMP_FPS)) goto usage;  /* still in this scene */
    long last = (long)nearest;

    int fade = 256;
    for (long i = 0; i <= last; i++) {
        double mt = scene * SCENE_LEN + (double)i / DUMP_FPS;
        g_kick = kick_at(mt);
        fade = render_frame(mt, 1.0f / DUMP_FPS);
    }

    FILE *fp = fopen(path, "wb");
    if (!fp) { perror(path); return 1; }
    fprintf(fp, "P6\n%d %d\n255\n", W, H);
    static uint8_t line[W * 3];
    for (int y = 0; y < H; y++) {
        nft_pack(&fb[y * W], line, W, SDL_PIXELFORMAT_RGB24, fade);   /* PPM order */
        fwrite(line, 1, sizeof(line), fp);
    }
    int failed = ferror(fp);
    if (fclose(fp) != 0 || failed) { perror(path); return 1; }
    return 0;

usage:
    fprintf(stderr, "--dump SCENE:TIME:PATH: SCENE is 0..%d; TIME is plain decimal seconds into it,\n"
                    "0 <= TIME < %.5f (it rounds to the nearest 1/%d s frame, which must be in the scene)\n",
            NSCENES - 1, SCENE_LEN - 0.5 / DUMP_FPS, DUMP_FPS);
    return 2;
}

/* ---- --selftest ---------------------------------------------------------- */
struct pack_fmt { SDL_PixelFormat fmt; const char *name; int bpp; };
static const struct pack_fmt pack_fmts[] = {
    { SDL_PIXELFORMAT_BGR24, "BGR24", 3 },
    { SDL_PIXELFORMAT_RGB24, "RGB24", 3 },
    { SDL_PIXELFORMAT_XRGB8888, "XRGB8888", 4 },
};

/* Packs n pixels with nft_pack and checks each channel against
   (c * fade) >> 8, and that nothing past the n-th pixel was written. */
static int check_pack(const struct pack_fmt *pf, const uint32_t *src, int n, int fade) {
    static uint32_t outw[128 + 4];   /* uint32_t storage: XRGB8888 writes words */
    uint8_t *out = (uint8_t *)outw;
    if (n * pf->bpp + 16 > (int)sizeof(outw)) return 1;
    memset(outw, 0xa5, sizeof(outw));
    nft_pack(src, out, n, pf->fmt, fade);
    for (int i = 0; i < n; i++) {
        const uint8_t *o = out + i * pf->bpp;
        int r, g, b;
        if (pf->fmt == SDL_PIXELFORMAT_BGR24)      { b = o[0]; g = o[1]; r = o[2]; }
        else if (pf->fmt == SDL_PIXELFORMAT_RGB24) { r = o[0]; g = o[1]; b = o[2]; }
        else {
            uint32_t v;
            memcpy(&v, o, sizeof(v));
            r = (v >> 16) & 255; g = (v >> 8) & 255; b = v & 255;
        }
        int wr = (int)((src[i] >> 16) & 255) * fade >> 8;
        int wg = (int)((src[i] >> 8) & 255) * fade >> 8;
        int wb = (int)(src[i] & 255) * fade >> 8;
        if (r != wr || g != wg || b != wb) {
            fprintf(stderr, "selftest: %s fade %d pixel %d (0x%08x): got %02x %02x %02x, want %02x %02x %02x\n",
                    pf->name, fade, i, (unsigned)src[i], r, g, b, wr, wg, wb);
            return 1;
        }
    }
    for (int k = n * pf->bpp; k < n * pf->bpp + 16; k++)
        if (out[k] != 0xa5) {
            fprintf(stderr, "selftest: %s fade %d: %d pixels wrote byte %d\n", pf->name, fade, n, k);
            return 1;
        }
    return 0;
}

static int selftest(void) {
    static const uint32_t px = 0xff102030u;
    uint8_t o[4];
    uint32_t x;

    nft_pack(&px, o, 1, SDL_PIXELFORMAT_BGR24, 256);
    if (o[0] != 0x30 || o[1] != 0x20 || o[2] != 0x10) {
        fprintf(stderr, "selftest: BGR24 of 0xff102030 is %02x %02x %02x, want 30 20 10\n", o[0], o[1], o[2]);
        return 1;
    }
    nft_pack(&px, o, 1, SDL_PIXELFORMAT_RGB24, 256);
    if (o[0] != 0x10 || o[1] != 0x20 || o[2] != 0x30) {
        fprintf(stderr, "selftest: RGB24 of 0xff102030 is %02x %02x %02x, want 10 20 30\n", o[0], o[1], o[2]);
        return 1;
    }
    nft_pack(&px, (uint8_t *)&x, 1, SDL_PIXELFORMAT_XRGB8888, 256);
    if ((x & 0xffffff) != 0x102030) {
        fprintf(stderr, "selftest: XRGB8888 of 0xff102030 is 0x%08x, want 0x..102030\n", (unsigned)x);
        return 1;
    }

    /* A row long enough for any vector loop plus a tail, then single pixels. */
    uint32_t row[67];
    uint32_t seed = 12345;
    for (int i = 0; i < 67; i++) {
        seed = seed * 1103515245u + 12345u;
        row[i] = 0xff000000u | (seed >> 8);
    }
    row[0] = px; row[1] = 0xffffffffu; row[2] = 0xff000000u;
    static const int fades[] = { 256, 128, 255, 1, 0 };
    for (int f = 0; f < (int)SDL_arraysize(fades); f++)
        for (int k = 0; k < (int)SDL_arraysize(pack_fmts); k++) {
            if (check_pack(&pack_fmts[k], &px, 1, fades[f])) return 1;
            if (check_pack(&pack_fmts[k], row, 67, fades[f])) return 1;
        }

    /* In place, as the renderer fallback fades fb. */
    for (int f = 0; f < (int)SDL_arraysize(fades); f++) {
        uint32_t buf[67];
        memcpy(buf, row, sizeof(buf));
        nft_pack(buf, (uint8_t *)buf, 67, SDL_PIXELFORMAT_XRGB8888, fades[f]);
        for (int i = 0; i < 67; i++) {
            uint32_t want = 0;
            for (int sh = 0; sh <= 16; sh += 8)
                want |= (uint32_t)((int)((row[i] >> sh) & 255) * fades[f] >> 8) << sh;
            if ((buf[i] & 0xffffff) != want) {
                fprintf(stderr, "selftest: XRGB8888 in place, fade %d pixel %d: got 0x%08x, want 0x..%06x\n",
                        fades[f], i, (unsigned)buf[i], (unsigned)want);
                return 1;
            }
        }
    }

    /* Any other format writes nothing. */
    uint8_t none[16];
    memset(none, 0xa5, sizeof(none));
    nft_pack(row, none, 4, SDL_PIXELFORMAT_RGB565, 256);
    for (int k = 0; k < (int)sizeof(none); k++)
        if (none[k] != 0xa5) {
            fprintf(stderr, "selftest: RGB565 wrote byte %d\n", k);
            return 1;
        }
    printf("selftest: nft_pack ok\n");
    return 0;
}

/* ---- presentation ------------------------------------------------------ */
/* What present_surface did with a frame. */
enum surface_result {
    SURFACE_PRESENTED,
    SURFACE_MISSED,     /* not WxH, or the update failed: try again later */
    SURFACE_UNUSABLE,   /* no window surface, or a format nft_pack cannot write */
};

/* Packs fb with the fade into the window surface and presents it, saying why
   when it cannot. With the no-copy hint an update moves the surface's pixels
   to another buffer, so they are read again every frame. */
static enum surface_result present_surface(SDL_Window *win, int fade) {
    SDL_Surface *s = SDL_GetWindowSurface(win);
    if (!s) {
        SDL_Log("no window surface (%s)", SDL_GetError());
        return SURFACE_UNUSABLE;
    }
    if (s->w != W || s->h != H) {
        SDL_Log("window surface is %dx%d, not %dx%d", s->w, s->h, W, H);
        return SURFACE_MISSED;
    }
    if (s->format != SDL_PIXELFORMAT_BGR24 && s->format != SDL_PIXELFORMAT_RGB24 &&
            s->format != SDL_PIXELFORMAT_XRGB8888) {
        SDL_Log("window surface is %s, not 24bpp or XRGB8888", SDL_GetPixelFormatName(s->format));
        return SURFACE_UNUSABLE;
    }
    uint8_t *px = (uint8_t *)s->pixels;
    for (int y = 0; y < H; y++)
        nft_pack(&fb[y * W], px + (size_t)y * s->pitch, W, s->format, fade);
    if (!SDL_UpdateWindowSurface(win)) {
        SDL_Log("UpdateWindowSurface: %s", SDL_GetError());
        return SURFACE_MISSED;
    }
    return SURFACE_PRESENTED;
}

/* The fallback: SDL's software renderer scales fb onto the window. */
static bool start_renderer(SDL_Window *win, SDL_Renderer **ren, SDL_Texture **tex) {
    SDL_Log("presenting through the software renderer");
    SDL_DestroyWindowSurface(win);   /* a renderer cannot share it */
    *ren = SDL_CreateRenderer(win, SDL_SOFTWARE_RENDERER);
    if (!*ren) { SDL_Log("CreateRenderer: %s", SDL_GetError()); return false; }
    SDL_SetRenderLogicalPresentation(*ren, W, H, SDL_LOGICAL_PRESENTATION_LETTERBOX);
    *tex = SDL_CreateTexture(*ren, SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STREAMING, W, H);
    if (!*tex) { SDL_Log("CreateTexture: %s", SDL_GetError()); return false; }
    /* Opaque frames, nearest-pixel scaled to the window. */
    SDL_SetTextureBlendMode(*tex, SDL_BLENDMODE_NONE);
    SDL_SetTextureScaleMode(*tex, SDL_SCALEMODE_NEAREST);
    return true;
}

/* Back to the window surface: the renderer goes, and its window surface with it. */
static void stop_renderer(SDL_Renderer **ren, SDL_Texture **tex) {
    SDL_Log("window is %dx%d: presenting into the window surface again", W, H);
    if (*tex) SDL_DestroyTexture(*tex);
    SDL_DestroyRenderer(*ren);
    *ren = NULL;
    *tex = NULL;
}

/* ---- main -------------------------------------------------------------- */
static void usage(void) {
    fprintf(stderr, "usage: nix-fixes-this [--dump SCENE:TIME:PATH | --selftest]\n");
}

/* NFT_STATS=1: one line per finished scene. render is the scene; present is
   the final pass and the commit, or the renderer's fade, upload and scale.
   Both are wall time: on the badge's one core, present includes the time
   the compositor spends on the frame while the demo waits. */
struct scene_stats {
    int scene, frames;
    double render_ms, present_ms;
    uint64_t t0;            /* performance counter at the scene's first frame */
};

static void print_stats(const struct scene_stats *st, uint64_t now, double perf_freq) {
    double wall = (now - st->t0) / perf_freq;
    printf("nft-stats: %dx%d scene %d: %d frames, render %.1f ms, present %.1f ms, %.1f fps\n",
           W, H, st->scene, st->frames, st->render_ms / st->frames,
           st->present_ms / st->frames, st->frames / wall);
    fflush(stdout);
}

int main(int argc, char **argv) {
    const char *dump = NULL;
    if (argc == 2 && strcmp(argv[1], "--selftest") == 0) return selftest();
    if (argc == 3 && strcmp(argv[1], "--dump") == 0) dump = argv[2];
    else if (argc != 1) { usage(); return 2; }

    samp_per_step = SR * (60.0 / BPM) / 4.0;
    build_tables();
    logo_init();
    extra_init();
    if (dump) return dump_frame(dump);

    if (!SDL_Init(SDL_INIT_VIDEO)) {
        SDL_Log("SDL_Init video: %s", SDL_GetError());
        return 1;
    }
    /* Audio is optional: a missing backend or sink must never kill the prod. */
    bool audio_ok = SDL_InitSubSystem(SDL_INIT_AUDIO);
    if (!audio_ok) SDL_Log("no audio subsystem (%s); running silent", SDL_GetError());

#ifdef SDL_HINT_VIDEO_WAYLAND_FRAMEBUFFER_NO_COPY
    /* The badge's sdl3 (pkgs/patches/sdl3) has a wl_shm window framebuffer:
       use it rather than a GL texture framebuffer, which would be llvmpipe.
       Every frame redraws every pixel, so the window surface can be the very
       buffer the compositor gets, with no copy in between. Stock SDL has no
       Wayland window framebuffer, so there the texture framebuffer stays. */
    SDL_SetHint(SDL_HINT_FRAMEBUFFER_ACCELERATION, "0");
    SDL_SetHint(SDL_HINT_VIDEO_WAYLAND_FRAMEBUFFER_NO_COPY, "1");
#endif

    /* Fullscreen with no mode set: desktop-sized, never a mode switch. */
    SDL_Window *win = SDL_CreateWindow("Nix Fixes This", W, H, SDL_WINDOW_FULLSCREEN);
    if (!win) { SDL_Log("CreateWindow: %s", SDL_GetError()); return 1; }

    /* Made by start_renderer when the window surface does not fit. */
    SDL_Renderer *ren = NULL;
    SDL_Texture *texf = NULL;
    bool surface_usable = true;

    /* Audio is best-effort: if there is no sink, run silent but keep the clock
       ticking so the visual timeline still advances. */
    SDL_AudioStream *astream = NULL;
    if (audio_ok) {
        const SDL_AudioSpec spec = { .format = SDL_AUDIO_S16, .channels = 1, .freq = SR };
        char frames[16];
        SDL_snprintf(frames, sizeof(frames), "%d", AUDIO_FRAMES);
        SDL_SetHint(SDL_HINT_AUDIO_DEVICE_SAMPLE_FRAMES, frames);
        astream = SDL_OpenAudioDeviceStream(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, audio_cb, NULL);
    }
    uint64_t clock0 = SDL_GetPerformanceCounter();
    double perf_freq = (double)SDL_GetPerformanceFrequency();
    int have_audio = (astream != NULL);
    if (have_audio) SDL_ResumeAudioStreamDevice(astream);
    else SDL_Log("no audio device (%s); running silent", SDL_GetError());

    double prev_mt = 0.0;
    int running = 1, status = 0;
    SDL_HideCursor();

    /* present-rate cap (default 30 fps); NFT_FPS overrides for A/B tuning */
    int fps_cap = 30;
    const char *fps_env = SDL_getenv("NFT_FPS");
    if (fps_env) { int v = atoi(fps_env); if (v >= 5 && v <= 120) fps_cap = v; }
    uint64_t frame_budget_ms = (uint64_t)(1000 / fps_cap);

    const char *stats_env = SDL_getenv("NFT_STATS");
    int stats = stats_env && *stats_env && strcmp(stats_env, "0") != 0;
    /* NFT_CYCLES=n: quit after n full cycles of the scenes (0: never) */
    const char *cycles_env = SDL_getenv("NFT_CYCLES");
    int cycles = cycles_env ? atoi(cycles_env) : 0;
    struct scene_stats st = { .scene = -1 };

    while (running) {
        uint64_t frame_t0 = SDL_GetTicks();
        SDL_Event ev;
        while (SDL_PollEvent(&ev)) {
#ifndef SMOKE_NOQUIT
            if (ev.type == SDL_EVENT_QUIT) running = 0;
            if (ev.type == SDL_EVENT_KEY_DOWN && ev.key.key == SDLK_ESCAPE) running = 0;
#else
            (void)ev;
#endif
        }

        /* master clock: audio sample counter, or wall clock when silent */
        double mt;
        if (have_audio) mt = g_samples / (double)SR;
        else {
            mt = (SDL_GetPerformanceCounter() - clock0) / perf_freq;
            g_kick = kick_at(mt);
        }

        float dt = (float)(mt - prev_mt);
        if (dt < 0) dt = 0;
        if (dt > 0.1f) dt = 0.1f;
        prev_mt = mt;

        uint64_t t_frame = SDL_GetPerformanceCounter();
        int scene = scene_at(mt);
        if (scene != st.scene) {
            if (stats && st.frames) print_stats(&st, t_frame, perf_freq);
            if (cycles > 0 && mt >= cycles * TOTAL) break;
            st = (struct scene_stats){ .scene = scene, .t0 = t_frame };
        }

        int fade = render_frame(mt, dt);
        uint64_t t_drawn = SDL_GetPerformanceCounter();

        /* The window surface presents whenever the window is WxH; the renderer
           takes the frames it misses, and every frame once it is unusable. */
        if (ren && surface_usable) {
            int ww, wh;
            if (SDL_GetWindowSizeInPixels(win, &ww, &wh) && ww == W && wh == H)
                stop_renderer(&ren, &texf);
        }
        if (!ren) {
            enum surface_result r = present_surface(win, fade);
            if (r == SURFACE_UNUSABLE) surface_usable = false;
            if (r != SURFACE_PRESENTED && !start_renderer(win, &ren, &texf)) {
                status = 1;
                break;
            }
        }
        if (ren) {
            if (fade < 256) nft_pack(fb, (uint8_t *)fb, W * H, SDL_PIXELFORMAT_XRGB8888, fade);
            SDL_UpdateTexture(texf, NULL, fb, W * sizeof(uint32_t));
            SDL_RenderClear(ren);
            SDL_RenderTexture(ren, texf, NULL, NULL);
            SDL_RenderPresent(ren);
        }
        uint64_t t_shown = SDL_GetPerformanceCounter();

        st.frames++;
        st.render_ms += (t_drawn - t_frame) * 1000.0 / perf_freq;
        st.present_ms += (t_shown - t_drawn) * 1000.0 / perf_freq;

        /* Cap the present rate (~30 fps). The DISP scans the compositor's
           buffer straight from DDR and every present's buffer writes compete
           with that scanout, so an uncapped present rate can underrun the
           DISP FIFO (the reason Quake caps its fps on this board).
           30 fps is smooth and stays well under that ceiling. Animation is
           driven by the audio/wall clock, so a skipped present never changes
           motion speed. Overridable via NFT_FPS for A/B testing. */
        uint64_t frame_ms = SDL_GetTicks() - frame_t0;
        if (frame_ms < frame_budget_ms) SDL_Delay((Uint32)(frame_budget_ms - frame_ms));
    }

    if (have_audio) SDL_DestroyAudioStream(astream);
    if (texf) SDL_DestroyTexture(texf);
    if (ren) SDL_DestroyRenderer(ren);
    SDL_DestroyWindow(win);
    SDL_Quit();
    return status;
}
