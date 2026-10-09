#!/bin/bash
# ESO Base stage 5c, INSIDE the chroot: the ESO desktop session.
#   X server:  X.Org 21.1 (modesetting + glamor on every KMS GPU, rootless through logind, Xvfb for tests),
#              libinput input driver, xinit/startx, xauth, the small X tools the session calls
#              (xrandr, xset, xsetroot, xrdb, xprop, xdpyinfo, setxkbmap)
#   windows:   xfwm4 (title bars, minimize/maximize/close, snapping) with libxfce4util, xfconf, libxfce4ui, libwnck
#   keys etc:  sxhkd (shortcuts), eso-supertap (a lone tap of the Windows key opens Start), dunst (notifications),
#              xsettingsd, xclip, xdotool, wmctrl, xprintidle
#   fonts:     Inter (interface), Amiri (Arabic + Quran), Noto Color Emoji
# All from upstream sources. No network inside the chroot: every source is a pinned download in sources-stage5c.list.
set -euo pipefail
. /sources/versions.env
step() { echo; echo "=== $* ($(date -u +%H:%M:%S)) ==="; }
unpack() { rm -rf "/sources/$1"; mkdir -p "/sources/$1"; tar -xf "/sources/$2" -C "/sources/$1" --strip-components=1; cd "/sources/$1"; }
declare -A PFX=([xcbutil]=xcb-util [xcbutilkeysyms]=xcb-util-keysyms [xcbutilwm]=xcb-util-wm [xcbutilimage]=xcb-util-image
                [xcbutilrenderutil]=xcb-util-renderutil [xorgserver]=xorg-server [fontutil]=font-util [xf86inputlibinput]=xf86-input-libinput
                [startupnotification]=startup-notification)
src() { local f; f=$(ls /sources/"${PFX[$1]:-$1}"-[0-9v]* 2>/dev/null | grep -E '\.(tar\.(xz|gz|bz2)|tgz)$' | head -1)
        [[ -n $f ]] || { echo "no source tarball for $1" >&2; exit 1; }; basename "$f"; }
done_() { cd /sources; rm -rf "/sources/$1"; }
quiet() { "$@" > /tmp/build.log 2>&1 || { tail -80 /tmp/build.log; echo "FAILED: $*"; exit 1; }; }
ac() { local n=$1; shift; step "$n"; unpack "$n" "$(src "$n")"
       quiet ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --disable-static "$@"
       quiet make; quiet make install; done_ "$n"; }
ms() { local n=$1; shift; step "$n"; unpack "$n" "$(src "$n")"
       quiet meson setup build --prefix=/usr --buildtype=release -Dwrap_mode=nodownload "$@"
       quiet ninja -C build; quiet ninja -C build install; done_ "$n"; }
cm() { local n=$1; shift; step "$n"; unpack "$n" "$(src "$n")"
       quiet cmake -B build -G Ninja -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_LIBDIR=lib "$@"
       quiet ninja -C build; quiet ninja -C build install; done_ "$n"; }
export PKG_CONFIG_PATH=/usr/lib/pkgconfig:/usr/share/pkgconfig

# ───────────────────────────── X libraries ─────────────────────────────
ac libICE
ac libSM
ac libXt --with-appdefaultdir=/etc/X11/app-defaults
ac libXmu
ac libXpm --disable-open-zfile
ac libXres
ac libXScrnSaver
ac libXft
ac libXpresent
ac xcbutil
ac xcbutilkeysyms
ac xcbutilwm
ac xcbutilimage
ac xcbutilrenderutil
ac xbitmaps

# ───────────────────────────── X server ─────────────────────────────
# Default font path left alone on purpose: it keeps the server's built-in "fixed" font (no core font packages needed).
ac fontutil
ms xorgserver -Dxorg=true -Dxvfb=true -Dxephyr=false -Dxnest=false -Dxwin=false -Dxquartz=false \
    -Dglamor=true -Dglx=true -Ddri3=true -Dsecure-rpc=false -Dsha1=libcrypto -Dudev=true -Dudev_kms=true \
    -Dsystemd_logind=true -Dsuid_wrapper=true -Dhal=false -Dxselinux=false -Dint10=false -Dlinux_apm=false \
    -Dxkb_output_dir=/var/lib/xkb -Dlog_dir=/var/log -Ddocs=false -Ddevel-docs=false -Ddocs-pdf=false \
    -Dvendor_name="ESO OS" -Dvendor_name_short=ESO -Dvendor_web=https://esoos.dpdns.org
mkdir -p /var/lib/xkb /etc/X11/xorg.conf.d
ac xf86inputlibinput --with-xorg-module-dir=/usr/lib/xorg/modules
ac xinit --with-xinitdir=/etc/X11/xinit
ac xauth
ac xrandr
ac xset
ac xsetroot
ac xrdb --with-cpp=/usr/bin/cpp
ac xprop
ac xdpyinfo
ac setxkbmap

