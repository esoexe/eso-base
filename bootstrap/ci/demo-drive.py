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
        self.lk = __import__("threading").Lock()            # one socket: the drag and the mid-drag dumps share it
        self.f.readline()                                   # greeting
        self.cmd("qmp_capabilities")

    def cmd(self, name, **args):
        with self.lk:
            return self._cmd(name, **args)

    def _cmd(self, name, **args):
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
    names = {" ": "spc", "\n": "ret", "-": "minus", ".": "dot", "/": "slash", ";": "semicolon", ",": "comma",
             "=": "equal", "'": "apostrophe", "[": "bracket_left", "]": "bracket_right"}
    shifted = {"$": "4", "_": "minus", ":": "semicolon", "|": "backslash", ">": "dot", "(": "9", ")": "0",
               "*": "8", "+": "equal", '"': "apostrophe", "<": "comma", "{": "bracket_left", "}": "bracket_right",
               "!": "1", "&": "7", "#": "3", "%": "5"}
    for ch in s:
        if ch.isupper():
            key("shift", ch.lower())
        elif ch in shifted:
            key("shift", shifted[ch])
        else:
            key(names.get(ch, ch))
        time.sleep(gap)


def alt_drag(path, secs):
    """move the window under the pointer with Alt+drag (xfwm4 'easy click'): any point inside the window works"""
    ev({"type": "key", "data": {"down": True, "key": {"type": "qcode", "data": "alt"}}})
    time.sleep(0.05); btn(True); time.sleep(0.08)
    glide(path, secs)
    time.sleep(0.05); btn(False); time.sleep(0.05)
    ev({"type": "key", "data": {"down": False, "key": {"type": "qcode", "data": "alt"}}})


def glide(path, secs, hz=120):
    """one continuous hand movement through all points of path (a smooth Catmull-Rom curve, constant speed along
    it, easing only at the very start and end), at hz input updates/s on absolute deadlines (no drift, no pauses
    at the points - the old per-point ease made the window stop and go)"""
    pts = [tuple(cur)] + [tuple(p) for p in path]
    if len(pts) < 2:
        return
    ext = [pts[0]] + pts + [pts[-1]]
    curve = []
    for i in range(1, len(ext) - 2):
        p0, p1, p2, p3 = ext[i - 1], ext[i], ext[i + 1], ext[i + 2]
        for k in range(16):
            t = k / 16
            curve.append(tuple(0.5 * ((2 * p1[j]) + (-p0[j] + p2[j]) * t + (2 * p0[j] - 5 * p1[j] + 4 * p2[j] - p3[j]) * t * t
                                      + (-p0[j] + 3 * p1[j] - 3 * p2[j] + p3[j]) * t * t * t) for j in (0, 1)))
    curve.append(pts[-1])
    acc = [0.0]
    for a_, b_ in zip(curve, curve[1:]):
        acc.append(acc[-1] + math.hypot(b_[0] - a_[0], b_[1] - a_[1]))
    total = acc[-1] or 1.0
    n = max(2, int(secs * hz)); t0 = time.monotonic(); j = 0
    for i in range(1, n + 1):
        u = i / n
        u = u * u * (3 - 2 * u) if secs < 0.6 else (0.5 * u * u / 0.15 / 0.85 if u < 0.15 else
             (1 - 0.5 * (1 - u) * (1 - u) / 0.15 / 0.85 if u > 0.85 else (u - 0.075) / 0.85))   # short ramps
        d = u * total
        while j < len(acc) - 2 and acc[j + 1] < d:
            j += 1
        seg = (acc[j + 1] - acc[j]) or 1.0; f = min(1.0, max(0.0, (d - acc[j]) / seg))
        x = curve[j][0] + (curve[j + 1][0] - curve[j][0]) * f; y = curve[j][1] + (curve[j + 1][1] - curve[j][1]) * f
        ev(*absxy(x, y))
        dl = t0 + i * secs / n - time.monotonic()
        if dl > 0:
            time.sleep(dl)
    cur[:] = [pts[-1][0], pts[-1][1]]


