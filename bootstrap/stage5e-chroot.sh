#!/bin/bash
# ESO Base stage 5e, INSIDE the chroot: everything WebKitGTK (the ESO Browser engine) builds on.
#   text:     ICU (Unicode, line breaking, IDN), HarfBuzz rebuilt with ICU
#   web:      libxslt, nghttp2 (HTTP/2), glib-networking (TLS through OpenSSL + the system CA store), libsoup 3
#   formats:  libwebp, brotli + WOFF2 (web fonts), libavif (AVIF images, decoded with dav1d from stage 5d)
#   security: libgpg-error + libgcrypt, libtasn1, libsecret (saved passwords), libseccomp + bubblewrap +
#             xdg-dbus-proxy (WebKit's web-process sandbox)
#   storage:  SQLite (IndexedDB, cookies, history)
#   build:    gperf, Ruby (WebKit's code generators)
# All from upstream sources. No network inside the chroot: every source is a pinned download in sources-stage5e.list.
set -euo pipefail
. /sources/versions.env
step() { echo; echo "=== $* ($(date -u +%H:%M:%S)) ==="; }
unpack() { rm -rf "/sources/$1"; mkdir -p "/sources/$1"; tar -xf "/sources/$2" -C "/sources/$1" --strip-components=1; cd "/sources/$1"; }
declare -A PFX=([icu]=icu4c [libgpgerror]=libgpg-error [sqlite]=sqlite-autoconf [glibnetworking]=glib-networking
                [xdgdbusproxy]=xdg-dbus-proxy)
src() { local f; f=$(ls /sources/"${PFX[$1]:-$1}"-[0-9v]* 2>/dev/null | grep -E '\.(tar\.(xz|gz|bz2)|tgz)$' | head -1)
        [[ -n $f ]] || { echo "no source tarball for $1" >&2; ls /sources >&2; exit 1; }; basename "$f"; }
done_() { cd /sources; rm -rf "/sources/$1"; }
quiet() { "$@" > /tmp/build.log 2>&1 || { tail -80 /tmp/build.log; echo "FAILED: $*"; exit 1; }; }
ac() { local n=$1; shift; step "$n"; unpack "$n" "$(src "$n")"
       quiet ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --disable-static "$@"
       quiet make; quiet make install; done_ "$n"; }
ms() { local n=$1; shift; step "$n"; unpack "$n" "$(src "$n")"
       quiet meson setup build --prefix=/usr --buildtype=release -Dwrap_mode=nodownload "$@"
       quiet ninja -C build; quiet ninja -C build install; done_ "$n"; }
cm() { local n=$1; shift; step "$n"; unpack "$n" "$(src "$n")"
       quiet cmake -B build -G Ninja -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_POLICY_VERSION_MINIMUM=3.5 "$@"
       quiet ninja -C build; quiet ninja -C build install; done_ "$n"; }
export PKG_CONFIG_PATH=/usr/lib/pkgconfig:/usr/share/pkgconfig

# ───────────────────────────── build tools ─────────────────────────────
ac gperf
step "Ruby $V_ruby (only for WebKit's code generators)"; unpack ruby "$(src ruby)"
quiet ./configure --prefix=/usr --disable-install-doc --disable-install-rdoc --disable-yjit --enable-shared
quiet make; quiet make install; done_ ruby

# ───────────────────────────── text ─────────────────────────────
step "ICU $V_icu"; unpack icu "$(src icu)"
cd source
quiet ./configure --prefix=/usr --disable-static --disable-tests --disable-samples
quiet make; quiet make install; done_ icu
ms harfbuzz -Dtests=disabled -Ddocs=disabled -Dgobject=enabled -Dintrospection=enabled -Dfreetype=enabled \
   -Dglib=enabled -Dcairo=disabled -Dicu=enabled -Dutilities=disabled

# ───────────────────────────── crypto, storage ─────────────────────────────
ac libgpgerror --disable-doc --disable-tests
ac libgcrypt --disable-doc
ac libtasn1 --disable-doc
step "SQLite $V_sqlite"; unpack sqlite "$(src sqlite)"
# legacy soname (libsqlite3.so.0) like every distro; the functions browsers and Python expect
quiet ./configure --prefix=/usr --disable-static --soname=legacy --fts5 --rtree \
    CFLAGS="-O2 -DSQLITE_ENABLE_COLUMN_METADATA=1 -DSQLITE_ENABLE_UNLOCK_NOTIFY=1 -DSQLITE_ENABLE_DBSTAT_VTAB=1 -DSQLITE_SECURE_DELETE=1"