cat > /etc/X11/Xwrapper.config <<'EOF'
# Xorg runs as the user through logind; the wrapper only gives root rights when a driver really needs them.
allowed_users=anybody
needs_root_rights=auto
EOF
cat > /etc/X11/xorg.conf.d/30-eso-touchpad.conf <<'EOF'
# ESO: touchpads work like people expect — tap to click, two-finger scroll, no stray clicks while typing.
Section "InputClass"
    Identifier "ESO touchpad"
    MatchIsTouchpad "on"
    Driver "libinput"
    Option "Tapping" "on"
    Option "TappingDrag" "on"
    Option "ScrollMethod" "twofinger"
    Option "DisableWhileTyping" "on"
    Option "MiddleEmulation" "on"
EndSection
EOF

# ───────────────────────────── window manager: xfwm4 ─────────────────────────────
ac startupnotification
ms libwnck -Dintrospection=enabled -Dstartup_notification=enabled -Dinstall_tools=false -Dgtk_doc=false
ac libxfce4util --disable-debug --enable-introspection --enable-vala=no
ac xfconf --disable-debug --enable-introspection --enable-vala=no --disable-gsettings-backend
ac libxfce4ui --disable-debug --enable-introspection --enable-vala=no --enable-x11 --disable-wayland \
    --enable-libsm --enable-startup-notification --disable-glibtop --enable-epoxy --enable-gudev \
    --disable-gladeui2 --disable-tests --with-vendor-info="ESO OS"
ac xfwm4 --disable-debug --enable-epoxy --enable-startup-notification --enable-xsync --enable-render \
    --enable-randr --enable-xpresent --enable-compositor --enable-xi2

# ───────────────────────────── keys, notifications, small tools ─────────────────────────────
step "sxhkd"; unpack sxhkd "$(src sxhkd)"
quiet make PREFIX=/usr; quiet make PREFIX=/usr install; done_ sxhkd

step "eso-supertap (lone Windows-key tap = Start; replaces xcape, whose upstream is gone)"
gcc -O2 -Wall -o /usr/bin/eso-supertap /sources/files/eso-supertap.c -lX11 -lXtst
ln -sfn eso-supertap /usr/bin/xcape        # ESO sessions call "xcape -t 300 -e ..." — same command line

ms dunst -Dwayland=disabled -Dx11=enabled -Ddunstify=enabled -Dsystemd=enabled -Ddocs=disabled -Dcompletions=false
cm xsettingsd -DBUILD_TESTING=OFF

step "xclip"; unpack xclip "$(src xclip)"
quiet autoreconf -fi; quiet ./configure --prefix=/usr; quiet make; quiet make install; done_ xclip

step "xdotool"; unpack xdotool "$(src xdotool)"
quiet make PREFIX=/usr INSTALLMAN=/usr/share/man WITHOUT_RPATH_FIX=1
quiet make PREFIX=/usr INSTALLMAN=/usr/share/man WITHOUT_RPATH_FIX=1 install; done_ xdotool

ms xprintidle

step "wmctrl $V_wmctrl"; unpack wmctrl "$(src wmctrl)"
# the 2009 configure script predates current compilers; the program is one C file
gcc -O2 -DVERSION="\"$V_wmctrl\"" -o /usr/bin/wmctrl main.c $(pkg-config --cflags --libs glib-2.0 x11 xmu)
install -Dm644 wmctrl.1 /usr/share/man/man1/wmctrl.1; done_ wmctrl

# ───────────────────────────── fonts ─────────────────────────────
step "fonts: Inter $V_inter, Amiri $V_amiri, Noto Color Emoji"
V_inter=$V_inter V_amiri=$V_amiri python3 - <<'PY'
import zipfile, os, shutil
def take(zipname, dest, pick):
    os.makedirs(dest, exist_ok=True)
    z = zipfile.ZipFile("/sources/" + zipname)
    for n in z.namelist():
        b = os.path.basename(n)
        if b in pick:
            with z.open(n) as s, open(os.path.join(dest, b), "wb") as d: shutil.copyfileobj(s, d)
            pick.discard(b)
    assert not pick, f"{zipname}: missing {pick}"
take(f"Inter-{os.environ.get('V_inter','4.1')}.zip", "/usr/share/fonts/inter", {"InterVariable.ttf", "InterVariable-Italic.ttf"})
take(f"Amiri-{os.environ.get('V_amiri','1.003')}.zip", "/usr/share/fonts/amiri",
     {"Amiri-Regular.ttf", "Amiri-Bold.ttf", "Amiri-Italic.ttf", "Amiri-BoldItalic.ttf", "AmiriQuran.ttf"})
