#!/bin/bash
# ESO Base stage 6d, INSIDE the chroot.
#   Flatpak:  libarchive, fuse3, gpgme, json-glib, libxmlb, libfyaml, AppStream, libostree, Flatpak + the Flathub remote
#   Vulkan:   glslang (SPIR-V shader compiler) -> libplacebo rebuilt with it, so mpv's gpu-next/Vulkan output works
#   tools ESO's apps call: which, 7-Zip, xdg-utils, desktop-file-utils, xdg-user-dirs, brightnessctl, playerctl,
#             maim/slop (screenshots), ripgrep, OpenSSH client, git, BlueZ, power-profiles-daemon, SPICE agent (VMs),
#             tesseract OCR (eng/ara/fra), iptables-nft + ufw + ClamAV (ESO Defender), pw-play/pw-record
# RESUMABLE: every package that finishes leaves /var/lib/eso/build/6d/<name>; a re-run skips those. A package that
# fails does not stop the others; the failures are listed at the end (and in /var/lib/eso/build/6d/FAILED).
set -uo pipefail
. /sources/versions.env
export PKG_CONFIG_PATH=/usr/lib/pkgconfig:/usr/share/pkgconfig PATH=/opt/rust/bin:/usr/bin:/usr/sbin
M=/var/lib/eso/build/6d; mkdir -p "$M"; rm -f "$M/FAILED"
step() { echo; echo "=== $* ($(date -u +%H:%M:%S)) ==="; }
# the source file whose name starts with $1 (explicit prefixes: release file names differ in style)
src() { local f; f=$(ls -d /sources/$1* 2>/dev/null | grep -vE 'vendor\.tar$' | head -1); [[ -n $f ]] || { echo "no source /sources/$1*" >&2; return 1; }; echo "$f"; }
# unpack NAME PREFIX [STRIP]
unpack() { local f; f=$(src "$2") || return 1; rm -rf "/sources/$1"; mkdir -p "/sources/$1"
           tar -xf "$f" -C "/sources/$1" --strip-components="${3:-1}"; cd "/sources/$1"; }
ms() { meson setup build --prefix=/usr --libdir=lib --buildtype=release -Dwrap_mode=nodownload "$@" && ninja -C build && ninja -C build install; }
cmk() { cmake -B build -G Ninja -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=Release "$@" && cmake --build build && cmake --install build; }
ac() { ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --disable-static "$@" && make && make install; }
grp() { grep -q "^$1:" /etc/group || groupadd -r "$1"; }
sysuser() { grp "$1"; id "$1" >/dev/null 2>&1 || useradd -r -g "$1" -d "$2" -s /usr/sbin/nologin -c "$3" "$1"; }
offline_cargo() { mkdir -p .cargo; printf '[source.crates-io]\nreplace-with = "vendored-sources"\n\n[source.vendored-sources]\ndirectory = "%s"\n\n[net]\noffline = true\n' "$1" > .cargo/config.toml; }
FAILED=()
build() {   # build NAME: run b_NAME once (marker), log to /tmp/6d-NAME.log, keep going on failure
    local n=$1 rc
    if [[ -e $M/$n ]]; then echo "  $n: done earlier, skipped"; return 0; fi
    step "$n"
    ( set -e; "b_$n" ) > "/tmp/6d-$n.log" 2>&1; rc=$?
    cd /sources; rm -rf "/sources/${n:?}"
    if [[ $rc -eq 0 ]]; then date -u +%FT%TZ > "$M/$n"; echo "  ok"; ldconfig
    else tail -60 "/tmp/6d-$n.log"; echo "  FAILED: $n (exit $rc)"; FAILED+=("$n"); echo "$n" >> "$M/FAILED"; fi
}

