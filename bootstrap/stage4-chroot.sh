#!/bin/bash
# ESO Base stage 4, INSIDE the chroot: graphics.  X11 client libraries, Wayland, fonts, libdrm, Mesa (OpenGL/EGL/GBM),
# libinput, seatd and Xwayland, all from upstream sources.  Mesa pass 1 has no LLVM: older Intel (crocus/i915),
# NVIDIA open (nouveau), virtual machines (virgl, VMware/VirtualBox svga) and softpipe.  Stage 4b adds LLVM+Clang (iris needs CLC), AMD
# (radeonsi) and the fast software renderer (llvmpipe).
set -euo pipefail
. /sources/versions.env
step() { echo; echo "=== $* ($(date -u +%H:%M:%S)) ==="; }
unpack() { rm -rf "/sources/$1"; mkdir -p "/sources/$1"; tar -xf "/sources/$2" -C "/sources/$1" --strip-components=1; cd "/sources/$1"; }
declare -A PFX=([utilmacros]=util-macros [xkeyboardconfig]=xkeyboard-config [waylandprotocols]=wayland-protocols
                [libxkbcommon]=xkbcommon [xcbproto]=xcb-proto [libxxf86vm]=libXxf86vm)
src() {  # tarball of a package (its file name may differ from the package name)
    local f; f=$(ls /sources/"${PFX[$1]:-$1}"-[0-9]* 2>/dev/null | grep -E '\.(tar\.(xz|gz|bz2)|tgz)$' | head -1)
    [[ -n $f ]] || { echo "no source tarball for $1" >&2; exit 1; }; echo "$f"
}
done_() { cd /sources; rm -rf "/sources/$1"; }
quiet() { "$@" > /tmp/build.log 2>&1 || { tail -80 /tmp/build.log; echo "FAILED: $*"; exit 1; }; }
XC="--prefix=/usr --sysconfdir=/etc --localstatedir=/var --disable-static"
ac() {  # name [configure args]  (autotools)
    local n=$1; shift; step "$n"; unpack "$n" "$(basename "$(src "$n")")"
    quiet ./configure $XC "$@"; quiet make; quiet make install; done_ "$n"
}
ms() {  # name [meson args]
    local n=$1; shift; step "$n"; unpack "$n" "$(basename "$(src "$n")")"
    quiet meson setup build --prefix=/usr --buildtype=release -Dwrap_mode=nodownload "$@"
    quiet ninja -C build; quiet ninja -C build install; done_ "$n"
}
pyw() {  # name import-name
    step "python: $1"; unpack "$1" "$(basename "$(src "$1")")"
    quiet pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps "$PWD"
    quiet pip3 install --no-index --find-links dist --no-deps "$2"; done_ "$1"
}
export PKG_CONFIG_PATH=/usr/lib/pkgconfig:/usr/share/pkgconfig

# ── X11 protocol + client libraries ──
ac utilmacros
ms xorgproto -Dlegacy=false
ac libXau
ac libXdmcp
step "xcb-proto"; unpack xcbproto "xcb-proto-$V_xcbproto.tar.xz"; quiet ./configure $XC; quiet make install; done_ xcbproto
step "libxcb"; unpack libxcb "libxcb-$V_libxcb.tar.xz"; quiet ./configure $XC --without-doxygen; quiet make; quiet make install; done_ libxcb
ac xtrans
ac libX11
ac libXext
ac libXfixes
ac libXrender
ac libXrandr
ac libXi
ac libXcursor
ac libXinerama
ac libXdamage
ac libXcomposite
ac libXtst
ac libxshmfence
ac libxkbfile
ms libxcvt
ac libfontenc
step "libXxf86vm"; unpack libxxf86vm "libXxf86vm-$V_libxxf86vm.tar.xz"; quiet ./configure $XC; quiet make; quiet make install
done_ libxxf86vm