PY
install -Dm644 /sources/NotoColorEmoji.ttf /usr/share/fonts/noto/NotoColorEmoji.ttf
cat > /etc/fonts/local.conf <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<!-- ESO: Inter for the interface, Amiri for Arabic, DejaVu Sans Mono for code, Noto Color Emoji everywhere -->
<fontconfig>
  <alias><family>sans-serif</family><prefer><family>Inter Variable</family><family>Inter</family><family>Amiri</family><family>Noto Color Emoji</family><family>DejaVu Sans</family></prefer></alias>
  <alias><family>serif</family><prefer><family>Amiri</family><family>DejaVu Serif</family><family>Noto Color Emoji</family></prefer></alias>
  <alias><family>monospace</family><prefer><family>DejaVu Sans Mono</family><family>Noto Color Emoji</family></prefer></alias>
  <alias><family>emoji</family><prefer><family>Noto Color Emoji</family></prefer></alias>
  <match target="pattern"><test name="lang" compare="contains"><string>ar</string></test>
    <edit name="family" mode="prepend"><string>Amiri</string></edit></match>
</fontconfig>
EOF
fc-cache -f >/dev/null
ldconfig

# ───────────────────────────── smoke test: a real ESO-style session on Xvfb ─────────────────────────────
step "smoke test"
for t in "Xorg -version" "sxhkd -v" "dunst -v" "xdotool version" "xclip -version"; do
    printf '  %-10s ' "${t%% *}"; $t > /tmp/v.txt 2>&1 || { cat /tmp/v.txt; echo "FAILED: $t"; exit 1; }
    grep -m1 -iE 'x\.org x server|[0-9]+\.[0-9]' /tmp/v.txt || head -1 /tmp/v.txt
done
for f in /usr/lib/xorg/modules/drivers/modesetting_drv.so /usr/lib/xorg/modules/input/libinput_drv.so \
         /usr/lib/xorg/modules/libglamoregl.so /usr/libexec/Xorg.wrap /usr/bin/Xorg /usr/bin/startx /usr/bin/wmctrl /usr/bin/xprintidle \
         /usr/bin/xsettingsd /usr/bin/eso-supertap; do [[ -e $f ]] || { echo "missing $f"; exit 1; }; done
fc-list | grep -q "Inter" && fc-list | grep -q "Amiri" && fc-list | grep -q "Noto Color Emoji" || { echo "fonts missing"; exit 1; }
echo "  fonts: $(fc-match sans-serif) | $(fc-match :lang=ar) | $(fc-match emoji)"

export DISPLAY=:9 XDG_RUNTIME_DIR=/tmp/xdg-smoke; mkdir -p -m700 $XDG_RUNTIME_DIR
Xvfb :9 -screen 0 1280x800x24 -nolisten tcp > /tmp/xvfb.log 2>&1 &
XPID=$!
for i in $(seq 50); do [[ -S /tmp/.X11-unix/X9 ]] && break; sleep 0.2; done
[[ -S /tmp/.X11-unix/X9 ]] || { cat /tmp/xvfb.log; echo "Xvfb did not start"; exit 1; }
cat > /tmp/session-test.sh <<'EOF'
set -e
xfwm4 --compositor=off --sm-client-disable > /tmp/xfwm4.log 2>&1 &
for i in $(seq 50); do wmctrl -m > /tmp/wm.txt 2>/dev/null && break; sleep 0.2; done
grep -q "Name: Xfwm4" /tmp/wm.txt || { cat /tmp/wm.txt /tmp/xfwm4.log; echo "xfwm4 did not take over"; exit 1; }
echo "  window manager: $(head -1 /tmp/wm.txt)"
dunst > /tmp/dunst.log 2>&1 &
eso-supertap -t 300 > /tmp/tap.log 2>&1 &
python3 - <<'PY' &
import gi; gi.require_version("Gtk", "3.0"); from gi.repository import Gtk, GLib
w = Gtk.Window(title="ESO smoke test"); w.add(Gtk.Label(label="ESO Base  مرحبا  😀")); w.show_all()
GLib.timeout_add_seconds(20, Gtk.main_quit); Gtk.main()
PY
for i in $(seq 50); do wmctrl -l | grep -q "ESO smoke test" && break; sleep 0.2; done
wmctrl -l | grep -q "ESO smoke test" || { echo "GTK window never got managed"; exit 1; }
W=$(xdotool search --name "ESO smoke test" | head -1)
wmctrl -i -r "$W" -b add,maximized_vert,maximized_horz; sleep 0.5
xprop -id "$W" _NET_WM_STATE | grep -q MAXIMIZED_HORZ || { echo "maximize did not work"; exit 1; }
echo "  GTK window managed and maximized by xfwm4 (id $W)"
notify-send "ESO" "notification test"; sleep 1
grep -qi error /tmp/dunst.log && { cat /tmp/dunst.log; echo "dunst reported an error"; exit 1; }
echo "  dunst running, notification sent; idle seconds: $(xprintidle) ms"
xdotool key Super_L; sleep 0.3
echo "  xfwm4: $(xfwm4 --version 2>/dev/null | head -1)"
echo "  xrandr: $(xrandr | head -1)"
EOF
dbus-run-session -- bash /tmp/session-test.sh || { echo "FAILED: session test"; kill $XPID; exit 1; }
kill $XPID 2>/dev/null || true
rm -rf /tmp/xdg-smoke /tmp/.X11-unix/X9 /tmp/.X9-lock
step "stage 5c done"; du -sh /usr/lib /usr/share
