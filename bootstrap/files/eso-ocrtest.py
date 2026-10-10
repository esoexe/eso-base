#!/usr/bin/env python3
"""eso-ocrtest.py: real text recognition test. Draws known words (Pango/cairo, as on a screen), saves PNG and PNM,
runs tesseract on both the way ESO's Snip editor and Amenokal do, prints what came back. exit 0 = words read."""
import os, subprocess, sys, tempfile
import gi
gi.require_version("Pango", "1.0"); gi.require_version("PangoCairo", "1.0")
from gi.repository import Pango, PangoCairo
import cairo

WORDS = "ESO OCR test 2026 Hello World"
d = tempfile.mkdtemp()
s = cairo.ImageSurface(cairo.FORMAT_RGB24, 1400, 220)
cr = cairo.Context(s)
cr.set_source_rgb(1, 1, 1); cr.paint(); cr.set_source_rgb(0.05, 0.05, 0.08)
lay = PangoCairo.create_layout(cr); lay.set_font_description(Pango.FontDescription("Sans 44")); lay.set_text(WORDS, -1)
cr.move_to(40, 60); PangoCairo.show_layout(cr, lay)
png = os.path.join(d, "t.png"); s.write_to_png(png)
# PNM (P6): leptonica reads it without any image library
w, h, st = s.get_width(), s.get_height(), s.get_stride(); buf = bytes(s.get_data())
out = bytearray(w * h * 3)
for y in range(h):
    row = buf[y * st:y * st + w * 4]          # BGRx little endian
    o = y * w * 3
    out[o:o + w * 3:3] = row[2::4]; out[o + 1:o + w * 3:3] = row[1::4]; out[o + 2:o + w * 3:3] = row[0::4]
pnm = os.path.join(d, "t.ppm"); open(pnm, "wb").write(b"P6\n%d %d\n255\n" % (w, h) + bytes(out))
ok = True
langs = subprocess.run(["tesseract", "--list-langs"], capture_output=True, text=True).stdout.split()[1:]
print("languages:", " ".join(langs))
for f in (png, pnm):
    for l in ("eng", "+".join(x for x in ("eng", "fra", "ara") if x in langs)):
        r = subprocess.run(["tesseract", f, "-", "-l", l, "--psm", "3"], capture_output=True, text=True, timeout=120)
        txt = " ".join(r.stdout.split())
        good = "Hello" in txt and "World" in txt
        ok &= good
        print(f"{os.path.basename(f)} -l {l}: rc={r.returncode} {'OK' if good else 'FAILED'} text={txt!r}")
        if not good:
            print("  stderr:", " | ".join(r.stderr.strip().splitlines()[-6:]))
sys.exit(0 if ok else 1)
