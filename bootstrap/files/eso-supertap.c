/*
 * eso-supertap - a key that is tapped on its own sends other keys (ESO: a lone tap of the Windows key opens Start).
 * Holding the key and pressing anything else (Super+E, Super+click ...) keeps its normal meaning.
 *
 *   eso-supertap [-t MS] [-e 'Super_L=Control_L|Escape;Super_R=Control_L|Escape'] [-d]
 *
 * Same command line as the classic xcape tool, so ESO sessions can call either.  X11 only: it watches key events
 * with the RECORD extension (no keyboard grab, no lag) and sends the replacement keys with XTEST.
 * Build: cc -O2 -o eso-supertap eso-supertap.c -lX11 -lXtst
 * Part of ESO Base (github.com/esoexe/eso-base). MIT licence.
 */
#include <X11/Xlib.h>
#include <X11/XKBlib.h>
#include <X11/Xproto.h>
#include <X11/extensions/record.h>
#include <X11/extensions/XTest.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

#define MAXMAP 16
#define MAXTO 8

typedef struct {
    KeyCode from;
    KeyCode to[MAXTO];
    int nto;
    int down;            /* the key is held */
    int used;            /* something else was pressed while it was held */
    struct timeval t;    /* when it went down */
} Map;

static Map maps[MAXMAP];
static int nmaps;
static long timeout_ms = 500;
static int debug;
static Display *ctrl;    /* sends the replacement keys */
static Display *data;    /* receives the recorded events */
static XRecordContext ctx;
static volatile sig_atomic_t stop;

static long ms_since(const struct timeval *a) {
    struct timeval now;
    gettimeofday(&now, NULL);
    return (now.tv_sec - a->tv_sec) * 1000L + (now.tv_usec - a->tv_usec) / 1000L;
}

static KeyCode code_of(const char *name) {
    KeySym ks = XStringToKeysym(name);
    if (ks == NoSymbol) { fprintf(stderr, "eso-supertap: unknown key '%s'\n", name); exit(2); }
    KeyCode kc = XKeysymToKeycode(ctrl, ks);
    if (!kc) { fprintf(stderr, "eso-supertap: key '%s' is not on this keyboard\n", name); exit(2); }
    return kc;
}

/* 'A=B|C;D=E' */
static void parse(char *spec) {
    for (char *rule = strtok(spec, ";"); rule; rule = strtok(NULL, ";")) {
        char *eq = strchr(rule, '=');
        if (!eq || nmaps >= MAXMAP) { fprintf(stderr, "eso-supertap: bad mapping '%s'\n", rule); exit(2); }
        *eq = 0;
        Map *m = &maps[nmaps];
        memset(m, 0, sizeof *m);
        m->from = code_of(rule);
        char *save = NULL;
        for (char *k = strtok_r(eq + 1, "|", &save); k && m->nto < MAXTO; k = strtok_r(NULL, "|", &save))
            m->to[m->nto++] = code_of(k);
        if (!m->nto) { fprintf(stderr, "eso-supertap: '%s' maps to nothing\n", rule); exit(2); }
        nmaps++;
    }
}

static void send_keys(const Map *m) {
    for (int i = 0; i < m->nto; i++) XTestFakeKeyEvent(ctrl, m->to[i], True, CurrentTime);
    for (int i = m->nto - 1; i >= 0; i--) XTestFakeKeyEvent(ctrl, m->to[i], False, CurrentTime);
    XFlush(ctrl);
}

static int is_target(KeyCode kc) {   /* keys we generate ourselves must not count as "something else pressed" */
    for (int i = 0; i < nmaps; i++)
        for (int j = 0; j < maps[i].nto; j++)
            if (maps[i].to[j] == kc) return 1;
    return 0;
}

static int sending;

