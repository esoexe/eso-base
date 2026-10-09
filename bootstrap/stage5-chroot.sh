#!/bin/bash
# ESO Base stage 5, INSIDE the chroot: the GTK 3 stack the ESO apps run on.  GLib + GObject introspection, image
# loaders, HarfBuzz/FriBidi (Arabic shaping and right-to-left text), Cairo, Pango, accessibility, librsvg (SVG
# icons), GTK 3, icon themes, PyGObject/pycairo (the ESO apps are Python + GTK), GtkSourceView 4 (Ilyass), VTE
# (terminal) and libnotify.  All from upstream sources; Rust comes from rust-lang.org's own release.
set -euo pipefail
. /sources/versions.env
step() { echo; echo "=== $* ($(date -u +%H:%M:%S)) ==="; }
unpack() { rm -rf "/sources/$1"; mkdir -p "/sources/$1"; tar -xf "/sources/$2" -C "/sources/$1" --strip-components=1; cd "/sources/$1"; }
declare -A PFX=([gobjectintrospection]=gobject-introspection [libjpegturbo]=libjpeg-turbo [gdkpixbuf]=gdk-pixbuf
                [atspi2core]=at-spi2-core [gtk3]=gtk [hicolor]=hicolor-icon-theme [adwaitaicons]=adwaita-icon-theme
                [gtksourceview4]=gtksourceview [gsettingsschemas]=gsettings-desktop-schemas)
