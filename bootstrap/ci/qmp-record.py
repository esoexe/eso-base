#!/usr/bin/env python3
"""qmp-record.py SOCK OUT.mp4 [FPS]: films the VM straight from its framebuffer (QMP screendump), so the video shows
exactly what ESO OS draws: whole frames only, no tearing added by a VNC viewer or a screen grabber. Frames are
stamped with the wall clock and resampled to FPS (default 60). Stops on SIGINT/SIGTERM."""
import json, os, signal, socket, subprocess, sys, time

SOCK, OUT = sys.argv[1], sys.argv[2]
FPS = int(sys.argv[3]) if len(sys.argv) > 3 else 60
TMP = "/dev/shm/eso-rec.ppm"
run = {"on": True}
signal.signal(signal.SIGINT, lambda *a: run.update(on=False))
signal.signal(signal.SIGTERM, lambda *a: run.update(on=False))

for _ in range(100):
    try:
        s = socket.socket(socket.AF_UNIX); s.connect(SOCK); break
    except OSError:
        time.sleep(0.1)
f = s.makefile("rw")
f.readline()
f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush(); f.readline()

ff = subprocess.Popen(["ffmpeg", "-loglevel", "error", "-y", "-f", "image2pipe", "-use_wallclock_as_timestamps", "1",
                       "-c:v", "ppm", "-i", "-", "-vf", f"scale=1920:1080:flags=bicubic,fps={FPS}", "-c:v", "libx264", "-preset", "ultrafast",
                       "-threads", "2", "-crf", "18", "-pix_fmt", "yuv420p", OUT], stdin=subprocess.PIPE)
n = 0; t0 = time.monotonic()
while run["on"]:
    f.write(json.dumps({"execute": "screendump", "arguments": {"filename": TMP}}) + "\n"); f.flush()
    while True:
        line = f.readline()
        if not line:
            run["on"] = False; break
        if '"return"' in line or '"error"' in line:
            break
    try:
        with open(TMP, "rb") as fh:
            ff.stdin.write(fh.read())
        n += 1
    except (OSError, BrokenPipeError):
        break
    nxt = t0 + n / (FPS * 1.25)              # a little faster than FPS; never more than needed
    d = nxt - time.monotonic()
    if d > 0:
        time.sleep(d)
ff.stdin.close(); ff.wait()
el = time.monotonic() - t0
print(f"qmp-record: {n} frames in {el:.0f} s ({n / max(el, 1):.1f}/s) -> {OUT}", flush=True)