def title_drag(grab, path, secs):
    """drag a window by its title bar (grab = a point on the title bar), like a hand: one continuous movement"""
    move(*grab, 0.5); time.sleep(0.1)
    btn(True); time.sleep(0.12)
    glide(path, secs)
    time.sleep(0.08); btn(False); time.sleep(0.1)


def key_drag(path, secs):
    """xfwm4's keyboard move (Alt+F7): the focused window follows the pointer, no mouse button needed; Return ends it"""
    key("alt", "f7"); time.sleep(0.3)
    step = secs / max(1, len(path))
    for (x, y) in path:
        move(x, y, step)
    time.sleep(0.1); key("ret"); time.sleep(0.2)


def ppm(name):
    q.cmd("screendump", filename=os.path.abspath(f"{SHOTS}/.{name}.ppm"))
    b = open(f"{SHOTS}/.{name}.ppm", "rb").read()
    os.remove(f"{SHOTS}/.{name}.ppm")
    i = 0
    for _ in range(4):                                   # P6 / width height / maxval: skip the 3 header lines
        i = b.index(b"\n", i) + 1 if _ < 3 else i
    return b[i:]


def changed(a, b):
    """fraction of sampled pixels that differ (grid sample over the whole screen)"""
    n = d = 0
    for y in range(40, H - 60, 24):
        for x in range(0, W, 24):
            o = (y * W + x) * 3
            n += 1
            if abs(a[o] - b[o]) + abs(a[o + 1] - b[o + 1]) + abs(a[o + 2] - b[o + 2]) > 30:
                d += 1
    return d / max(1, n)


def mice():
    """which QEMU mouse gets button events right now (the 'current' one)"""
    try:
        r = q.cmd("query-mice")
        r = r.get("return", r) if isinstance(r, dict) else r
        return ", ".join(f"{m['name']}{'*' if m.get('current') else ''}{'(abs)' if m.get('absolute') else ''}"
                         for m in r)
    except Exception as e:                               # noqa: BLE001
        return f"query-mice failed: {e}"


def drag_window(grab, path, secs, name):
    """move the window smoothly; verify it really moved, else try Alt+drag, then the keyboard move"""
    log(f"drag {name}: mice = {mice()}")
    before = ppm(name + "-a")
    end = path[-1]
    mid = []

    def middump():                                       # WHILE the pointer still moves: does the screen follow?
        time.sleep(0.72 + secs * 0.25); mid.append(ppm(name + "-m1"))
        time.sleep(min(0.4, secs * 0.25)); mid.append(ppm(name + "-m2"))
    th = __import__("threading").Thread(target=middump, daemon=True); th.start()
    title_drag(grab, path, secs)
    th.join(5)
    c = changed(before, ppm(name + "-b"))
    if c > 0.02:
        m = changed(mid[0], mid[1]) if len(mid) == 2 else -1
        log(f"drag {name}: title bar ok ({c:.0%} of the screen changed); mid-drag "
            + (f"FROZEN: the screen did not follow the pointer ({m:.1%})" if 0 <= m < 0.004 else f"live ({m:.1%})"))
        with open(f"{SHOTS}/middrag.txt", "a") as f:
            f.write(f"{name} {'FROZEN' if 0 <= m < 0.004 else 'live'} {m:.4f}\n")
        return
    log(f"drag {name}: title bar did nothing ({c:.1%}), trying Alt+drag")
    move(grab[0], grab[1] + 120, 0.3)
    alt_drag([(x, y + 120) for (x, y) in path], secs)
    c = changed(before, ppm(name + "-c"))
    if c > 0.02:
        log(f"drag {name}: Alt+drag ok ({c:.0%})"); return
    log(f"drag {name}: Alt+drag did nothing ({c:.1%}), keyboard move")
    move(*grab, 0.2)
    key_drag(path, secs)
    c = changed(before, ppm(name + "-d"))
    log(f"drag {name}: keyboard move {'ok' if c > 0.02 else 'did NOTHING'} ({c:.0%})")


def figure8(cx, cy, rx, ry, pts=24):
    return [(cx + rx * math.sin(2 * math.pi * i / pts), cy + ry * math.sin(4 * math.pi * i / pts)) for i in range(pts + 1)]


