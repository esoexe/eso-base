#!/usr/bin/env python3
"""Patch QEMU 8.2.x ui/console.c into the ESO demo recorder.

Two things stock QEMU does that make a recording of a smooth guest look uneven:
  1. the display refresh timer is re-armed AFTER each refresh finishes (last_update = now; timer = now + interval),
     so every refresh's own cost is added to the period and frames come at 16..50 ms, never on a steady beat;
  2. the picture then has to be grabbed a second time from the host screen by a recorder with its own clock.

With ESO_REFRESH_HZ=N the refresh runs on fixed deadlines (next += 1/N s; a late tick never shifts the beat).
With ESO_FRAME_FIFO=path (and ESO_FRAME_SIZE=WxH) every refresh writes the guest's framebuffer, exactly as it is at
that tick, as one raw BGRX frame into the fifo (ffmpeg -f rawvideo -framerate N reads it): one video frame per guest
display refresh, no second capture. A writer thread with an 8-frame ring keeps the main loop from ever blocking.
Statistics (tick lateness, refresh cost, ring drops) go to stderr every 2 s.
usage: qemu-eso-recorder.py path/to/ui/console.c
"""
import sys

p = sys.argv[1]
s = open(p).read()

HELPERS = r'''
/* ---- ESO demo recorder (see bootstrap/ci/qemu-eso-recorder.py) ---- */
#include <pthread.h>
static int64_t eso_step_ns, eso_next_ns, eso_stat_t0;
static uint64_t eso_ticks, eso_late, eso_missed, eso_cost_sum, eso_cost_max, eso_late_max;
static const char *eso_fifo;
static int eso_w, eso_h;
#define ESO_RING 8
static uint8_t *eso_ring[ESO_RING];
static unsigned eso_head, eso_tail;            /* head: next to fill (main), tail: next to write (writer) */
static uint64_t eso_frames, eso_drops;
static pthread_mutex_t eso_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t eso_cv = PTHREAD_COND_INITIALIZER;

static void *eso_writer(void *arg)
{
    int fd = open(eso_fifo, O_WRONLY);          /* blocks until ffmpeg opens it - in this thread only */
    size_t n = (size_t)eso_w * eso_h * 4;
    if (fd < 0) {
        fprintf(stderr, "eso-recorder: cannot open %s\n", eso_fifo);
        return NULL;
    }
    for (;;) {
        pthread_mutex_lock(&eso_mu);
        while (eso_tail == eso_head) {
            pthread_cond_wait(&eso_cv, &eso_mu);
        }
        uint8_t *b = eso_ring[eso_tail % ESO_RING];
        pthread_mutex_unlock(&eso_mu);
        size_t off = 0;
        while (off < n) {
            ssize_t r = write(fd, b + off, n - off);
            if (r <= 0) {
                if (r < 0 && errno == EINTR) {
                    continue;
                }
                fprintf(stderr, "eso-recorder: fifo closed\n");
                close(fd);
                return NULL;
            }
            off += r;
        }
        pthread_mutex_lock(&eso_mu);
        eso_tail++;
        pthread_mutex_unlock(&eso_mu);
    }
    return NULL;
}

static void eso_setup(void)
{
    static int done;
    if (done) {
        return;
    }
    done = 1;
    const char *hz = getenv("ESO_REFRESH_HZ");
    if (hz && atof(hz) > 1) {
        eso_step_ns = (int64_t)(1e9 / atof(hz) + 0.5);
        fprintf(stderr, "eso-recorder: fixed-rate refresh %.3f Hz\n", 1e9 / eso_step_ns);
    }
    eso_fifo = getenv("ESO_FRAME_FIFO");
    if (eso_fifo && *eso_fifo) {
        const char *sz = getenv("ESO_FRAME_SIZE");
        if (!sz || sscanf(sz, "%dx%d", &eso_w, &eso_h) != 2 || eso_w <= 0 || eso_h <= 0) {
            eso_w = 1920; eso_h = 1080;
        }
        for (int i = 0; i < ESO_RING; i++) {
            eso_ring[i] = g_malloc0((size_t)eso_w * eso_h * 4);
        }
        pthread_t t;
        pthread_create(&t, NULL, eso_writer, NULL);
        pthread_detach(t);
        fprintf(stderr, "eso-recorder: frames %dx%d -> %s\n", eso_w, eso_h, eso_fifo);
    } else {
        eso_fifo = NULL;
    }
}

static void eso_tap(void)
{
    QemuConsole *con = qemu_console_lookup_by_index(0);
    DisplaySurface *srf = con ? qemu_console_surface(con) : NULL;
    unsigned used;
    pthread_mutex_lock(&eso_mu);
    used = eso_head - eso_tail;
    pthread_mutex_unlock(&eso_mu);
    if (used >= ESO_RING - 1) {
        eso_drops++;
        return;
    }
    uint8_t *dst = eso_ring[eso_head % ESO_RING];
    size_t stride = (size_t)eso_w * 4;
    memset(dst, 0, stride * eso_h);
    if (srf && surface_bits_per_pixel(srf) == 32) {
        int sw = surface_width(srf), sh = surface_height(srf), ss = surface_stride(srf);
        int cw = sw < eso_w ? sw : eso_w, ch = sh < eso_h ? sh : eso_h;
        int ox = (eso_w - cw) / 2, oy = (eso_h - ch) / 2;   /* smaller modes (boot text) centred, like the GTK view */
        const uint8_t *src = surface_data(srf);
        for (int y = 0; y < ch; y++) {
            memcpy(dst + (size_t)(oy + y) * stride + (size_t)ox * 4, src + (size_t)y * ss, (size_t)cw * 4);
        }
    }
    pthread_mutex_lock(&eso_mu);
    eso_head++;
    eso_frames++;
    pthread_cond_signal(&eso_cv);
    pthread_mutex_unlock(&eso_mu);
}
/* ---- end ESO demo recorder ---- */

static void gui_update(void *opaque)
{'''