quiet make; quiet make install; done_ sqlite

# ───────────────────────────── formats ─────────────────────────────
ac libxslt --without-python
ac libwebp --enable-libwebpmux --enable-libwebpdemux --enable-libwebpdecoder --disable-sdl --disable-gl \
    --disable-png --disable-jpeg --disable-tiff --disable-gif --disable-wic
cm brotli -DBROTLI_DISABLE_TESTS=ON
cm woff2 -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_CXX_FLAGS="-O2 -include cstdint"
cm libavif -DAVIF_CODEC_DAV1D=SYSTEM -DAVIF_LIBYUV=OFF -DAVIF_LIBSHARPYUV=OFF -DAVIF_BUILD_APPS=OFF \
    -DAVIF_BUILD_TESTS=OFF -DAVIF_BUILD_EXAMPLES=OFF -DAVIF_BUILD_MAN_PAGES=OFF

# ───────────────────────────── HTTP + TLS ─────────────────────────────
ac nghttp2 --enable-lib-only
ms glibnetworking -Dgnutls=disabled -Dopenssl=enabled -Dlibproxy=disabled -Dgnome_proxy=disabled \
    -Denvironment_proxy=enabled -Dtests=false -Dinstalled_tests=false
gio-querymodules /usr/lib/gio/modules
ms libsoup -Dintrospection=enabled -Dvapi=disabled -Ddocs=disabled -Dtests=false -Dinstalled_tests=false \
    -Dgssapi=disabled -Dntlm=disabled -Dbrotli=enabled -Dzstd=enabled -Dsysprof=disabled -Dautobahn=disabled \
    -Dpkcs11_tests=disabled -Dfuzzing=disabled
ms libsecret -Dcrypto=libgcrypt -Dmanpage=false -Dgtk_doc=false -Dvapi=false -Dintrospection=true \
    -Dbash_completion=disabled -Dtpm2=false -Dpam=false

# ───────────────────────────── web-process sandbox ─────────────────────────────
ac libseccomp
ms bubblewrap -Dman=disabled -Dselinux=disabled -Dtests=false -Dbash_completion=disabled -Dzsh_completion=disabled
ms xdgdbusproxy -Dman=disabled -Dtests=false
ldconfig

# ───────────────────────────── smoke test ─────────────────────────────
step "smoke test"
for t in "ruby --version" "gperf --version" "bwrap --version" "xdg-dbus-proxy --help" "sqlite3 --version" "uconv --version"; do
    printf '  %-16s ' "${t%% *}"; $t > /tmp/v.txt 2>&1 || { cat /tmp/v.txt; echo "FAILED: $t"; exit 1; }; head -1 /tmp/v.txt
done
for pc in icu-uc icu-i18n harfbuzz-icu libxslt libwebp libwebpdemux libbrotlidec libwoff2dec libavif libgcrypt \
          libtasn1 sqlite3 libnghttp2 libsoup-3.0 libsecret-1 libseccomp; do
    pkg-config --exists $pc || { echo "missing $pc.pc"; exit 1; }
done; echo "  pkg-config: every WebKitGTK dependency is present"
python3 - <<'PY'
import gi
gi.require_version("Soup", "3.0"); gi.require_version("Secret", "1")
from gi.repository import Soup, Gio, GLib, Secret
# TLS works offline? glib-networking must be loaded as GIO's TLS backend (no network needed for this check)
backend = Gio.TlsBackend.get_default()
assert backend.supports_tls(), "no TLS backend: glib-networking was not picked up"
db = backend.get_default_database()
print("  libsoup", Soup.get_major_version(), Soup.get_minor_version(), Soup.get_micro_version(),
      "| TLS backend:", type(backend).__name__, "| system CA database loaded:", db is not None)
PY
# GStreamer's soup plugin (built in 5d) finds libsoup 3 at runtime: online video/audio streams now work
rm -rf /root/.cache/gstreamer-1.0
gst-inspect-1.0 souphttpsrc >/dev/null 2>&1 && echo "  GStreamer souphttpsrc: ok" || echo "  note: souphttpsrc not registered (GStreamer streams will use other sources)"
step "stage 5e done"; du -sh /usr/lib /usr/share