src() { local f; f=$(ls /sources/"${PFX[$1]:-$1}"-[0-9]* 2>/dev/null | grep -E '\.(tar\.(xz|gz|bz2)|tgz)$' | head -1)
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

ac pcre2 --enable-unicode --enable-jit --enable-pcre2-16 --enable-pcre2-32 --enable-pcre2grep-libz
ms glib -Dintrospection=disabled -Dman-pages=disabled -Dtests=false -Dsysprof=disabled -Dglib_debug=disabled
ms gobjectintrospection
ms glib -Dintrospection=enabled -Dman-pages=disabled -Dtests=false -Dsysprof=disabled -Dglib_debug=disabled

# file-type database (GIO content types for the ESO file manager; gdk-pixbuf needs it). Its test suite would
# pull xdgmime over git, so tests and the HTML spec are off.
ms sharedmimeinfo -Dbuild-tests=false -Dbuild-spec=false -Dupdate-mimedb=true

cm libjpegturbo -DENABLE_STATIC=FALSE -DCMAKE_INSTALL_DEFAULT_LIBDIR=lib
cm tiff -Dtiff-docs=OFF -Dtiff-tests=OFF -Dtiff-contrib=OFF -Dtiff-tools=OFF
ms gdkpixbuf -Dman=false -Dothers=enabled -Dtests=false -Dinstalled_tests=false -Dgtk_doc=false -Dintrospection=enabled
gdk-pixbuf-query-loaders --update-cache

ms fribidi -Ddocs=false -Dtests=false
ms harfbuzz -Dtests=disabled -Ddocs=disabled -Dgobject=enabled -Dintrospection=enabled -Dfreetype=enabled \
   -Dglib=enabled -Dcairo=disabled -Dicu=disabled -Dutilities=disabled
ms cairo -Dtests=disabled -Dxlib=enabled -Dxcb=enabled -Dfreetype=enabled -Dfontconfig=enabled -Dglib=enabled
ms pango -Dintrospection=enabled -Ddocumentation=false -Dbuild-testsuite=false -Dbuild-examples=false -Dman-pages=false
ms atspi2core -Dintrospection=enabled -Ddocs=false -Duse_systemd=true -Dx11=enabled

step "Rust $V_rust (rust-lang.org release, needed to build librsvg)"
unpack rust "rust-$V_rust-x86_64-unknown-linux-gnu.tar.xz"
quiet ./install.sh --prefix=/opt/rust --components=rustc,cargo,rust-std-x86_64-unknown-linux-gnu --disable-ldconfig
done_ rust
export PATH=/opt/rust/bin:$PATH
step "librsvg (Rust crates vendored on the host from its Cargo.lock; cargo builds offline)"
unpack librsvg "$(src librsvg)"
tar -xf /sources/librsvg-vendor.tar
mkdir -p .cargo
printf '[source.crates-io]\nreplace-with = "vendored-sources"\n\n[source.vendored-sources]\ndirectory = "vendor"\n\n[net]\noffline = true\n' > .cargo/config.toml
quiet ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --disable-static --disable-gtk-doc \
    --enable-introspection --disable-vala
quiet make; quiet make install; done_ librsvg
gdk-pixbuf-query-loaders --update-cache

ms gtk3 -Dintrospection=true -Dx11_backend=true -Dwayland_backend=true -Dbroadway_backend=false -Dexamples=false \
   -Dtests=false -Ddemos=false -Dman=false -Dgtk_doc=false -Dcolord=no -Dcloudproviders=false -Dtracker3=false \
   -Dprint_backends=file
ms hicolor
ms adwaitaicons
gtk-update-icon-cache -qtf /usr/share/icons/hicolor || true
gtk-update-icon-cache -qtf /usr/share/icons/Adwaita || true

ms pycairo -Dtests=false
ms pygobject -Dtests=false -Dpycairo=enabled
ms gtksourceview4 -Dvapi=false -Dgtk_doc=false -Dinstall_tests=false -Dgir=true
step "vte $V_vte (terminal) with its fast_float, fmt and simdutf helpers from pinned sources (no git, no download)"
unpack vte "$(src vte)"
for h in fastfloat:fast_float fmt:fmt simdutf:simdutf; do
    n=${h%%:*}; d=subprojects/${h#*:}; rm -rf "$d"; mkdir -p "$d"
    tar -xf "$(ls /sources/$n-*.tar.gz | head -1)" -C "$d" --strip-components=1
    cp -a "subprojects/packagefiles/${h#*:}/." "$d/"      # vte's meson.build overlay (normally applied by the wrap)
done
quiet meson setup build --prefix=/usr --buildtype=release -Dwrap_mode=nodownload -Dgtk3=true -Dgtk4=false -Dgir=true -Dvapi=false \
    -Dgnutls=false -Ddocs=false -D_systemd=true -Dicu=false
quiet ninja -C build; quiet ninja -C build install; done_ vte
ms libnotify -Dtests=false -Dintrospection=enabled -Dman=false -Dgtk_doc=false -Ddocbook_docs=disabled
ms gsettingsschemas
glib-compile-schemas /usr/share/glib-2.0/schemas

step "smoke test: GTK/GtkSource/VTE import + Arabic text shaped by HarfBuzz/Pango into an image (no display needed)"
python3 - <<'PY'
import gi
gi.require_version("Gtk", "3.0"); gi.require_version("GtkSource", "4"); gi.require_version("Vte", "2.91")
gi.require_version("PangoCairo", "1.0")
from gi.repository import Gtk, GtkSource, Vte, Pango, PangoCairo
import cairo
s = cairo.ImageSurface(cairo.FORMAT_ARGB32, 600, 80); cr = cairo.Context(s)
lay = PangoCairo.create_layout(cr); lay.set_font_description(Pango.FontDescription("DejaVu Sans 20"))
lay.set_text("ESO OS \u2014 \u0623\u0647\u0644\u0627 \u2014 Bonjour", -1); PangoCairo.show_layout(cr, lay)
s.write_to_png("/root/eso-text.png"); w, h = lay.get_pixel_size()
buf = GtkSource.Buffer(); buf.set_language(GtkSource.LanguageManager.get_default().get_language("python3"))
print("GTK %d.%d.%d | Pango %s | text %dx%d px | GtkSource python3: %s | VTE %d.%d" % (Gtk.get_major_version(),
      Gtk.get_minor_version(), Gtk.get_micro_version(), Pango.version_string(), w, h, bool(buf.get_language()),
      Vte.get_major_version(), Vte.get_minor_version()))
PY
step "stage 5 done"; du -sh /usr/lib /usr/share