# ───────────────────────────── small tools ─────────────────────────────
b_which() { unpack which which-; ./configure --prefix=/usr && make && make install; }
b_sevenzip() {
    unpack sevenzip sevenzip- 0; cd CPP/7zip/Bundles/Alone2
    make -f makefile.gcc CFLAGS_WARN_WALL="-Wall"          # upstream sets -Werror; newer GCC warnings must not stop it
    install -m755 _o/7zz /usr/bin/7zz; ln -sfn 7zz /usr/bin/7z; /usr/bin/7z i > /dev/null
}
b_xdgutils() {   # git archive: the scripts are generated from *.in (help text needs xmlto; ship them without it)
    unpack xdgutils xdgutils-; ./configure --prefix=/usr --mandir=/usr/share/man; cd scripts
    for x in xdg-open xdg-mime xdg-settings xdg-desktop-menu xdg-desktop-icon xdg-icon-resource xdg-email xdg-screensaver; do
        : > "$x.txt"; make "$x"; install -m755 "$x" /usr/bin/
    done
    xdg-mime --version > /dev/null
}
b_desktopfileutils() { unpack desktopfileutils desktop-file-utils-; ms; update-desktop-database -q /usr/share/applications || true; }
b_xdguserdirs() { unpack xdguserdirs xdg-user-dirs-; ac --disable-documentation; }
b_brightnessctl() { unpack brightnessctl brightnessctl-; make ENABLE_SYSTEMD=1 PREFIX=/usr; make ENABLE_SYSTEMD=1 PREFIX=/usr install; }
b_playerctl() { unpack playerctl playerctl-; ms -Dgtk-doc=false -Dintrospection=false -Dbash-completions=false -Dzsh-completions=false; }
b_glm() {   # header-only
    unpack glm glm-; find glm -name '*.cpp' -delete; rm -f glm/CMakeLists.txt; rm -rf /usr/include/glm; cp -r glm /usr/include/
}
b_slop() { unpack slop slop-; cmk -DSLOP_OPENGL=OFF; }
b_maim() { unpack maim maim-; cmk; maim --version; }
b_ripgrep() {
    unpack ripgrep ripgrep-; tar -xf /sources/ripgrep-vendor.tar; offline_cargo "$PWD/vendor"
    CARGO_HOME=/tmp/cargo-rg cargo build --release --locked --offline; install -m755 target/release/rg /usr/bin/; rm -rf /tmp/cargo-rg
    rg --version
}
b_openssh() {   # client tools for git/ssh; sshd is installed but never enabled
    unpack openssh openssh-; sysuser sshd /var/lib/sshd "sshd privilege separation"; install -d -m700 /var/lib/sshd
    ./configure --prefix=/usr --sysconfdir=/etc/ssh --libexecdir=/usr/lib/ssh --with-privsep-path=/var/lib/sshd \
        --with-pid-dir=/run --with-default-path=/usr/bin:/usr/sbin
    make && make install-nokeys                                    # no host keys baked into the image
    ssh -V
}
b_git() {
    unpack git git-
    G=(prefix=/usr NO_TCLTK=1 NO_PERL=1 NO_PYTHON=1 NO_RUST=1 USE_LIBPCRE2=1 INSTALL_SYMLINKS=1 NO_INSTALL_HARDLINKS=1)
    make "${G[@]}" all && make "${G[@]}" install; git --version
}
b_bluez() {
    unpack bluez bluez-
    ac --libexecdir=/usr/lib --disable-obex --disable-cups --disable-manpages --disable-mesh --disable-midi --enable-library \
       --with-systemdsystemunitdir=/usr/lib/systemd/system --with-systemduserunitdir=/usr/lib/systemd/user
    install -d -m755 /etc/bluetooth; [[ -f /etc/bluetooth/main.conf ]] || install -m644 src/main.conf /etc/bluetooth/main.conf
    bluetoothctl --version
}
b_ppd() {
    unpack ppd ppd-
    ms -Dsystemdsystemunitdir=/usr/lib/systemd/system -Dmanpage=disabled -Dbashcomp=disabled -Dpylint=disabled -Dtests=false -Dgtk_doc=false
}
b_spiceprotocol() { unpack spiceprotocol spice-protocol-; ms; }
b_spicevdagent() {   # VM guests: auto-resize to the window size + shared clipboard (does nothing on real hardware)
    unpack spicevdagent spice-vdagent-
    ac --with-session-info=systemd --with-init-script=systemd --with-gtk=no
}
# ───────────────────────────── OCR (Amenokal's eyes) ─────────────────────────────
b_leptonica() { unpack leptonica leptonica-; ac --without-giflib --without-libopenjpeg; }
b_tesseract() {
    unpack tesseract tesseract-
    cmk -DBUILD_TRAINING_TOOLS=OFF -DGRAPHICS_DISABLED=ON -DDISABLE_ARCHIVE=ON -DDISABLE_CURL=ON -DBUILD_TESTS=OFF \
        -DOPENMP_BUILD=OFF -DENABLE_NATIVE=OFF -DENABLE_CCACHE=OFF -DSW_BUILD=OFF -DENABLE_PRECOMPILED_HEADERS=OFF
    install -d /usr/share/tessdata
    for l in eng ara fra; do install -m644 "/sources/$l.traineddata" /usr/share/tessdata/; done
    tesseract --list-langs
}
# ───────────────────────────── ESO Defender: firewall + antivirus ─────────────────────────────
b_libmnl() { unpack libmnl libmnl-; ac; }
b_libnftnl() { unpack libnftnl libnftnl-; ac; }
b_iptables() {   # nf_tables backend (the kernel's modern netfilter); "iptables" = iptables-nft
    unpack iptables iptables-
    ac --enable-nftables --disable-libnfnetlink --disable-connlabel --disable-nfsynproxy
    for t in iptables iptables-save iptables-restore ip6tables ip6tables-save ip6tables-restore; do
        ln -sfn xtables-nft-multi "/usr/sbin/$t"
    done
    iptables --version | grep -q nf_tables
}
b_ufw() {
    unpack ufw ufw-; python3 setup.py install --root=/ --prefix=/usr > /dev/null
    f=$(ls /usr/lib/ufw/ufw-init /lib/ufw/ufw-init 2>/dev/null | head -1); [[ -n $f ]]
    sed "s|/lib/ufw/ufw-init|$f|g" doc/systemd.example > /usr/lib/systemd/system/ufw.service
    ufw --version
}
b_clamav() {
    unpack clamav clamav-; sysuser clamav /var/lib/clamav "ClamAV"
    install -d -o clamav -g clamav /var/lib/clamav /var/log/clamav
    # Rust parts: the release tarball vendors every crate in .cargo/vendor
    mkdir -p /tmp/cargo-clam; printf '[source.crates-io]\nreplace-with = "v"\n[source.v]\ndirectory = "%s/.cargo/vendor"\n[net]\noffline = true\n' "$PWD" > /tmp/cargo-clam/config.toml
    CARGO_HOME=/tmp/cargo-clam cmk -DENABLE_MILTER=OFF -DENABLE_TESTS=OFF -DENABLE_MAN_PAGES=OFF -DENABLE_DOXYGEN=OFF \
        -DENABLE_EXAMPLES=OFF -DENABLE_JSON_SHARED=ON -DENABLE_SYSTEMD=ON -DENABLE_CLAMONACC=OFF \
        -DAPP_CONFIG_DIRECTORY=/etc/clamav -DDATABASE_DIRECTORY=/var/lib/clamav -DSYSTEMD_UNIT_DIR=/usr/lib/systemd/system
    rm -rf /tmp/cargo-clam
    for c in freshclam clamd; do
        [[ -f /etc/clamav/$c.conf.sample && ! -f /etc/clamav/$c.conf ]] && sed '/^Example/d' "/etc/clamav/$c.conf.sample" > "/etc/clamav/$c.conf"
    done
    clamscan --version
}
# ───────────────────────────── Flatpak ─────────────────────────────
b_libarchive() { unpack libarchive libarchive-; ac --without-nettle; }
b_fuse() {
    unpack fuse fuse-
    ms -Dudevrulesdir=/usr/lib/udev/rules.d -Dinitscriptdir= -Dexamples=false -Dtests=false -Denable-io-uring=false -Duseroot=true
    fusermount3 --version
}
b_gpgme() { unpack gpgme gpgme-; ac --disable-gpg-test --disable-gpgsm-test --disable-gpgconf-test --disable-g13-test; }
b_jsonglib() {
    unpack jsonglib json-glib-
    ms -Dintrospection=disabled -Ddocumentation=disabled -Dgtk_doc=disabled -Dman=false -Dtests=false -Dconformance=false -Dinstalled_tests=false
}
b_libxmlb() { unpack libxmlb libxmlb-; ms -Dgtkdoc=false -Dintrospection=false -Dtests=false -Dstemmer=false; }
b_libfyaml() { unpack libfyaml libfyaml-; ac --disable-network; }
b_appstream() {
    unpack appstream AppStream- 2          # tarball root is ./AppStream-x.y.z/
    # the CLI's own metainfo is translated with itstool (needs libxml2's Python module): install it untranslated
    python3 - <<'EOF'
import re
p = 'data/meson.build'; t = open(p).read()
t2 = re.sub(r"metainfo_i18n = i18n\.itstool_join\(.*?\n\)\n", "metainfo_i18n = metainfo_with_relinfo\n", t, flags=re.S)
assert t2 != t, 'itstool_join block not found'; open(p, 'w').write(t2)
EOF
    ms -Dstemming=false -Dsystemd=true -Dvapi=false -Dqt=false -Dcompose=false -Dgir=false -Dtools=true \
       -Dzstd-support=true -Dblake3-support=false -Ddocs=false -Dapidocs=false -Dinstall-docs=false -Dman=false \
       -Dbash-completion=false
    appstreamcli --version
}
b_ostree() {
    unpack ostree libostree-
    ac --libexecdir=/usr/lib --with-curl --without-soup --with-crypto=openssl --without-selinux --without-avahi \
       --without-composefs --disable-man --disable-gtk-doc --enable-introspection=no \
       --with-systemdsystemunitdir=/usr/lib/systemd/system
    ostree --version > /dev/null
}
b_pyparsing() { python3 -m pip install --no-index --no-deps --no-warn-script-location "$(src pyparsing-)"; }
b_flatpak() {
    unpack flatpak flatpak-; sysuser flatpak /nonexistent "Flatpak system helper"
    ms -Dsystem_bubblewrap=/usr/bin/bwrap -Dsystem_dbus_proxy=/usr/bin/xdg-dbus-proxy -Dsystem_fusermount=/usr/bin/fusermount3 \
       -Ddconf=disabled -Dmalcontent=disabled -Dselinux_module=disabled -Dgir=disabled -Dgtkdoc=disabled \
       -Ddocbook_docs=disabled -Dman=disabled -Dtests=false -Dinstalled_tests=false -Dsystemd=enabled \
       -Dprivileged_group=sudo
    install -Dm644 "$(src flathub)" /etc/flatpak/remotes.d/flathub.flatpakrepo
    flatpak --version
}
# ───────────────────────────── Vulkan for the video player ─────────────────────────────
b_glslang() {
    unpack glslang glslang-
    cmk -DBUILD_SHARED_LIBS=ON -DBUILD_EXTERNAL=OFF -DENABLE_OPT=OFF -DALLOW_EXTERNAL_SPIRV_TOOLS=OFF -DGLSLANG_TESTS=OFF \
        -DENABLE_GLSLANG_BINARIES=ON
    [[ -e /usr/lib/libSPIRV.so && -e /usr/lib/libglslang.so && -e /usr/include/glslang/build_info.h ]]
    glslang --version | head -2
}
b_libplacebo() {
    unpack libplacebo libplacebo-
    for p in glad:glad jinja:jinja2 markupsafe:markupsafe fast_float:fastfloat Vulkan-Headers:vulkanheaders; do
        mkdir -p "3rdparty/${p%%:*}"; tar -xf "$(src "${p#*:}-")" -C "3rdparty/${p%%:*}" --strip-components=1
    done
    ms -Dvulkan=enabled -Dvk-proc-addr=enabled -Dopengl=enabled -Dgl-proc-addr=enabled -Dd3d11=disabled -Dglslang=enabled \
       -Dshaderc=disabled -Dlcms=enabled -Ddovi=enabled -Dlibdovi=disabled -Dunwind=disabled -Dxxhash=disabled \
       -Ddemos=false -Dtests=false -Dbench=false -Dfuzz=false
    ldd /usr/lib/libplacebo.so | grep -q glslang                    # the shader compiler is really linked in
    ldd /usr/bin/mpv | grep -q 'not found' && exit 1 || true        # mpv still loads (same libplacebo ABI)
}
b_pipewire() {   # same build as stage 5b plus pw-cat (pw-play / pw-record) with libsndfile
    unpack pipewire pipewire-
    ms -Dauto_features=disabled -Dexamples=disabled -Dtests=disabled -Dpipewire-jack=disabled \
       -Dpipewire-v4l2=disabled -Dflatpak=disabled "-Dsession-managers=[]" -Dalsa=enabled -Dpipewire-alsa=enabled \
       -Dudev=enabled -Dlibsystemd=enabled -Dlogind=enabled -Dsystemd-user-service=enabled -Dreadline=enabled \
       -Dman=disabled -Ddocs=disabled -Dsystemd-user-unit-dir=/usr/lib/systemd/user -Dpw-cat=enabled -Dsndfile=enabled
    [[ -x /usr/bin/pw-play && -x /usr/bin/pw-record ]]
}

for n in which sevenzip xdgutils desktopfileutils xdguserdirs brightnessctl playerctl glm slop maim ripgrep openssh git \
         bluez ppd spiceprotocol spicevdagent leptonica tesseract libmnl libnftnl iptables ufw clamav \
         glslang libplacebo pipewire \
         libarchive fuse gpgme jsonglib libxmlb libfyaml appstream ostree pyparsing flatpak; do
    build "$n"
done
ldconfig; glib-compile-schemas /usr/share/glib-2.0/schemas 2>/dev/null || true
step "stage 6d summary"
for c in which 7z xdg-open xdg-settings xdg-user-dir update-desktop-database brightnessctl playerctl maim slop rg ssh git \
         bluetoothctl powerprofilesctl spice-vdagent tesseract iptables ufw clamscan freshclam flatpak fusermount3 \
         appstreamcli ostree glslang pw-play pw-record; do
    printf '  %-24s %s\n' "$c" "$(command -v "$c" || echo MISSING)"
done
if (( ${#FAILED[@]} )); then echo; echo "FAILED packages: ${FAILED[*]}  (re-run with resume to retry only these)"; exit 1; fi
echo "stage 6d complete"
