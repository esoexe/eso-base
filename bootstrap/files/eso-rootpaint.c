/* eso-rootpaint: paint a JPEG on the X root window, fast (a few ms at 1080p).
 *
 *   eso-rootpaint [--zoom] FILE.jpg        cover the whole screen (crop, keep aspect)
 *   eso-rootpaint --test OUT.ppm W H FILE  write the scaled picture instead (self-test, no X)
 *
 * ESO Base has no feh / xwallpaper; without this the X root stays black until eso-shell
 * (Python + GTK) draws the desktop, about 3 s of black screen after the boot animation.
 * Also installed as "xwallpaper" so eso-wallpaper's existing "xwallpaper --zoom FILE" path uses it.
 * Sets _XROOTPMAP_ID / ESETROOT_PMAP_ID and keeps the pixmap after exit (RetainPermanent).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <setjmp.h>
#include <jpeglib.h>
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/Xutil.h>

struct jerr { struct jpeg_error_mgr pub; jmp_buf jb; };
static void on_err(j_common_ptr c) { longjmp(((struct jerr *)c->err)->jb, 1); }

/* decode, letting libjpeg shrink by 1/2, 1/4, 1/8 while the result still covers WxH */
static unsigned char *load(const char *path, int W, int H, int *w, int *h)
{
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    struct jpeg_decompress_struct d; struct jerr e;
    unsigned char *px = NULL;
    d.err = jpeg_std_error(&e.pub); e.pub.error_exit = on_err;
    if (setjmp(e.jb)) { jpeg_destroy_decompress(&d); fclose(f); free(px); return NULL; }
    jpeg_create_decompress(&d);
    jpeg_stdio_src(&d, f);
    jpeg_read_header(&d, TRUE);
    d.out_color_space = JCS_RGB;
    d.scale_num = 1; d.scale_denom = 1;
    for (int s = 8; s > 1; s /= 2)
        if ((int)d.image_width / s >= W && (int)d.image_height / s >= H) { d.scale_denom = s; break; }
    d.dct_method = JDCT_IFAST;
    jpeg_start_decompress(&d);
    *w = d.output_width; *h = d.output_height;
    px = malloc((size_t)*w * *h * 3);
    if (!px) longjmp(e.jb, 1);
    while (d.output_scanline < d.output_height) {
        JSAMPROW row = px + (size_t)d.output_scanline * *w * 3;
        jpeg_read_scanlines(&d, &row, 1);
    }
    jpeg_finish_decompress(&d); jpeg_destroy_decompress(&d); fclose(f);
    return px;
}

/* cover-scale (bilinear) into 0x00RRGGBB pixels */
static unsigned int *cover(const unsigned char *s, int sw, int sh, int W, int H)
{
    unsigned int *o = malloc((size_t)W * H * 4);
    if (!o) return NULL;
    double k = (double)W / sw > (double)H / sh ? (double)W / sw : (double)H / sh;
    double ox = (sw * k - W) / 2, oy = (sh * k - H) / 2;
    for (int y = 0; y < H; y++) {
        double fy = (y + oy + 0.5) / k - 0.5; if (fy < 0) fy = 0;
        int y0 = (int)fy, y1 = y0 + 1 < sh ? y0 + 1 : sh - 1; if (y0 >= sh) y0 = y1 = sh - 1;
        int wy = (int)((fy - y0) * 256);
        for (int x = 0; x < W; x++) {
            double fx = (x + ox + 0.5) / k - 0.5; if (fx < 0) fx = 0;
            int x0 = (int)fx, x1 = x0 + 1 < sw ? x0 + 1 : sw - 1; if (x0 >= sw) x0 = x1 = sw - 1;
            int wx = (int)((fx - x0) * 256);
            const unsigned char *a = s + ((size_t)y0 * sw + x0) * 3, *b = s + ((size_t)y0 * sw + x1) * 3,
                                *c = s + ((size_t)y1 * sw + x0) * 3, *d = s + ((size_t)y1 * sw + x1) * 3;
            unsigned int p = 0;
            for (int i = 0; i < 3; i++) {
                int t = (a[i] * (256 - wx) + b[i] * wx) >> 8, u = (c[i] * (256 - wx) + d[i] * wx) >> 8;
                p = (p << 8) | (unsigned)((t * (256 - wy) + u * wy) >> 8);
            }
            o[(size_t)y * W + x] = p;
        }
    }
    return o;
}