# ── fonts and 2D ──
ac libpng
ac freetype --enable-freetype-config --without-harfbuzz --without-brotli
ac fontconfig --disable-docs
ac libXfont2 --disable-devel-docs
ms pixman -Dtests=disabled -Ddemos=disabled
step "DejaVu fonts"; unpack dejavu "dejavu-fonts-ttf-$V_dejavu.tar.bz2"
install -d /usr/share/fonts/dejavu; install -m644 ttf/*.ttf /usr/share/fonts/dejavu/
cp fontconfig/*.conf /usr/share/fontconfig/conf.avail/ 2>/dev/null || true; done_ dejavu
fc-cache -f >/dev/null 2>&1 || true

# ── kernel graphics + Wayland ──
ms libpciaccess
ms libdrm -Dudev=true -Dvalgrind=disabled -Dtests=false -Dman-pages=disabled -Dcairo-tests=disabled
ac libxml2 --without-python --with-history --docdir=/usr/share/doc/libxml2
ms wayland -Ddocumentation=false -Dtests=false
ms waylandprotocols -Dtests=false
step "libxkbcommon"; unpack libxkbcommon "$(basename "$(src libxkbcommon)")"
quiet meson setup build --prefix=/usr --buildtype=release -Denable-docs=false -Denable-xkbregistry=false \
    -Denable-bash-completion=false -Denable-tools=true
quiet ninja -C build; quiet ninja -C build install; done_ libxkbcommon
ms xkeyboardconfig
ac xkbcomp

# ── Mesa ──
pyw mako mako
pyw pyyaml PyYAML
step "Mesa $V_mesa (pass 1, no LLVM: crocus, i915, nouveau, virgl, svga, softpipe)"
unpack mesa "mesa-$V_mesa.tar.xz"
quiet meson setup build --prefix=/usr --buildtype=release -Dwrap_mode=nodownload \
    -Dplatforms=x11,wayland -Dgallium-drivers=crocus,i915,nouveau,virgl,svga,softpipe -Dvulkan-drivers= \
    -Dllvm=disabled -Dglx=dri -Degl=enabled -Dgbm=enabled -Dgles1=disabled -Dgles2=enabled -Dglvnd=disabled \
    -Dvalgrind=disabled -Dlibunwind=disabled -Dintel-rt=disabled -Dvideo-codecs=
quiet ninja -C build; quiet ninja -C build install; done_ mesa

ms libepoxy -Ddocs=false -Dtests=false
ac mtdev
ms libevdev -Dtests=disabled -Ddocumentation=disabled
ms libinput -Dlibwacom=false -Ddebug-gui=false -Dtests=false -Ddocumentation=false
ms seatd -Dlibseat-logind=systemd -Dserver=enabled -Dexamples=disabled -Dman-pages=disabled
ms xwayland -Dxvfb=false -Dsecure-rpc=false -Dglamor=true -Ddri3=true -Dsha1=libcrypto -Dlibdecor=false \
    -Dxwayland_eglstream=false -Ddocs=false -Dxselinux=false

# ── proof: OpenGL renders inside ESO Base (EGL surfaceless + softpipe, no GPU needed) ──
step "smoke test: EGL + OpenGL ES on ESO's Mesa"
cat > /tmp/gltest.c <<'C'
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <stdio.h>
int main(void) {
    PFNEGLGETPLATFORMDISPLAYEXTPROC gpd = (void *)eglGetProcAddress("eglGetPlatformDisplayEXT");
    EGLDisplay d = gpd(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
    EGLint ma, mi; if (!eglInitialize(d, &ma, &mi)) { puts("eglInitialize failed"); return 1; }
    eglBindAPI(EGL_OPENGL_ES_API);
    EGLint ca[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
    EGLContext c = eglCreateContext(d, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, ca);
    if (!c || !eglMakeCurrent(d, EGL_NO_SURFACE, EGL_NO_SURFACE, c)) { puts("context failed"); return 1; }
    printf("EGL %d.%d  vendor: %s\nGL renderer: %s\nGL version: %s\n", ma, mi, eglQueryString(d, EGL_VENDOR),
           glGetString(GL_RENDERER), glGetString(GL_VERSION));
    return 0;
}
C
gcc /tmp/gltest.c -o /tmp/gltest -lEGL -lGLESv2
LIBGL_ALWAYS_SOFTWARE=1 /tmp/gltest
rm -f /tmp/gltest /tmp/gltest.c
Xwayland -version 2>&1 | head -2 || true
fc-list | wc -l | sed 's/^/fonts: /'
step "stage 4 done"
du -sh /usr/lib /usr/share 2>/dev/null || true
