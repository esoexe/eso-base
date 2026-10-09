#!/bin/bash
# ESO Base stage 6a, INSIDE the chroot: the system apps the ESO desktop calls.
#   trust:    GnuPG (gpgv checks the signature on every ESO update) + npth, libassuan, libksba
#   shell:    zsh + zsh-autosuggestions + zsh-syntax-highlighting (ESO Terminal's shell), jq, fastfetch, btop
#   desktop:  poppler with GObject bindings (PDF viewing in ESO apps), polkit-gnome (password prompts for admin
#             actions, started by eso-polkit), plymouth (animated boot), mesa-demos (glxinfo/eglinfo for
#             eso-hwdetect and the performance tuning)
#   python:   python-xlib (+ six), openpyxl (+ et_xmlfile) for ESO Sheets, cffi (+ pycparser) for offline speech
# All from upstream sources. No network inside the chroot: every source is a pinned download in sources-stage6a.list.
set -euo pipefail
. /sources/versions.env
step() { echo; echo "=== $* ($(date -u +%H:%M:%S)) ==="; }
unpack() { rm -rf "/sources/$1"; mkdir -p "/sources/$1"; tar -xf "/sources/$2" -C "/sources/$1" --strip-components=1; cd "/sources/$1"; }
declare -A PFX=([mesademos]=mesa-demos [polkitgnome]=polkit-gnome [pythonxlib]=python-xlib [etxmlfile]=et_xmlfile)
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
       quiet cmake -B build -G Ninja -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_LIBDIR=lib "$@"
       quiet ninja -C build; quiet ninja -C build install; done_ "$n"; }
pyw() { local n=$1; step "python: $n"; unpack "$n" "$(src "$n")"
        quiet pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps "$PWD"
        quiet pip3 install --no-index --no-deps dist/*.whl; done_ "$n"; }
export PKG_CONFIG_PATH=/usr/lib/pkgconfig:/usr/share/pkgconfig

# ───────────────────────────── trust: GnuPG ─────────────────────────────
ac npth
ac libassuan
ac libksba
# only what ESO needs: gpg + gpgv + gpg-agent; no LDAP/TLS key-server client, no smart cards, no docs
ac gnupg --disable-ldap --disable-gnutls --disable-ntbtls --disable-scdaemon --disable-doc --disable-wks-tools \
         --disable-tests

# ───────────────────────────── shell ─────────────────────────────
step "zsh $V_zsh"; unpack zsh "$(src zsh)"
quiet ./configure --prefix=/usr --sysconfdir=/etc/zsh --enable-etcdir=/etc/zsh --enable-multibyte --enable-cap --enable-pcre \
      CFLAGS="-O2 -std=gnu17"
quiet make; quiet make install.bin install.modules install.fns
grep -qx /usr/bin/zsh /etc/shells 2>/dev/null || { echo /usr/bin/zsh >> /etc/shells; echo /bin/zsh >> /etc/shells; }
done_ zsh
step "zsh plugins"
for p in zshautosuggestions:zsh-autosuggestions zshsyntaxhighlighting:zsh-syntax-highlighting; do
    n=${p%%:*}; d=${p#*:}; unpack "$n" "$(src "$n")"
    if [[ $d == zsh-syntax-highlighting ]]; then quiet make install PREFIX=/usr SHARE_DIR=/usr/share/zsh/plugins/$d
    else install -d /usr/share/zsh/plugins/$d; cp -r ./*.zsh src /usr/share/zsh/plugins/$d/; fi
    done_ "$n"
done
ls /usr/share/zsh/plugins/*/*.zsh
ac jq --disable-docs --with-oniguruma=builtin
cm fastfetch -DBUILD_TESTS=OFF -DENABLE_SYSTEM_YYJSON=OFF
step "btop $V_btop"; unpack btop "$(src btop)"
quiet make PREFIX=/usr STATIC=false GPU_SUPPORT=true ADDFLAGS=-O2; quiet make install PREFIX=/usr; done_ btop

# ───────────────────────────── desktop pieces ─────────────────────────────
ms mesademos -Degl=enabled -Dgles1=disabled -Dgles2=enabled -Dglut=disabled -Dosmesa=disabled -Dlibdrm=enabled \
             -Dx11=enabled -Dvulkan=disabled -Dwayland=disabled
cm poppler -DENABLE_QT5=OFF -DENABLE_QT6=OFF -DENABLE_BOOST=OFF -DENABLE_NSS3=OFF -DENABLE_GPGME=OFF \
           -DENABLE_LIBOPENJPEG=OFF -DENABLE_CPP=OFF -DENABLE_GLIB=ON -DENABLE_GOBJECT_INTROSPECTION=ON \
           -DENABLE_UTILS=ON -DENABLE_LCMS=ON -DENABLE_LIBCURL=ON -DENABLE_LIBTIFF=ON -DENABLE_GTK_DOC=OFF \
           -DBUILD_MANUAL_TESTS=OFF -DBUILD_GTK_TESTS=OFF -DBUILD_CPP_TESTS=OFF -DBUILD_QT5_TESTS=OFF \
           -DBUILD_QT6_TESTS=OFF -DENABLE_UNSTABLE_API_ABI_HEADERS=OFF
# eso-polkit looks for /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1
ac polkitgnome --libexecdir=/usr/lib/polkit-gnome CFLAGS="-O2 -std=gnu17 -Wno-error=incompatible-pointer-types"
ms plymouth -Ddocs=false -Dgtk=disabled -Drelease-file=/etc/os-release -Dsystemd-integration=true -Dudev=enabled \
            -Dpango=enabled -Dfreetype=enabled -Ddrm=true -Dlogo=/usr/share/pixmaps/eso-logo.png

# ───────────────────────────── python ─────────────────────────────
pyw six
step "python: python-xlib $V_pythonxlib (pure Python; copied, its setup.py wants to download setuptools-scm)"
unpack pythonxlib "$(src pythonxlib)"
SP=$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])'); rm -rf "$SP/Xlib"; cp -r Xlib "$SP/"
python3 -m compileall -q "$SP/Xlib" >/dev/null; done_ pythonxlib
pyw etxmlfile
pyw openpyxl
pyw pycparser
pyw cffi