def shot(name):
    q.cmd("screendump", filename=os.path.abspath(f"{SHOTS}/{name}.ppm"))
    log(f"shot {name}")


def wait(s):
    time.sleep(s)


q = QMP(SOCK)
if os.environ.get("DEMO_PHASE") == "diag":
    # after the recording: who the terminal runs as and its Linux capabilities (zsh showed # for a normal user)
    log("diagnostics")
    key("meta_l", "ret"); time.sleep(3.5)
    shot("89-matrix-fresh")                              # untouched new terminal: its first line must be the shell's
    type_text("clear; cat $XDG_RUNTIME_DIR/eso/intro.log; grep -a 'eso-shell:' $XDG_RUNTIME_DIR/eso/autostart.log; "
              "ps -o etimes=,comm= -C xfwm4,picom,eso-shell; cut -d' ' -f1 /proc/uptime; "
              "echo compositor $(eso-perf compositor) vblank $(xfconf-query -c xfwm4 -p /general/vblank_mode) "
              "eso-xfwm4 $(grep -ca ESO_XFWM_PAINT_US /proc/$(pgrep -n -x xfwm4)/exe); "
              "xfconf-query -c xfwm4 -p /general/use_compositing; grep -ah 'compos\\|picom' $XDG_RUNTIME_DIR/eso/*.log | tail -4; "
              "python3 -c 'import gi;from gi.repository import Gdk;print(\"composited now\",Gdk.Screen.get_default().is_composited())'\n")
    time.sleep(4)
    shot("90-diag-terminal")
    sys.exit(0)
PROBE = """python3 -c "import glob,select,struct,time
fs={open(p,'rb',buffering=0):p for p in glob.glob('/dev/input/event*')}
nm=lambda p:open('/sys/class/input/'+p[11:]+'/device/name').read().strip()
t=time.time()+9
while time.time()<t:
 for f in select.select(list(fs),[],[],0.3)[0]:
  s,u,ty,c,v=struct.unpack('llHHi',f.read(24))
  if ty==1 and c in (272,273):print('BUTTON',c,v,'from',fs[f],nm(fs[f]))
print('probe done')"
"""
GRAB = """python3 -c "import gi;gi.require_version('Gtk','3.0');from gi.repository import Gtk,Gdk;s=Gdk.Display.get_default().get_default_seat();r=s.grab(Gdk.get_default_root_window(),Gdk.SeatCapabilities.POINTER,False,None,None,None,None);print('X POINTER GRAB TEST:',r.value_nick)"
"""

