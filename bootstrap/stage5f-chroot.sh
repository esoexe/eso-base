#!/bin/bash
# ESO Base stage 5f, INSIDE the chroot: WebKitGTK 4.1 — the engine of the ESO Browser and of every ESO app that
# shows web content (GTK 3 API, libsoup 3, GStreamer media, bubblewrap sandbox).
# WebKit is the biggest single build in ESO Base (hours on CI's 4 cores), so it can RESUME: the build tree lives in
# /var/cache/eso-webkit inside ESO Base, the workflow packs it if time runs out, and the next run continues with ninja.
# All from upstream sources. No network inside the chroot: the source is a pinned download in sources-stage5f.list.
set -euo pipefail
. /sources/versions.env
step() { echo; echo "=== $* ($(date -u +%H:%M:%S)) ==="; }
export PKG_CONFIG_PATH=/usr/lib/pkgconfig:/usr/share/pkgconfig
W=/var/cache/eso-webkit; SRC=$W/src; B=$W/build
BUDGET=${ESO_WEBKIT_MINUTES:-300}        # stop ninja cleanly before CI's 6-hour limit so the tree can be packed

if [[ -e /usr/lib/libwebkit2gtk-4.1.so ]]; then
    step "WebKitGTK already installed (resumed run) — only the smoke test"
else
    if [[ ! -f $B/build.ninja ]]; then
        step "WebKitGTK $V_webkitgtk: unpack + configure"
        rm -rf "$W"; mkdir -p "$SRC" "$B"
        tar -xf "/sources/webkitgtk-$V_webkitgtk.tar.xz" -C "$SRC" --strip-components=1
        # Clang is faster and lighter on WebKit than GCC, but only if it works with ESO Base's libstdc++ here
        CCX=(-DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++)
        printf '#include <format>\n#include <string>\n#include <vector>\nint main(){std::vector<std::string> v{"a"};return std::format("{}",v[0]).size()==1?0:1;}\n' > /tmp/t.cc
        if command -v clang++ >/dev/null && clang++ -std=c++20 -O1 /tmp/t.cc -o /tmp/t && /tmp/t; then
            CCX=(-DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++); echo "  compiler: Clang $(clang --version | head -1)"
        else
            echo "  compiler: GCC $(gcc -dumpfullversion) (Clang not usable with this libstdc++)"
        fi
        cd "$B"
        cmake "$SRC" -G Ninja -DPORT=GTK -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr \
            -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_INSTALL_LIBEXECDIR=lib "${CCX[@]}" \
            -DUSE_GTK4=OFF -DENABLE_INTROSPECTION=ON -DENABLE_DOCUMENTATION=OFF -DENABLE_MINIBROWSER=OFF \
            -DENABLE_WEBDRIVER=OFF -DENABLE_API_TESTS=OFF -DENABLE_BUBBLEWRAP_SANDBOX=ON -DENABLE_JOURNALD_LOG=ON \
            -DENABLE_X11_TARGET=ON -DENABLE_WAYLAND_TARGET=ON -DUSE_GBM=ON -DUSE_LIBDRM=ON \
            -DUSE_LIBSECRET=ON -DUSE_AVIF=ON -DUSE_WOFF2=ON -DUSE_LCMS=ON -DENABLE_PDFJS=ON \
            -DENABLE_SPELLCHECK=OFF -DENABLE_GAMEPAD=OFF -DENABLE_SPEECH_SYNTHESIS=OFF -DUSE_FLITE=OFF \
            -DUSE_LIBHYPHEN=OFF -DUSE_JPEGXL=OFF -DUSE_LIBBACKTRACE=OFF -DUSE_SYSPROF_CAPTURE=OFF \
            -DUSE_SYSTEM_SYSPROF_CAPTURE=OFF -DUSE_SYSTEM_UNIFDEF=OFF > /tmp/cmake.log 2>&1 \
            || { tail -60 /tmp/cmake.log; echo "FAILED: WebKitGTK configure"; exit 1; }
        grep -E "^-- (Enabled|  ENABLE_|  USE_)" /tmp/cmake.log | head -60 || true
    else
        step "WebKitGTK: resuming the build tree from the previous run"
    fi
    cd "$B"
    step "WebKitGTK: compiling (budget ${BUDGET} min, $(nproc) cores)"
    # nproc jobs; quiet output except progress every ~5%; a clean stop on the time budget keeps the tree resumable
    set +e
    timeout --signal=TERM "${BUDGET}m" ninja -j"$(nproc)" > /tmp/ninja.log 2>&1 &
    NP=$!
    while kill -0 $NP 2>/dev/null; do sleep 300; tail -1 /tmp/ninja.log | cut -c1-120; done
    wait $NP; rc=$?
    set -e
    if [[ $rc -eq 124 ]]; then
        echo "TIME BUDGET REACHED: build tree kept in $B — re-run the workflow with resume=true to continue"; exit 3
    elif [[ $rc -ne 0 ]]; then
        grep -B2 -A25 -m3 "FAILED:" /tmp/ninja.log | head -120; echo "FAILED: WebKitGTK compile"; exit 1
    fi
    step "WebKitGTK: install"
    ninja install > /tmp/install.log 2>&1 || { tail -40 /tmp/install.log; echo "FAILED: install"; exit 1; }
    ldconfig
    cd /; rm -rf "$W"        # finished: drop the build tree so the stage artifact stays small