int main(int argc, char **argv)
{
    const char *file = NULL, *test = NULL; int TW = 0, TH = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--test") && i + 3 < argc) { test = argv[++i]; TW = atoi(argv[++i]); TH = atoi(argv[++i]); }
        else if (argv[i][0] == '-' && argv[i][1] == '-') continue;   /* --zoom and friends: cover is the only mode */
        else file = argv[i];
    }
    if (!file) { fprintf(stderr, "usage: eso-rootpaint [--zoom] FILE.jpg\n"); return 2; }

    if (test) {
        int w, h; unsigned char *s = load(file, TW, TH, &w, &h);
        if (!s) { fprintf(stderr, "eso-rootpaint: cannot read %s\n", file); return 1; }
        unsigned int *o = cover(s, w, h, TW, TH);
        FILE *f = fopen(test, "wb"); if (!f || !o) return 1;
        fprintf(f, "P6\n%d %d\n255\n", TW, TH);
        for (size_t i = 0; i < (size_t)TW * TH; i++) { unsigned char c[3] = { o[i] >> 16, o[i] >> 8, o[i] }; fwrite(c, 1, 3, f); }
        fclose(f); printf("decoded %dx%d -> %dx%d\n", w, h, TW, TH); return 0;
    }

    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) { fprintf(stderr, "eso-rootpaint: no X display\n"); return 1; }
    int scr = DefaultScreen(dpy); Window root = RootWindow(dpy, scr);
    int W = DisplayWidth(dpy, scr), H = DisplayHeight(dpy, scr), depth = DefaultDepth(dpy, scr);
    Visual *vis = DefaultVisual(dpy, scr);
    if ((depth != 24 && depth != 32) || vis->class != TrueColor) { fprintf(stderr, "eso-rootpaint: needs a 24-bit screen\n"); return 1; }
    int w, h; unsigned char *s = load(file, W, H, &w, &h);
    if (!s) { fprintf(stderr, "eso-rootpaint: cannot read %s\n", file); return 1; }
    unsigned int *o = cover(s, w, h, W, H); free(s);
    if (!o) return 1;

    /* a second connection whose resources outlive us: the root background pixmap stays valid */
    Display *keep = XOpenDisplay(NULL);
    if (!keep) return 1;
    XSetCloseDownMode(keep, RetainPermanent);
    Pixmap pm = XCreatePixmap(keep, root, W, H, depth);
    GC gc = XCreateGC(keep, pm, 0, NULL);
    XImage *img = XCreateImage(keep, vis, depth, ZPixmap, 0, (char *)o, W, H, 32, 0);
    XPutImage(keep, pm, gc, img, 0, 0, 0, 0, W, H);
    XDestroyImage(img); XFreeGC(keep, gc);

    /* free the pixmap a previous run left behind (same convention as feh / hsetroot) */
    Atom ae = XInternAtom(keep, "ESETROOT_PMAP_ID", False), ar = XInternAtom(keep, "_XROOTPMAP_ID", False);
    Atom type; int fmt; unsigned long n, after; unsigned char *data = NULL;
    if (XGetWindowProperty(keep, root, ae, 0, 1, False, XA_PIXMAP, &type, &fmt, &n, &after, &data) == Success && data) {
        if (type == XA_PIXMAP && n == 1) XKillClient(keep, *(Pixmap *)data);
        XFree(data);
    }
    XChangeProperty(keep, root, ar, XA_PIXMAP, 32, PropModeReplace, (unsigned char *)&pm, 1);
    XChangeProperty(keep, root, ae, XA_PIXMAP, 32, PropModeReplace, (unsigned char *)&pm, 1);
    XSetWindowBackgroundPixmap(keep, root, pm);
    XClearWindow(keep, root);
    XFlush(keep); XSync(keep, False);
    XCloseDisplay(keep); XCloseDisplay(dpy);
    return 0;
}