# ---- dragdiag: what really happens inside the VM during a window drag --------------------------------------------
# The guest fetches a probe from this script over QEMU's user network (host = 10.0.2.2) and posts its results back.
# The probe logs, every ~5 ms, the pointer and where X has the dragged window, and grabs the X framebuffer mid-drag;
# the host takes QEMU screendumps at the same moments. Window not moving in the log -> the window manager;
# moving in the log but not in the guest grab -> the X server/driver; moving in both but not on QEMU's screen -> QEMU.
GUEST_PROBE = r"""
import os, sys, time, glob, subprocess, threading, urllib.request, ctypes, ctypes.util
H = 'http://10.0.2.2:8765/'
def put(name, data):
    if isinstance(data, str): data = data.encode()
    urllib.request.urlopen(urllib.request.Request(H + name, data=data, method='POST'), timeout=10).read()
def get(name):
    return urllib.request.urlopen(H + name, timeout=10).read()
def sh(c):
    try: return subprocess.run(c, shell=True, capture_output=True, text=True, timeout=10).stdout
    except Exception as e: return str(e)
info = []
for lg in [os.path.expanduser('~/.local/share/xorg/Xorg.0.log'), '/var/log/Xorg.0.log']:
    if os.path.exists(lg):
        info.append('== ' + lg); info.append(sh("grep -aE 'LoadModule|Option|ShadowFB|glamor|cursor|Cursor|PageFlip|TearFree|AccelMethod' " + lg + " | head -40"))
info.append('== conf ' + sh('cat /etc/X11/xorg.conf.d/*.conf /usr/share/X11/xorg.conf.d/*eso* 2>/dev/null | head -60'))
info.append('== ps ' + sh('ps -eo pid,psr,pcpu,stat,args --sort=-pcpu | head -25'))
put('dd-info.txt', '\n'.join(info))
X = ctypes.CDLL(ctypes.util.find_library('X11'))
X.XOpenDisplay.restype = ctypes.c_void_p; X.XOpenDisplay.argtypes = [ctypes.c_char_p]
X.XDefaultRootWindow.restype = ctypes.c_ulong; X.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
X.XInternAtom.restype = ctypes.c_ulong; X.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
X.XGetWindowProperty.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_long, ctypes.c_long, ctypes.c_int,
    ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_ulong),
    ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_void_p)]
X.XFetchName.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_char_p)]
X.XTranslateCoordinates.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_int, ctypes.c_int,
    ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_ulong)]
X.XQueryPointer.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_ulong),
    ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int),
    ctypes.POINTER(ctypes.c_uint)]
dp = X.XOpenDisplay(None); xr = X.XDefaultRootWindow(dp)
def clients():
    at, fm, n, ba, pr = ctypes.c_ulong(), ctypes.c_int(), ctypes.c_ulong(), ctypes.c_ulong(), ctypes.c_void_p()
    X.XGetWindowProperty(dp, xr, X.XInternAtom(dp, b'_NET_CLIENT_LIST', 0), 0, 1024, 0, 0, ctypes.byref(at),
                         ctypes.byref(fm), ctypes.byref(n), ctypes.byref(ba), ctypes.byref(pr))
    return list(ctypes.cast(pr, ctypes.POINTER(ctypes.c_ulong))[:n.value]) if pr.value else []
def find():
    for c in clients():
        nm = ctypes.c_char_p()
        if X.XFetchName(dp, c, ctypes.byref(nm)) and nm.value and b'ESO Setup' in nm.value: return c
xid = find()
def wpos():
    if xid is None: return -1, -1
    x, y, ch = ctypes.c_int(), ctypes.c_int(), ctypes.c_ulong()
    X.XTranslateCoordinates(dp, xid, xr, 0, 0, ctypes.byref(x), ctypes.byref(y), ctypes.byref(ch)); return x.value, y.value
def ppos():
    r, c, a, b, d, e, m = ctypes.c_ulong(), ctypes.c_ulong(), ctypes.c_int(), ctypes.c_int(), ctypes.c_int(), ctypes.c_int(), ctypes.c_uint()
    X.XQueryPointer(dp, xr, ctypes.byref(r), ctypes.byref(c), ctypes.byref(a), ctypes.byref(b), ctypes.byref(d), ctypes.byref(e), ctypes.byref(m))
    return a.value, b.value, m.value
def pids(name):
    out = []
    for p in glob.glob('/proc/[0-9]*/comm'):
        try:
            if open(p).read().strip() == name: out.append(p.split('/')[2])
        except OSError: pass
    return out
def procs():
    d = {}
    for n in ('Xorg', 'xfwm4', 'eso-shell', 'python3'):
        for pid in pids(n):
            for tdir in glob.glob('/proc/%s/task/*' % pid):
                try:
                    st = open(tdir + '/stat').read().rsplit(')', 1)[1].split()
                    wc = open(tdir + '/wchan').read().strip()
                    tn = open(tdir + '/comm').read().strip()
                    d['%s/%s/%s' % (n, pid, tn)] = (st[0], int(st[11]) + int(st[12]), wc)
                except OSError: pass
    return d
def run(tag, secs):
    rows, prow = [], []
    stop = time.time() + secs; t0 = time.time()
    def sampler():
        last = {}
        while time.time() < stop:
            t = time.time() - t0; cur = procs()
            busy = []
            for k, (stt, cpu, wc) in cur.items():
                dc = cpu - last.get(k, (0, cpu, 0))[1]
                if dc > 0 or stt == 'R' or (k.startswith('Xorg') or k.startswith('xfwm4')):
                    busy.append('%s:%s:%d:%s' % (k, stt, dc, wc))
            last = cur
            prow.append('%.3f %s' % (t, ' '.join(busy)))
            time.sleep(0.02)
    th = threading.Thread(target=sampler, daemon=True); th.start()
    grabs = [2.6, 3.6]
    while time.time() < stop:
        t = time.time() - t0
        px, py, m = ppos(); ox, oy = wpos()
        rows.append('%.4f %.4f %d %d %d %d %d' % (t, time.time() - t0, px, py, ox, oy, m))
        time.sleep(0.004)
    th.join()
    put('dd-track-%s.txt' % tag, '\n'.join(rows)); put('dd-procs-%s.txt' % tag, '\n'.join(prow))
for tag in ('A', 'B'):
    while get('go-' + tag) != b'1': time.sleep(0.03)
    if tag == 'B':
        pass
    run(tag, 7.0)
    put('dd-done-%s.txt' % tag, 'ok')
    if tag == 'A':
        sh('xfconf-query -c xfwm4 -p /general/use_compositing -s true; xfconf-query -c xfwm4 -p /general/vblank_mode -s off')
        subprocess.Popen('xfwm4 --replace --compositor=on --sm-client-disable >/dev/null 2>&1 &', shell=True)
        time.sleep(4); dp = X.XOpenDisplay(None); xr = X.XDefaultRootWindow(dp); xid = find()
        put('dd-switched.txt', sh('ps -o args= -C xfwm4') + ' xid %s' % xid)
"""

