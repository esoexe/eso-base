#!/usr/bin/env python3
"""Same test for any ESO OS version (used to compare 3.7.4 with the newest build in the same VM):
  1. how long Files, Settings and the terminal take to appear (key press -> first change -> screen settled)
  2. a FAST window move over other windows (xfwm4 keyboard move, Alt+F7, so no title-bar position is needed)
     while a second QMP connection takes framebuffer snapshots as fast as it can (tearing / trails check)
Usage: compare-drive.py QMP1 QMP2 OUTDIR BOOT_WAIT"""
import json, math, os, socket, sys, threading, time

SOCK1, SOCK2, OUT, BOOT = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
W, H = 1920, 1080
os.makedirs(OUT, exist_ok=True)
T0 = time.monotonic()


def log(m):
    print(f"[{time.monotonic() - T0:6.1f}s] {m}", flush=True)


class QMP:
    def __init__(s, path):
        for _ in range(200):
            try:
                s.s = socket.socket(socket.AF_UNIX); s.s.connect(path); break
            except OSError:
                time.sleep(0.2)
        s.f = s.s.makefile("rw"); s.f.readline(); s.cmd("qmp_capabilities")
        s.lock = threading.Lock()

    def cmd(s, c, **a):
        s.f.write(json.dumps({"execute": c, "arguments": a}) + "\n"); s.f.flush()
        while True:
            r = json.loads(s.f.readline())
            if "return" in r or "error" in r:
                return r


q, q2 = QMP(SOCK1), QMP(SOCK2)
cur = [W // 2, H // 2]


def ev(*e):
    q.cmd("input-send-event", events=list(e))


def absxy(x, y):
    x = min(max(x, 0), W - 1); y = min(max(y, 0), H - 1)
    return [{"type": "abs", "data": {"axis": "x", "value": int(x * 32767 / (W - 1))}},
            {"type": "abs", "data": {"axis": "y", "value": int(y * 32767 / (H - 1))}}]


def key(*names, hold=0.06):
    ks = [{"type": "qcode", "data": n} for n in names]
    ev(*[{"type": "key", "data": {"down": True, "key": k}} for k in ks]); time.sleep(hold)
    ev(*[{"type": "key", "data": {"down": False, "key": k}} for k in reversed(ks)]); time.sleep(0.05)


def type_text(s):
    names = {" ": "spc", "\n": "ret", "-": "minus", "/": "slash", ".": "dot", ";": "semicolon"}
    for ch in s:
        key(names.get(ch, ch)); time.sleep(0.04)


def dump(name="cur"):
    p = os.path.abspath(f"{OUT}/.{name}.ppm")
    q2.cmd("screendump", filename=p)
    b = open(p, "rb").read(); os.remove(p)
    return b[-W * H * 3:]


def diff(a, b):
    n = d = 0
    for y in range(40, H - 60, 20):
        for x in range(0, W, 20):
            o = (y * W + x) * 3; n += 1
            d += abs(a[o] - b[o]) + abs(a[o + 1] - b[o + 1]) + abs(a[o + 2] - b[o + 2]) > 30
    return d / n


def open_latency(name, *keys):
    base = dump()
    key(*keys); t = time.monotonic()
    first = settled = None; prev = base
    while time.monotonic() - t < 15:
        d = dump()
        now = time.monotonic() - t
        if first is None and diff(base, d) > 0.015:
            first = now
        elif first is not None and diff(prev, d) < 0.002:
            settled = now; break
        prev = d
    log(f"OPEN {name}: first change {first if first is None else round(first * 1000)} ms, "
        f"settled {settled if settled is None else round(settled * 1000)} ms")
    return first, settled


burst = {"on": False, "n": 0, "tag": "", "t": [], "h": []}


def burster():
    import hashlib
    i = 0; burst["t"] = []; burst["h"] = []
    while burst["on"]:
        p = os.path.abspath(f"{OUT}/burst-{burst['tag']}-{i:03d}.ppm")
        q2.cmd("screendump", filename=p); burst["t"].append(time.monotonic())
        with open(p, "rb") as f: burst["h"].append(hashlib.md5(f.read()).hexdigest())
        i += 1
    burst["n"] = i


def fast_move(tag):
    """FAST move of the focused window over the others: 3 figure-eights in 4.5 s, 60 pointer updates/s.
    Judder = how long the picture stays frozen while the pointer keeps moving."""
    key("alt", "f7"); time.sleep(0.4)
    burst["tag"] = tag; burst["on"] = True; th = threading.Thread(target=burster); th.start()
    t = time.monotonic(); steps = 0
    cx, cy = W // 2, H // 2
    while time.monotonic() - t < 4.5:
        a = 2 * math.pi * (time.monotonic() - t) / 1.5
        ev(*absxy(cx + 520 * math.sin(a), cy + 260 * math.sin(2 * a))); steps += 1
        time.sleep(1 / 60)
    burst["on"] = False; th.join()
    key("ret"); time.sleep(1)
    ts, hs = burst["t"], burst["h"]
    same = sum(1 for a, b in zip(hs, hs[1:]) if a == b)
    longest = run = 0.0
    for k in range(1, len(hs)):
        run = run + (ts[k] - ts[k - 1]) if hs[k] == hs[k - 1] else 0.0
        longest = max(longest, run)
    changes = len(hs) - 1 - same
    log(f"MOVE {tag}: {steps} pointer updates in 4.5 s; {len(hs)} snapshots, {changes} picture changes "
        f"({changes / 4.5:.0f}/s), {same} frozen, longest freeze {longest * 1000:.0f} ms")


VARIANTS = sys.argv[5:] if len(sys.argv) > 5 else ["default"]
CMDS = {   # typed into the focused terminal before the move
    "default": None,
    "xpresent": None,
    "vbloff": "xfconf-query -c xfwm4 -p /general/vblank_mode -s off\n",
    "nocomp": "xfconf-query -c xfwm4 -p /general/use_compositing -s false\n",
    "picomxr": "picom -b --config /dev/null --backend xrender\n",
}


log(f"waiting {BOOT:.0f} s for the desktop")
time.sleep(BOOT)
q2.cmd("screendump", filename=os.path.abspath(f"{OUT}/00-desktop.ppm"))
key("meta_l", "down"); time.sleep(1.5)                   # minimize a first-run window if there is one
open_latency("files", "meta_l", "e"); time.sleep(1.5)
open_latency("settings", "meta_l", "i"); time.sleep(1.5)
open_latency("terminal", "meta_l", "ret"); time.sleep(2)
q2.cmd("screendump", filename=os.path.abspath(f"{OUT}/01-three-windows.ppm"))

for v in VARIANTS:
    if CMDS.get(v):
        type_text(CMDS[v]); time.sleep(2.5)
    fast_move(v)
q2.cmd("screendump", filename=os.path.abspath(f"{OUT}/02-after-move.ppm"))
type_text("free -m\n"); time.sleep(1.5)
q2.cmd("screendump", filename=os.path.abspath(f"{OUT}/03-free.ppm"))
log("done")