static void on_event(XPointer priv, XRecordInterceptData *d) {
    (void)priv;
    if (d->category != XRecordFromServer || !d->data) { XRecordFreeData(d); return; }
    const xEvent *ev = (const xEvent *)d->data;
    int type = ev->u.u.type & 0x7f;
    KeyCode kc = ev->u.u.detail;
    if (type == KeyPress) {
        int mapped = 0;
        for (int i = 0; i < nmaps; i++) {
            if (maps[i].from == kc) {
                if (!maps[i].down) { maps[i].down = 1; maps[i].used = 0; gettimeofday(&maps[i].t, NULL); }
                mapped = 1;
            }
        }
        if (!mapped && !(sending && is_target(kc)))
            for (int i = 0; i < nmaps; i++) if (maps[i].down) maps[i].used = 1;
    } else if (type == ButtonPress) {
        for (int i = 0; i < nmaps; i++) if (maps[i].down) maps[i].used = 1;
    } else if (type == KeyRelease) {
        for (int i = 0; i < nmaps; i++) {
            if (maps[i].from != kc || !maps[i].down) continue;
            maps[i].down = 0;
            long held = ms_since(&maps[i].t);
            if (debug) fprintf(stderr, "eso-supertap: key %d released after %ld ms, %s\n", kc, held,
                               maps[i].used ? "used with another key" : "alone");
            if (!maps[i].used && held <= timeout_ms) { sending = 1; send_keys(&maps[i]); sending = 0; }
        }
    }
    XRecordFreeData(d);
}

static void on_signal(int s) { (void)s; stop = 1; }

int main(int argc, char **argv) {
    char *spec = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-t") && i + 1 < argc) timeout_ms = atol(argv[++i]);
        else if (!strcmp(argv[i], "-e") && i + 1 < argc) spec = strdup(argv[++i]);
        else if (!strcmp(argv[i], "-d")) debug = 1;
        else { fprintf(stderr, "usage: eso-supertap [-t MS] [-e 'Super_L=Control_L|Escape'] [-d]\n"); return 2; }
    }
    if (!spec) spec = strdup("Super_L=Control_L|Escape;Super_R=Control_L|Escape");
    if (!(ctrl = XOpenDisplay(NULL)) || !(data = XOpenDisplay(NULL))) { fprintf(stderr, "eso-supertap: no X display\n"); return 1; }
    int a, b, c, d;
    if (!XRecordQueryVersion(ctrl, &a, &b) || !XTestQueryExtension(ctrl, &a, &b, &c, &d)) {
        fprintf(stderr, "eso-supertap: the X server lacks RECORD or XTEST\n"); return 1;
    }
    parse(spec);
    XSynchronize(ctrl, True);
    XRecordClientSpec all = XRecordAllClients;
    XRecordRange *range = XRecordAllocRange();
    range->device_events.first = KeyPress;
    range->device_events.last = ButtonRelease;
    ctx = XRecordCreateContext(ctrl, 0, &all, 1, &range, 1);
    XFree(range);
    if (!ctx) { fprintf(stderr, "eso-supertap: could not watch the keyboard\n"); return 1; }
    signal(SIGINT, on_signal); signal(SIGTERM, on_signal);
    if (debug) fprintf(stderr, "eso-supertap: %d mapping(s), timeout %ld ms\n", nmaps, timeout_ms);
    /* asynchronous: poll the data connection so a signal can end the loop cleanly */
    if (!XRecordEnableContextAsync(data, ctx, on_event, NULL)) { fprintf(stderr, "eso-supertap: RECORD failed\n"); return 1; }
    while (!stop) {
        XRecordProcessReplies(data);
        if (XPending(data)) continue;    /* Xlib already holds more data */
        struct timeval tv = {5, 0};      /* sleeps until a key event arrives (5 s safety wake-up, ~0% CPU) */
        fd_set fds; FD_ZERO(&fds); FD_SET(ConnectionNumber(data), &fds);
        select(ConnectionNumber(data) + 1, &fds, NULL, NULL, &tv);
    }
    XRecordDisableContext(ctrl, ctx);
    XRecordFreeContext(ctrl, ctx);
    XCloseDisplay(data); XCloseDisplay(ctrl);
    return 0;
}