fi

cd /                         # never run the tests from a deleted build directory
step "smoke test"
for f in /usr/lib/libwebkit2gtk-4.1.so /usr/lib/libjavascriptcoregtk-4.1.so /usr/lib/girepository-1.0/WebKit2-4.1.typelib \
         /usr/lib/webkit2gtk-4.1/WebKitWebProcess /usr/lib/webkit2gtk-4.1/WebKitNetworkProcess; do
    [[ -e $f ]] || { echo "missing $f"; ls /usr/lib/webkit2gtk-4.1 2>/dev/null; exit 1; }
done
python3 - <<'PY'
import gi
gi.require_version("WebKit2", "4.1"); gi.require_version("JavaScriptCore", "4.1")
from gi.repository import WebKit2, JavaScriptCore
ctx = JavaScriptCore.Context()
val = ctx.evaluate("[1,2,3].map(x => x * 2).join(',') + ' ' + (typeof WebAssembly)", -1)
print("  WebKitGTK", WebKit2.get_major_version(), WebKit2.get_minor_version(), WebKit2.get_micro_version(),
      "| JavaScriptCore says:", val.to_string())
assert val.to_string() == "2,4,6 object"
PY
# render a real page offline in a real WebView on Xvfb (from stage 5c) and read the DOM back
if command -v Xvfb >/dev/null; then
    export DISPLAY=:11 XDG_RUNTIME_DIR=/tmp/xdg-wk; mkdir -p -m700 $XDG_RUNTIME_DIR
    # test only: a CI chroot cannot create the sandbox's namespaces and has no GPU (real ESO keeps both)
    export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 WEBKIT_DISABLE_DMABUF_RENDERER=1 LIBGL_ALWAYS_SOFTWARE=1
    Xvfb :11 -screen 0 1024x768x24 -nolisten tcp > /tmp/xvfb.log 2>&1 & XP=$!
    for i in $(seq 50); do [[ -S /tmp/.X11-unix/X11 ]] && break; sleep 0.2; done
    dbus-run-session -- python3 - <<'PY' || { kill $XP; echo "FAILED: WebView test"; exit 1; }
import gi, sys
gi.require_version("Gtk", "3.0"); gi.require_version("WebKit2", "4.1")
from gi.repository import Gtk, WebKit2, GLib
w = Gtk.Window(); v = WebKit2.WebView(); w.add(v); w.set_default_size(800, 600); w.show_all()
html = "<html><body><h1 id=t>ESO</h1><script>document.getElementById('t').textContent += ' Browser ' + (1+1);</script></body></html>"
res = {}
def done(obj, r):
    try:
        res["v"] = v.evaluate_javascript_finish(r).to_string()
    except Exception as e:
        res["v"] = "error: %s" % e
    Gtk.main_quit()
def loaded(view, ev):
    if ev == WebKit2.LoadEvent.FINISHED:
        v.evaluate_javascript("document.getElementById('t').textContent", -1, None, None, None, done)
v.connect("load-changed", loaded)
v.load_html(html, "about:blank")
GLib.timeout_add_seconds(60, lambda: (res.setdefault("v", "timeout"), Gtk.main_quit()))
Gtk.main()
print("  WebView rendered the page, DOM says:", res["v"])
sys.exit(0 if res["v"] == "ESO Browser 2" else 1)
PY
    kill $XP 2>/dev/null || true; rm -rf /tmp/xdg-wk /tmp/.X11-unix/X11 /tmp/.X11-lock
fi
step "stage 5f done"; du -sh /usr/lib /usr/share