step "smoke test"
for t in "gpgv --version" "gpg --version" "zsh --version" "jq --version" "fastfetch --version" "btop --version" \
         "pdftotext -v" "plymouthd --help" "glxinfo --help" "eglinfo --help"; do
    printf '  %-12s ' "${t%% *}"; $t > /tmp/v.txt 2>&1 || [[ $t == *--help* ]] || { cat /tmp/v.txt; echo "FAILED: $t"; exit 1; }
    head -1 /tmp/v.txt | cut -c1-80
done
for f in /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 /usr/bin/glxinfo /usr/bin/eglinfo \
         /usr/lib/girepository-1.0/Poppler-0.18.typelib /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh \
         /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh; do
    [[ -e $f ]] || { echo "missing $f"; exit 1; }
done
echo '{"eso":{"base":"6a"}}' | jq -e '.eso.base == "6a"' >/dev/null
zsh -fc 'source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh; source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh; print "  zsh plugins load: ok"'
python3 - <<'PY'
import gi
gi.require_version("Poppler", "0.18")
from gi.repository import Poppler
import Xlib, Xlib.display, openpyxl, cffi
from cffi import FFI
ffi = FFI(); ffi.cdef("size_t strlen(const char *);"); C = ffi.dlopen(None)
assert C.strlen(b"ESO Base") == 8
wb = openpyxl.Workbook(); wb.active["A1"] = "=1+1"; wb.save("/tmp/t.xlsx"); assert openpyxl.load_workbook("/tmp/t.xlsx").active["A1"].value == "=1+1"
print("  python: Poppler", Poppler.get_version(), "| python-xlib", Xlib.__version_string__, "| openpyxl", openpyxl.__version__,
      "| cffi", cffi.__version__)
PY
# real signature check with gpgv: make a throwaway key, sign, verify, tamper, verify again (must fail)
export GNUPGHOME=/tmp/gpgtest; rm -rf $GNUPGHOME; mkdir -m700 $GNUPGHOME
quiet gpg --batch --pinentry-mode loopback --passphrase '' --quick-gen-key "ESO Base test <test@eso.invalid>" ed25519 sign never
echo "ESO update manifest" > /tmp/m.json; quiet gpg --batch --detach-sign -o /tmp/m.json.sig /tmp/m.json
gpg --batch --export > /tmp/k.gpg
gpgv --keyring /tmp/k.gpg /tmp/m.json.sig /tmp/m.json >/dev/null 2>&1 || { echo "FAILED: gpgv rejected a good signature"; exit 1; }
echo "  gpgv: good signature accepted"
echo tampered >> /tmp/m.json
if gpgv --keyring /tmp/k.gpg /tmp/m.json.sig /tmp/m.json >/dev/null 2>&1; then echo "FAILED: gpgv accepted a tampered file"; exit 1; fi
echo "  gpgv: tampered file rejected"; gpgconf --kill all 2>/dev/null || true; rm -rf $GNUPGHOME /tmp/m.json* /tmp/k.gpg /tmp/t.xlsx
step "stage 6a done"; du -sh /usr/lib /usr/share
