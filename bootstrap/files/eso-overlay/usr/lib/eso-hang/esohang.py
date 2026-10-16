"""esohang - finds what makes an ESO app freeze, lag or show "not responding".

A heartbeat runs inside the app's GTK main loop; a watcher thread notices when it stops (the interface is blocked)
and samples the main thread's Python stack while it is blocked. When the interface runs again, one line is written:

    <ms>ms <app> | <file>:<line> <function> < <caller> < ...    (the most frequent stack during the stall)

to $XDG_RUNTIME_DIR/eso/hangs.log. Turned on by ESO_HANGLOG=1 (eso-selftest, or for a bug report); costs nothing
otherwise, because nothing starts. Loaded into every ESO Python program by sitecustomize (PYTHONPATH=.../eso-hang).
"""
import os, sys, threading, time, collections

THRESH = float(os.environ.get("ESO_HANG_MS", "100")) / 1000.0
_last = time.monotonic()
_started = False
_loop_seen = False            # the first stall before the main loop ever ran = start-up time


def _app():
    return os.path.basename(sys.argv[0] or "python") if sys.argv else "python"


def _log_path():
    d = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or f"/tmp/eso-{os.getuid()}", "eso")
    os.makedirs(d, exist_ok=True)
    return os.path.join(d, "hangs.log")


def _stack(frame, depth=6):
    out = []
    while frame is not None and len(out) < depth:
        co = frame.f_code
        fn = co.co_filename
        if "-packages/gi/" in fn or "/gi/overrides/" in fn or fn.endswith("esohang.py"):
            frame = frame.f_back
            continue
        out.append(f"{os.path.basename(fn)}:{frame.f_lineno} {co.co_name}")
        frame = frame.f_back
    return " < ".join(out) or "(in C code: GTK drawing, a C library call or the window system)"


def _beat():
    global _last, _loop_seen
    _last = time.monotonic()
    _loop_seen = True
    return True


def _watch(main_id):
    from gi.repository import GLib
    GLib.timeout_add(20, _beat)                           # PRIORITY_DEFAULT (PyGObject 3.54 rejects priority=)
    stalled_since, samples = None, collections.Counter()
    while True:
        time.sleep(0.025)
        now = time.monotonic()
        late = now - _last
        if late > THRESH:
            if stalled_since is None:
                stalled_since, samples, was_loop = _last, collections.Counter(), _loop_seen
            f = sys._current_frames().get(main_id)
            samples[_stack(f) if f is not None else "(no main thread)"] += 1
        elif stalled_since is not None:
            dur = (_last - stalled_since) * 1000
            top, n = samples.most_common(1)[0] if samples else ("?", 0)
            kind = "" if was_loop else " startup"
            try:
                with open(_log_path(), "a") as fh:
                    fh.write(f"{dur:.0f}ms {_app()}{kind} | {top}\n")
            except OSError:
                pass
            stalled_since = None


def start():
    """Start watching once GLib is imported (from sitecustomize, before the app's own code runs)."""
    global _started
    if _started or os.environ.get("ESO_HANGLOG") != "1":
        return
    # never inside the app preloader: it fork()s every app, and a watcher thread there makes eso-appd refuse to
    # fork (correctly: fork copies only one thread). Each app started from it watches itself (esoui/esowait).
    prog = os.path.basename((sys.argv[0] if sys.argv and sys.argv[0] else "") or "")
    if prog == "eso-appd" or any(os.path.basename(a) == "eso-appd" for a in (sys.argv or [])[:2]):
        return
    _started = True
    main_id = threading.main_thread().ident

    def wait_for_glib():
        for _ in range(600):                       # up to 60 s: the app imports gi itself
            if "gi.repository.GLib" in sys.modules or "gi.repository.Gtk" in sys.modules:
                global _last
                _last = time.monotonic()
                _watch(main_id)
                return
            time.sleep(0.1)
    threading.Thread(target=wait_for_glib, name="esohang", daemon=True).start()