GO = set()


def dd_server():
    import http.server, threading

    class Hd(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            n = self.path.strip("/")
            b = GUEST_PROBE.encode() if n == "p" else (b"1" if n in GO else b"0")
            self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers()
            self.wfile.write(b)

        def do_POST(self):
            n = int(self.headers.get("Content-Length", 0)); data = self.rfile.read(n)
            name = os.path.basename(self.path.strip("/")) or "post.bin"
            open(os.path.join(SHOTS, name), "wb").write(data)
            log(f"probe posted {name} ({n} bytes)")
            self.send_response(200); self.end_headers(); self.wfile.write(b"ok")

        def log_message(self, *a):
            pass
    srv = http.server.ThreadingHTTPServer(("0.0.0.0", 8765), Hd)
    threading.Thread(target=srv.serve_forever, daemon=True).start()


def have(n):
    return os.path.exists(os.path.join(SHOTS, n))


def until(n, secs):
    t = time.time() + secs
    while not have(n) and time.time() < t:
        time.sleep(0.05)
    return have(n)


if os.environ.get("DEMO_PHASE") == "dragdiag":
    import threading
    dd_server()
    log("drag diagnostics; waiting for the desktop")
    wait(float(os.environ.get("DEMO_BOOT_WAIT", "38")))
    SETUP_T = (900, 254)
    key("meta_l", "ret"); wait(3.5)
    type_text("python3 -c \"import urllib.request as u;exec(u.urlopen('http://10.0.2.2:8765/p').read())\" > /tmp/dd.log 2>&1 &\n")
    wait(0.5); key("meta_l", "down"); wait(1.5)            # the terminal out of the way: ESO Setup on top
    log(f"probe hello: {until('dd-info.txt', 30)}")
    lock = threading.Lock(); orig = QMP.cmd

    def locked(self, name, **a):
        with lock:
            return orig(self, name, **a)
    QMP.cmd = locked                                       # one QMP socket, shared by the drag and the dumps
    for tag in ("A", "B"):
        if tag == "B":
            log(f"switched: {until('dd-switched.txt', 30)}"); wait(1.0)
        move(*SETUP_T, 0.4); wait(0.3)
        GO.add("go-" + tag); tg = time.time(); log(f"go {tag}")
        while time.time() < tg + 1.0:
            time.sleep(0.005)

        def dumps():
            for g in (2.6, 3.6):
                while time.time() < tg + g:
                    time.sleep(0.002)
                q.cmd("screendump", filename=os.path.abspath(f"{SHOTS}/dd-qemu-{tag}-{g:.1f}.ppm"))
        th = threading.Thread(target=dumps); th.start()
        btn(True); time.sleep(0.12)
        path = [(-420, 60), (-200, 260), (300, 300), (430, 40), (150, -110)]
        glide([(SETUP_T[0] + dx, SETUP_T[1] + dy) for (dx, dy) in path], 4.0)
        time.sleep(0.08); btn(False); log(f"drag {tag} end"); th.join()
        log(f"done {tag}: {until('dd-done-' + tag + '.txt', 30)}")
        SETUP_T = (SETUP_T[0] + 150, SETUP_T[1] - 110)      # the title bar is where the drag left it
    wait(2); shot("dd-end")
    sys.exit(0)
if os.environ.get("DEMO_PHASE") == "bootdiag":
    # why the first title-bar drag after boot did nothing: QEMU mouse routing, or an X pointer grab in ESO?
    log("boot diagnostics; waiting for the desktop")
    wait(float(os.environ.get("DEMO_BOOT_WAIT", "38")))
    log(f"mice at the desktop: {mice()}")
    SETUP_T = (900, 254)
    drag_window(SETUP_T, [(SETUP_T[0] - 300, SETUP_T[1] + 150), (SETUP_T[0] - 380, SETUP_T[1] + 200)], 1.5, "setup1")
    shot("80-after-first-drag")
    key("meta_l", "ret"); wait(3)
    type_text("findmnt -no FSTYPE,SIZE /tmp; uptime\n"); wait(1)
    type_text(GRAB); wait(3)
    type_text(PROBE); wait(1.5)
    for i in range(3):                                   # clicks on the empty desktop corner while the probe listens
        click(1500, 900 - 40 * i, 0.4); wait(0.8)
    log(f"mice after the clicks: {mice()}")
    wait(5)
    shot("81-probe")
    key("ctrl", "esc"); wait(1.5); key("esc"); wait(1)
    log(f"mice after Start: {mice()}")
    key("meta_l", "ret"); wait(3)
    type_text(GRAB); wait(3)
    type_text(PROBE); wait(1.5)
    for i in range(3):
        click(1500, 900 - 40 * i, 0.4); wait(0.8)
    wait(5)
    shot("82-probe-after-start")
    sys.exit(0)
if os.environ.get("DEMO_PHASE") == "watchdiag":
    # the shell watcher: kill the shell on purpose; the taskbar + desktop icons must come back within ~3 s
    log("watcher diagnostics; waiting for the desktop")
    wait(float(os.environ.get("DEMO_BOOT_WAIT", "38")))
    key("meta_l", "down"); wait(1)
    key("meta_l", "ret"); wait(3)
    type_text("clear; pgrep -af eso-shellwatc[h]; pgrep -a -x eso-shell; pkill -x eso-shell; sleep 0.7; echo killed\n")
    wait(1.2); shot("60-shell-killed")
    wait(5); type_text("pgrep -a -x eso-shell; grep shellwatch $XDG_RUNTIME_DIR/eso/autostart.log\n")
    wait(2); shot("61-shell-back")
    sys.exit(0)
if os.environ.get("DEMO_PHASE") == "closediag":
    # the taskbar + desktop icons vanished together with the browser on Alt+F4: reproduce and collect the logs
    log("close diagnostics; waiting for the desktop")
    wait(float(os.environ.get("DEMO_BOOT_WAIT", "38")))
    key("meta_l", "down"); wait(1)                       # minimize ESO Setup
    shot("70-desktop")
    key("meta_l", "b"); wait(8); shot("71-browser")
    key("alt", "f4"); wait(2.5); shot("72-after-close-browser")
    key("meta_l", "b"); wait(8)
    key("meta_l", "n"); wait(1.8); key("esc"); wait(0.8); shot("73-browser-after-notif")
    key("alt", "f4"); wait(2.5); shot("74-after-close-browser-2")
    key("meta_l", "ret"); wait(3)
    type_text("clear; tail -n 22 $XDG_RUNTIME_DIR/eso/autostart.log | cut -c1-150; pgrep -a python3 | cut -c1-110\n")
    wait(3); shot("75-logs")
    sys.exit(0)
log("connected; waiting for the desktop")
cx, cy = W // 2, H // 2
# the desktop (with ESO Setup on a live boot) is up ~12 s after power-on with KVM; give it margin
wait(float(os.environ.get("DEMO_BOOT_WAIT", "38")))
shot("01-desktop")

# window title bars, measured on the 1920x1080 desktop (setup: ESO OS 3.13.26; others 3.13.6; windows open centred)
SETUP_T, FILES_T, SETTINGS_T, TERM_T = (900, 254), (900, 172), (850, 164), (800, 234)

# 1. the setup window: drag it around smoothly (3.13.6: no trails), put it back, minimize it
drag_window(SETUP_T, [(SETUP_T[0] + dx, SETUP_T[1] + dy) for (dx, dy) in
                      [(-420, 60), (-200, 260), (300, 300), (430, 40), (150, -110)]], 4.0, "setup")
# (the path must not end where it began: the before/after comparison would then see "no change")
shot("02-dragged-setup")
key("meta_l", "down"); wait(1.2)

# 2. Start menu, search
_pre = ppm("pre-start")
key("ctrl", "esc"); wait(1.6); shot("03-start")
# Health gate (3.13.18 shipped without a working shell and the demo still "passed"): the Start menu must open.
_d = changed(_pre, ppm("post-start"))
HEALTH = "OK" if _d >= 0.02 else f"FAIL: Ctrl+Esc changed {_d:.1%} of the screen - the desktop shell is not running"
log(f"health: {HEALTH} (start-menu change {_d:.1%})")
open(f"{SHOTS}/HEALTH", "w").write(HEALTH + "\n")
type_text("settings"); wait(1.5); shot("04-search")
# 3.13.17 launch zoom: Enter opens Settings - it grows out of the Start menu, then becomes the real window
key("ret"); wait(0.12); shot("04a-zoom-grow"); wait(0.25); shot("04b-zoom-landed"); wait(3.0); shot("04c-zoom-window")
key("alt", "f4"); wait(1.2)

# 3. Files, dragged to the left
key("meta_l", "e"); wait(3.0); shot("05-files")
drag_window(FILES_T, [(FILES_T[0] - 150, FILES_T[1] + 120), (FILES_T[0] - 380, FILES_T[1] + 60)], 2.2, "files")

# 4. Settings, dragged across Files (Files underneath must stay clean)
key("meta_l", "i"); wait(3.5); shot("06-settings")
drag_window(SETTINGS_T, [(SETTINGS_T[0] - 350, SETTINGS_T[1] + 180), (SETTINGS_T[0] + 50, SETTINGS_T[1] + 260),
                         (SETTINGS_T[0] + 380, SETTINGS_T[1] + 90)], 3.5, "settings")
shot("07-overlap")
# 3.13.23: a fast flick (~2000 px/s figure-of-eight over Files): the window must stay glued to the pointer
FL = (SETTINGS_T[0] + 380, SETTINGS_T[1] + 90)
title_drag(FL, figure8(FL[0] - 420, FL[1] + 260, 420, 170, 32), 1.8)
shot("07b-after-flick")
key("meta_l", "up"); wait(1.6); shot("08-maximized")
key("meta_l", "up"); wait(1.4)

# 5. Terminal: system report with the ESO logo
key("meta_l", "ret"); wait(2.5)
type_text("fastfetch\n"); wait(3.5); shot("09-terminal")
drag_window(TERM_T, [(TERM_T[0] + 120, TERM_T[1] + 200), (TERM_T[0] + 60, TERM_T[1] + 300)], 2.0, "terminal")

# 6. Task view
key("meta_l", "tab"); wait(2.2); shot("10-taskview")
key("esc"); wait(1.0)

# 7. Browser
key("meta_l", "b"); wait(7.0); shot("11-browser")
key("meta_l", "up"); wait(1.5); key("meta_l", "up"); wait(1.0)

# 8. Quick settings and notifications
key("meta_l", "a"); wait(1.8); shot("12-quick")
key("esc"); wait(0.8)
key("meta_l", "n"); wait(1.8); shot("13-notifications")
key("esc"); wait(0.8)

# 9. close the 4 windows this demo opened (browser, terminal, settings, files), back to the desktop
for i in range(4):
    key("alt", "f4"); wait(1.1); shot(f"15-close-{i + 1}")
move(cx + 300, cy + 200, 1.0); wait(2.5)
shot("14-end")
log("demo done")
