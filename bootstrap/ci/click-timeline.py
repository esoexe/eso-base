#!/usr/bin/env python3
"""Every 2 s from T0 to T1 after power-on: drag the ESO Setup title bar by 60 px and back, report whether the
window moved (QMP screendump comparison). Shows if/when clicks are ignored after the desktop appears."""
import json, os, socket, sys, time
SOCK, OUT, T0, T1 = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
W, H = 1920, 1080
os.makedirs(OUT, exist_ok=True)


class QMP:
    def __init__(s, path):
        for _ in range(100):
            try:
                s.s = socket.socket(socket.AF_UNIX); s.s.connect(path); break
            except OSError:
                time.sleep(0.2)
        s.f = s.s.makefile("rw"); s.f.readline(); s.cmd("qmp_capabilities")

    def cmd(s, c, **a):
        s.f.write(json.dumps({"execute": c, "arguments": a}) + "\n"); s.f.flush()
        while True:
            r = json.loads(s.f.readline())
            if "return" in r or "error" in r:
                return r


q = QMP(SOCK); start = time.monotonic()
def ev(*e): q.cmd("input-send-event", events=list(e))
def move(x, y): ev({"type": "abs", "data": {"axis": "x", "value": int(x * 32767 / (W - 1))}},
                   {"type": "abs", "data": {"axis": "y", "value": int(y * 32767 / (H - 1))}})
def btn(d): ev({"type": "btn", "data": {"down": d, "button": "left"}})
def dump(n):
    p = os.path.abspath(f"{OUT}/.{n}.ppm"); q.cmd("screendump", filename=p); b = open(p, "rb").read(); os.remove(p)
    return b[-W * H * 3:]
def diff(a, b):
    n = d = 0
    for y in range(40, H - 60, 24):
        for x in range(0, W, 24):
            o = (y * W + x) * 3; n += 1
            d += abs(a[o] - b[o]) + abs(a[o + 1] - b[o + 1]) + abs(a[o + 2] - b[o + 2]) > 30
    return d / n
def path(x0, y0, x1, y1, n=8):
    for i in range(1, n + 1):
        move(x0 + (x1 - x0) * i / n, y0 + (y1 - y0) * i / n); time.sleep(0.03)

G = (900, 231)
while time.monotonic() - start < T0:
    time.sleep(0.2)
while time.monotonic() - start < T1:
    t = time.monotonic() - start
    a = dump("a"); move(*G); time.sleep(0.15); btn(True); time.sleep(0.1)
    path(G[0], G[1], G[0] + 60, G[1] + 40); time.sleep(0.1)
    b = dump("b")
    path(G[0] + 60, G[1] + 40, G[0], G[1]); time.sleep(0.05); btn(False); time.sleep(0.1)
    c = diff(a, b)
    print(f"[{t:5.1f}s] title-bar drag {'MOVED' if c > 0.01 else 'ignored'} ({c:.1%})", flush=True)
    if c <= 0.01:
        q.cmd("screendump", filename=os.path.abspath(f"{OUT}/ignored-{int(t)}.ppm"))
    while time.monotonic() - start < t + 2:
        time.sleep(0.05)