old_head = "static void gui_update(void *opaque)\n{"
assert s.count(old_head) == 1, "gui_update not found"
s = s.replace(old_head, HELPERS.lstrip("\n"), 1)

old_ref = """    ds->refreshing = true;
    dpy_refresh(ds);
    ds->refreshing = false;
"""
new_ref = """    int64_t eso_t_start = qemu_clock_get_ns(QEMU_CLOCK_REALTIME);
    ds->refreshing = true;
    dpy_refresh(ds);
    if (eso_fifo) {
        QemuConsole *eso_con = qemu_console_lookup_by_index(0);
        if (eso_con) {
            graphic_hw_update(eso_con);      /* the guest picture at this very tick, whatever the UI backend does */
        }
        eso_tap();
    }
    ds->refreshing = false;
"""
assert s.count(old_ref) == 1, "refresh block not found"
s = s.replace(old_ref, new_ref, 1)

old_arm = """    ds->last_update = qemu_clock_get_ms(QEMU_CLOCK_REALTIME);
    timer_mod(ds->gui_timer, ds->last_update + interval);
}"""
new_arm = """    ds->last_update = qemu_clock_get_ms(QEMU_CLOCK_REALTIME);
    if (eso_step_ns) {
        int64_t now = qemu_clock_get_ns(QEMU_CLOCK_REALTIME);
        int64_t cost = now - eso_t_start;
        int64_t late = eso_next_ns ? eso_t_start - eso_next_ns : 0;
        if (!eso_next_ns) {
            eso_next_ns = eso_t_start;
            eso_stat_t0 = now;
        }
        eso_ticks++;
        eso_cost_sum += cost;
        if ((uint64_t)cost > eso_cost_max) {
            eso_cost_max = cost;
        }
        if (late > 4000000) {
            eso_late++;
        }
        if (late > 0 && (uint64_t)late > eso_late_max) {
            eso_late_max = late;
        }
        eso_next_ns += eso_step_ns;                       /* fixed beat: never re-based on the refresh's end */
        while (eso_next_ns <= now) {                     /* fell a whole frame behind: skip it, keep the phase */
            eso_next_ns += eso_step_ns;
            eso_missed++;
        }
        timer_mod_ns(ds->gui_timer, eso_next_ns);
        if (now - eso_stat_t0 >= 2000000000LL) {
            fprintf(stderr, "eso-recorder: %.1f ticks/s, refresh avg %.2f ms max %.2f ms, late>4ms %" PRIu64
                    ", worst late %.2f ms, missed %" PRIu64 ", frames %" PRIu64 ", ring drops %" PRIu64 "\\n",
                    eso_ticks * 1e9 / (now - eso_stat_t0), eso_ticks ? eso_cost_sum / 1e6 / eso_ticks : 0.0,
                    eso_cost_max / 1e6, eso_late, eso_late_max / 1e6, eso_missed, eso_frames, eso_drops);
            eso_stat_t0 = now;
            eso_ticks = eso_late = eso_missed = eso_cost_sum = eso_cost_max = eso_late_max = 0;
        }
        return;
    }
    timer_mod(ds->gui_timer, ds->last_update + interval);
}"""
assert s.count(old_arm) == 1, "timer re-arm not found"
s = s.replace(old_arm, new_arm, 1)

old_setup = """        ds->gui_timer = timer_new_ms(QEMU_CLOCK_REALTIME, gui_update, ds);"""
new_setup = """        eso_setup();
        ds->gui_timer = timer_new_ms(QEMU_CLOCK_REALTIME, gui_update, ds);"""
assert s.count(old_setup) == 1
s = s.replace(old_setup, new_setup, 1)

old_upd = """    if (!ds->refreshing && ds->update_interval > interval) {"""
new_upd = """    if (!eso_step_ns && !ds->refreshing && ds->update_interval > interval) {"""
assert s.count(old_upd) == 1
s = s.replace(old_upd, new_upd, 1)

open(p, "w").write(s)
print("patched", p)
