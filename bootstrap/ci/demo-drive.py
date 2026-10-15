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
    step = secs / max(1, len(path))
    for (x, y) in path:
        move(x, y, step)
    time.sleep(0.05); btn(False); time.sleep(0.05)
    ev({"type": "key", "data": {"down": False, "key": {"type": "qcode", "data": "alt"}}})


def title_drag(grab, path, secs):
    """drag a window by its title bar (grab = a point on the title bar)"""
    move(*grab, 0.5); time.sleep(0.1)
    btn(True); time.sleep(0.12)
    step = secs / max(1, len(path))
    for (x, y) in path:
        move(x, y, step)
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
    title_drag(grab, path, secs)
    c = changed(before, ppm(name + "-b"))
    if c > 0.02:
        log(f"drag {name}: title bar ok ({c:.0%} of the screen changed)"); return
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
    key("meta_l", "ret"); time.sleep(3)
    type_text("clear; cat /proc/uptime; ps -eo etimes,user,comm --sort=etimes | grep -v -E ' (kworker|ps|grep|zsh)' | head -28\n")
    time.sleep(2.5)
    shot("90-diag-terminal")
    type_text("clear; sudo -n journalctl -b --no-pager -o short-monotonic | grep -i -E 'session|xorg|xfwm|eso-shell|greet|segfault|killed|oom' | tail -30\n")
    time.sleep(4)
    shot("91-diag-journal")
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
if os.environ.get("DEMO_PHASE") == "bootdiag":
    # why the first title-bar drag after boot did nothing: QEMU mouse routing, or an X pointer grab in ESO?
    log("boot diagnostics; waiting for the desktop")
    wait(float(os.environ.get("DEMO_BOOT_WAIT", "38")))
    log(f"mice at the desktop: {mice()}")
    SETUP_T = (900, 231)
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

# window title bars, measured on the 1920x1080 desktop of ESO OS 3.13.6 (windows open centred)
SETUP_T, FILES_T, SETTINGS_T, TERM_T = (900, 231), (900, 172), (850, 164), (800, 234)

# 1. the setup window: drag it around smoothly (3.13.6: no trails), put it back, minimize it
drag_window(SETUP_T, [(SETUP_T[0] + dx, SETUP_T[1] + dy) for (dx, dy) in
                      [(-420, 60), (-200, 260), (300, 300), (430, 40), (150, -110)]], 4.0, "setup")
# (the path must not end where it began: the before/after comparison would then see "no change")
shot("02-dragged-setup")
key("meta_l", "down"); wait(1.2)

# 2. Start menu, search
key("ctrl", "esc"); wait(1.6); shot("03-start")
type_text("settings"); wait(1.5); shot("04-search")
key("esc"); wait(0.8)

# 3. Files, dragged to the left
key("meta_l", "e"); wait(3.0); shot("05-files")
drag_window(FILES_T, [(FILES_T[0] - 150, FILES_T[1] + 120), (FILES_T[0] - 380, FILES_T[1] + 60)], 2.2, "files")

# 4. Settings, dragged across Files (Files underneath must stay clean)
key("meta_l", "i"); wait(3.5); shot("06-settings")
drag_window(SETTINGS_T, [(SETTINGS_T[0] - 350, SETTINGS_T[1] + 180), (SETTINGS_T[0] + 50, SETTINGS_T[1] + 260),
                         (SETTINGS_T[0] + 380, SETTINGS_T[1] + 90)], 3.5, "settings")
shot("07-overlap")
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
