#!/usr/bin/env python3
"""Drive a booted ESO OS VM like a person would, for the full-screen demo recording (CI, eso-os-demo.yml).
Talks to QEMU over QMP: absolute pointer (usb-tablet) + keyboard. Real-time, nothing sped up.
usage: demo-drive.py QMP_SOCKET SHOTS_DIR [WIDTH HEIGHT]"""
import json, math, os, socket, sys, time

SOCK, SHOTS = sys.argv[1], sys.argv[2]
W, H = (int(sys.argv[3]), int(sys.argv[4])) if len(sys.argv) > 4 else (1920, 1080)
os.makedirs(SHOTS, exist_ok=True)
T0 = time.time()


class QMP:
    def __init__(self, path):
        for _ in range(100):
            try:
                self.s = socket.socket(socket.AF_UNIX); self.s.connect(path); break
            except OSError:
                time.sleep(0.2)
        self.f = self.s.makefile("rw")
        self.f.readline()                                   # greeting
        self.cmd("qmp_capabilities")

    def cmd(self, name, **args):
        self.f.write(json.dumps({"execute": name, "arguments": args} if args else {"execute": name}) + "\n")
        self.f.flush()
        while True:
            r = json.loads(self.f.readline())
            if "return" in r or "error" in r:
                if "error" in r:
                    log(f"QMP {name}: {r['error']}")
                return r


q = None
cur = [W // 2, H // 2]


def log(m):
    print(f"[{time.time() - T0:6.1f}s] {m}", flush=True)


def ev(*events):
    q.cmd("input-send-event", events=list(events))


def absxy(x, y):
    return [{"type": "abs", "data": {"axis": "x", "value": int(x * 32767 / (W - 1))}},
            {"type": "abs", "data": {"axis": "y", "value": int(y * 32767 / (H - 1))}}]


def move(x, y, secs=0.0):
    """glide the pointer (60 updates/s) so the recording shows a real hand movement"""
    x0, y0 = cur
    n = max(1, int(secs * 60))
    for i in range(1, n + 1):
        t = i / n
        t = t * t * (3 - 2 * t)                             # ease in/out
        ev(*absxy(x0 + (x - x0) * t, y0 + (y - y0) * t))
        if n > 1:
            time.sleep(secs / n)
    cur[:] = [x, y]


def btn(down, b="left"):
    ev({"type": "btn", "data": {"down": down, "button": b}})


def click(x, y, secs=0.5, double=False):
    move(x, y, secs); time.sleep(0.08)
    for _ in range(2 if double else 1):
        btn(True); time.sleep(0.06); btn(False); time.sleep(0.09)


def key(*names, hold=0.06):
    """a key combination by QEMU qcode names, e.g. key('meta_l', 'e')"""
    for k in names:
        ev({"type": "key", "data": {"down": True, "key": {"type": "qcode", "data": k}}}); time.sleep(0.02)
    time.sleep(hold)
    for k in reversed(names):
        ev({"type": "key", "data": {"down": False, "key": {"type": "qcode", "data": k}}}); time.sleep(0.02)


def type_text(s, gap=0.07):
    names = {" ": "spc", "\n": "ret", "-": "minus", ".": "dot", "/": "slash"}
    for ch in s:
        if ch.isupper():
            key("shift", ch.lower())
        else:
            key(names.get(ch, ch))
        time.sleep(gap)


def alt_drag(path, secs):
    """move the window under the pointer with Alt+drag (xfwm4 'easy click'): any point inside the window works"""
    ev({"type": "key", "data": {"down": True, "key": {"type": "qcode", "data": "alt"}}})
    time.sleep(0.05); btn(True); time.sleep(0.08)
    step = secs / max(1, len(path))
    for (x, y) in path:
        move(x, y, step)
    time.sleep(0.05); btn(False); time.sleep(0.05)
    ev({"type": "key", "data": {"down": False, "key": {"type": "qcode", "data": "alt"}}})


def figure8(cx, cy, rx, ry, pts=24):
    return [(cx + rx * math.sin(2 * math.pi * i / pts), cy + ry * math.sin(4 * math.pi * i / pts)) for i in range(pts + 1)]


def shot(name):
    q.cmd("screendump", filename=os.path.abspath(f"{SHOTS}/{name}.ppm"))
    log(f"shot {name}")


def wait(s):
    time.sleep(s)


q = QMP(SOCK)
log("connected; waiting for the desktop")
cx, cy = W // 2, H // 2
# the desktop (with ESO Setup on a live boot) is up ~12 s after power-on with KVM; give it margin
wait(float(os.environ.get("DEMO_BOOT_WAIT", "38")))
shot("01-desktop")

# 1. the setup window: glide to it, drag it around smoothly (3.13.6: no trails), then minimize it
move(cx, cy - 60, 0.8); wait(0.4)
alt_drag(figure8(cx, cy - 60, 420, 160), 4.0); wait(0.6)
shot("02-dragged-setup")
key("meta_l", "down"); wait(1.2)

# 2. Start menu, search
key("ctrl", "esc"); wait(1.6); shot("03-start")
type_text("settings"); wait(1.5); shot("04-search")
key("esc"); wait(0.8)

# 3. Files, dragged
key("meta_l", "e"); wait(3.0); shot("05-files")
move(cx, cy, 0.6)
alt_drag(figure8(cx, cy, 380, 180), 4.0); wait(0.5)

# 4. Settings over Files, dragged across it (the window underneath must stay clean)
key("meta_l", "i"); wait(3.5); shot("06-settings")
move(cx + 40, cy, 0.5)
alt_drag([(cx - 300, cy - 120), (cx + 320, cy + 80), (cx - 200, cy + 120), (cx + 40, cy)], 4.0); wait(0.6)
shot("07-overlap")
key("meta_l", "up"); wait(1.6); shot("08-maximized")
key("meta_l", "up"); wait(1.4)

# 5. Terminal: system info
key("meta_l", "ret"); wait(2.5)
type_text("fastfetch\n"); wait(3.5); shot("09-terminal")

# 6. Task view
key("meta_l", "tab"); wait(2.2); shot("10-taskview")
key("esc"); wait(1.0)

# 7. Browser
key("meta_l", "b"); wait(7.0); shot("11-browser")
move(cx, cy + 40, 0.5)
alt_drag(figure8(cx, cy + 40, 260, 120, 16), 3.0); wait(0.6)

# 8. Quick settings and notifications
key("meta_l", "a"); wait(1.8); shot("12-quick")
key("esc"); wait(0.8)
key("meta_l", "n"); wait(1.8); shot("13-notifications")
key("esc"); wait(0.8)

# 9. close everything with Alt+F4, back to a clean desktop
for i in range(5):
    key("alt", "f4"); wait(1.0)
move(cx + 300, cy + 200, 1.0); wait(2.5)
shot("14-end")
log("demo done")
