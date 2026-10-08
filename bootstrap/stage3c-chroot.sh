#!/bin/bash
# ESO Base stage 3c, INSIDE the chroot: the rest of the base system (shell, Perl, Python, OpenSSL, kmod, systemd,
# D-Bus, GRUB, util-linux, e2fsprogs …).  Generic x86-64 code so it runs on every 64-bit PC.
set -euo pipefail
. /sources/versions.env
step() { echo; echo "=== $* ($(date -u +%H:%M:%S)) ==="; }
unpack() { rm -rf "/sources/$1"; mkdir -p "/sources/$1"; tar -xf "/sources/$2" -C "/sources/$1" --strip-components=1; cd "/sources/$1"; }
done_() { cd /sources; rm -rf "/sources/$1"; }
cfg() { ./configure --prefix=/usr "$@" >/dev/null; make >/dev/null; make install >/dev/null; }
pywheel() {  # name tarball
    unpack "$1" "$2"
    pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps "$PWD" >/dev/null
    pip3 install --no-index --find-links dist --no-deps "$3" >/dev/null
    done_ "$1"
}

step "ncurses $V_ncurses"
unpack ncurses "ncurses-$V_ncurses.tar.gz"
./configure --prefix=/usr --mandir=/usr/share/man --with-shared --without-debug --without-normal --with-cxx-shared \
    --enable-pc-files --with-pkg-config-libdir=/usr/lib/pkgconfig >/dev/null
make >/dev/null; make DESTDIR="$PWD/dest" install >/dev/null
install -m755 dest/usr/lib/libncursesw.so.6.5 /usr/lib; rm dest/usr/lib/libncursesw.so.6.5
sed -e 's/^#if.*XOPEN.*$/#if 1/' -i dest/usr/include/curses.h
cp -a dest/* /
for lib in ncurses form panel menu; do ln -sf lib${lib}w.so /usr/lib/lib${lib}.so; ln -sf ${lib}w.pc /usr/lib/pkgconfig/${lib}.pc; done
ln -sf libncursesw.so /usr/lib/libcurses.so; done_ ncurses

step "sed"; unpack sed "sed-$V_sed.tar.xz"; cfg; done_ sed
step "psmisc"; unpack psmisc "psmisc-$V_psmisc.tar.xz"; cfg; done_ psmisc
step "gettext"; unpack gettext "gettext-$V_gettext.tar.xz"; cfg --disable-static --docdir=/usr/share/doc/gettext
chmod 0755 /usr/lib/preloadable_libintl.so; done_ gettext
step "bison"; unpack bison "bison-$V_bison.tar.xz"; cfg --docdir=/usr/share/doc/bison; done_ bison
step "grep"; unpack grep "grep-$V_grep.tar.xz"; sed -i "s/echo/#echo/" src/egrep.sh; cfg; done_ grep
step "bash $V_bash"; unpack bash "bash-$V_bash.tar.gz"
cfg --without-bash-malloc --with-installed-readline --docdir=/usr/share/doc/bash; done_ bash
step "libtool"; unpack libtool "libtool-$V_libtool.tar.xz"; cfg; rm -f /usr/lib/libltdl.a; done_ libtool
step "gdbm"; unpack gdbm "gdbm-$V_gdbm.tar.gz"; cfg --disable-static --enable-libgdbm-compat; done_ gdbm
step "gperf"; unpack gperf "gperf-$V_gperf.tar.gz"; cfg; done_ gperf
step "expat"; unpack expat "expat-$V_expat.tar.xz"; cfg --disable-static; done_ expat
step "inetutils"; unpack inetutils "inetutils-$V_inetutils.tar.xz"
sed -i 's/def HAVE_TERMCAP_TGETENT/ 1/' telnet/telnet.c
cfg --bindir=/usr/bin --localstatedir=/var --disable-logger --disable-whois --disable-rcp --disable-rexec --disable-rlogin \
    --disable-rsh --disable-servers
mv /usr/bin/ifconfig /usr/sbin/ 2>/dev/null || true; done_ inetutils
step "less"; unpack less "less-$V_less.tar.gz"; cfg --sysconfdir=/etc; done_ less

step "perl $V_perl (final)"
unpack perl "perl-$V_perl.tar.xz"
PV=${V_perl%.*}
export BUILD_ZLIB=False BUILD_BZIP2=0
sh Configure -des -D prefix=/usr -D vendorprefix=/usr -D privlib=/usr/lib/perl5/$PV/core_perl \
    -D archlib=/usr/lib/perl5/$PV/core_perl -D sitelib=/usr/lib/perl5/$PV/site_perl -D sitearch=/usr/lib/perl5/$PV/site_perl \
    -D vendorlib=/usr/lib/perl5/$PV/vendor_perl -D vendorarch=/usr/lib/perl5/$PV/vendor_perl -D man1dir=none -D man3dir=none \
    -D pager="/usr/bin/less -isR" -D useshrplib -D usethreads >/dev/null
make >/dev/null; make install >/dev/null; unset BUILD_ZLIB BUILD_BZIP2; done_ perl
step "XML::Parser"; unpack xmlparser "XML-Parser-$V_xmlparser.tar.gz"
perl Makefile.PL >/dev/null; make >/dev/null; make install >/dev/null; done_ xmlparser
step "intltool"; unpack intltool "intltool-$V_intltool.tar.gz"; sed -i 's:\\\${:\\\$\\{:' intltool-update.in; cfg; done_ intltool
step "autoconf"; unpack autoconf "autoconf-$V_autoconf.tar.xz"; cfg; done_ autoconf
step "automake"; unpack automake "automake-$V_automake.tar.xz"; cfg; done_ automake

step "openssl $V_openssl"
unpack openssl "openssl-$V_openssl.tar.gz"
./config --prefix=/usr --openssldir=/etc/ssl --libdir=lib shared zlib-dynamic >/dev/null
make >/dev/null; sed -i '/INSTALL_LIBS/s/libcrypto.a libssl.a//' Makefile; make MANSUFFIX=ssl install_sw install_ssldirs >/dev/null
done_ openssl
step "libelf (elfutils $V_elfutils)"; unpack elfutils "elfutils-$V_elfutils.tar.bz2"
./configure --prefix=/usr --disable-debuginfod --enable-libdebuginfod=dummy >/dev/null; make >/dev/null
make -C libelf install >/dev/null; install -m644 config/libelf.pc /usr/lib/pkgconfig; rm -f /usr/lib/libelf.a; done_ elfutils
step "libffi"; unpack libffi "libffi-$V_libffi.tar.gz"; cfg --disable-static --with-gcc-arch=x86-64; done_ libffi

step "Python $V_python (final)"
unpack python "Python-$V_python.tar.xz"
./configure --prefix=/usr --enable-shared --with-system-expat --without-static-libpython --without-ensurepip >/dev/null
make >/dev/null 2>&1; make install >/dev/null 2>&1; done_ python
python3 -m ensurepip --help >/dev/null 2>&1 || true
# pip comes from Python's bundled wheel (no download)
W=$(ls /usr/lib/python3*/ensurepip/_bundled/pip-*.whl 2>/dev/null | head -1 || true)
if [[ -n "$W" ]]; then python3 "$W/pip" install --no-index --no-deps "$W" >/dev/null; fi
printf '[global]\nroot-user-action = ignore\ndisable-pip-version-check = true\n' > /etc/pip.conf
step "flit-core, packaging, wheel, setuptools"
pywheel flitcore "flit_core-$V_flitcore.tar.gz" flit_core
pywheel packaging "packaging-$V_packaging.tar.gz" packaging
pywheel wheel "wheel-$V_wheel.tar.gz" wheel
pywheel setuptools "setuptools-$V_setuptools.tar.gz" setuptools
step "ninja"; unpack ninja "ninja-$V_ninja.tar.gz"; python3 configure.py --bootstrap >/dev/null; install -m755 ninja /usr/bin/; done_ ninja
step "meson"; pywheel meson "meson-$V_meson.tar.gz" meson
step "markupsafe, jinja2"
pywheel markupsafe "markupsafe-$V_markupsafe.tar.gz" markupsafe
pywheel jinja2 "jinja2-$V_jinja2.tar.gz" jinja2

step "kmod $V_kmod"; unpack kmod "kmod-$V_kmod.tar.xz"
mkdir build && cd build && meson setup --prefix=/usr .. --buildtype=release -D manpages=false > /tmp/meson.log 2>&1 || { tail -40 /tmp/meson.log; exit 1; }
ninja >/dev/null; ninja install >/dev/null; done_ kmod
step "coreutils"; unpack coreutils "coreutils-$V_coreutils.tar.xz"
FORCE_UNSAFE_CONFIGURE=1 cfg --enable-no-install-program=kill,uptime; mv /usr/bin/chroot /usr/sbin 2>/dev/null || true; done_ coreutils
step "diffutils"; unpack diffutils "diffutils-$V_diffutils.tar.xz"; cfg; done_ diffutils
step "gawk"; unpack gawk "gawk-$V_gawk.tar.xz"; sed -i 's/extras//' Makefile.in; cfg; done_ gawk
step "findutils"; unpack findutils "findutils-$V_findutils.tar.xz"; cfg --localstatedir=/var/lib/locate; done_ findutils

step "GRUB $V_grub (BIOS + UEFI)"
for plat in pc efi; do
    unpack grub "grub-$V_grub.tar.xz"
    echo depends bli part_gpt > grub-core/extra_deps.lst
    if [[ $plat == pc ]]; then extra=(); else extra=(--with-platform=efi --target=x86_64); fi
    env -u CFLAGS -u CPPFLAGS -u CXXFLAGS -u LDFLAGS ./configure --prefix=/usr --sysconfdir=/etc --disable-efiemu \
        --disable-werror "${extra[@]}" >/dev/null
    make >/dev/null; make install >/dev/null; done_ grub
done
mkdir -p /usr/share/bash-completion/completions
mv /etc/bash_completion.d/grub /usr/share/bash-completion/completions 2>/dev/null || true

step "gzip"; unpack gzip "gzip-$V_gzip.tar.xz"; cfg; done_ gzip
step "iproute2"; unpack iproute2 "iproute2-$V_iproute2.tar.xz"
sed -i /ARPD/d Makefile; make NETNS_RUN_DIR=/run/netns >/dev/null; make SBINDIR=/usr/sbin install >/dev/null; done_ iproute2
step "kbd"; unpack kbd "kbd-$V_kbd.tar.xz"
sed -i '/RESIZECONS_PROGS=/s/yes/no/' configure; sed -i 's/resizecons.8 //' docs/man/man8/Makefile.in
cfg --disable-vlock; done_ kbd
step "make"; unpack make "make-$V_make.tar.gz"; cfg; done_ make
step "patch"; unpack patch "patch-$V_patch.tar.xz"; cfg; done_ patch
step "tar"; unpack tar "tar-$V_tar.tar.xz"; FORCE_UNSAFE_CONFIGURE=1 cfg; done_ tar
step "texinfo"; unpack texinfo "texinfo-$V_texinfo.tar.xz"; cfg; done_ texinfo
step "vim"; unpack vim "vim-$V_vim.tar.gz"; echo '#define SYS_VIMRC_FILE "/etc/vimrc"' >> src/feature.h
cfg; ln -sf vim /usr/bin/vi; printf 'source $VIMRUNTIME/defaults.vim\nlet skip_defaults_vim=1\nset nocompatible\nset backspace=2\nset mouse=\nsyntax on\n' > /etc/vimrc
done_ vim

step "systemd $V_systemd"
unpack systemd "systemd-$V_systemd.tar.gz"
grep -q '^render:' /etc/group || echo 'render:x:30:' >> /etc/group
grep -q '^sgx:' /etc/group || echo 'sgx:x:31:' >> /etc/group
grep -q '^systemd-journal:' /etc/group || echo 'systemd-journal:x:23:' >> /etc/group
mkdir build && cd build
meson setup .. --prefix=/usr --buildtype=release -D default-dnssec=no -D firstboot=false -D install-tests=false \
    -D ldconfig=false -D sysusers=false -D rpmmacrosdir=no -D homed=disabled -D userdb=false -D man=disabled \
    -D mode=release -D pam=disabled -D dev-kvm-mode=0660 -D nobody-group=nogroup -D sysupdate=disabled \
    -D ukify=disabled -D docdir=/usr/share/doc/systemd > /tmp/meson.log 2>&1 || { tail -40 /tmp/meson.log; exit 1; }
ninja >/dev/null; ninja install >/dev/null
systemd-machine-id-setup >/dev/null 2>&1 || true
systemctl preset-all >/dev/null 2>&1 || true
done_ systemd

step "D-Bus $V_dbus"; unpack dbus "dbus-$V_dbus.tar.xz"
mkdir build && cd build && meson setup --prefix=/usr --buildtype=release --wrap-mode=nofallback .. > /tmp/meson.log 2>&1 || { tail -40 /tmp/meson.log; exit 1; }
ninja >/dev/null; ninja install >/dev/null; mkdir -p /var/lib/dbus; ln -sf /etc/machine-id /var/lib/dbus/machine-id; done_ dbus
step "procps-ng"; unpack procps "procps-ng-$V_procps.tar.xz"
cfg --disable-static --disable-kill --enable-watch8bit --with-systemd; done_ procps
step "util-linux (final, with systemd support)"; unpack utillinux "util-linux-$V_utillinux.tar.xz"
cfg --bindir=/usr/bin --libdir=/usr/lib --runstatedir=/run --sbindir=/usr/sbin --disable-chfn-chsh --disable-login \
    --disable-nologin --disable-su --disable-setpriv --disable-runuser --disable-pylibmount --disable-liblastlog2 \
    --disable-static --without-python ADJTIME_PATH=/var/lib/hwclock/adjtime
done_ utillinux
step "e2fsprogs"; unpack e2fsprogs "e2fsprogs-$V_e2fsprogs.tar.gz"
mkdir build && cd build
../configure --prefix=/usr --sysconfdir=/etc --enable-elf-shlibs --disable-libblkid --disable-libuuid --disable-uuidd \
    --disable-fsck >/dev/null
make >/dev/null; make install >/dev/null; rm -f /usr/lib/{libcom_err,libe2p,libext2fs,libss}.a; done_ e2fsprogs

step "strip + clean"
find /usr/lib /usr/libexec -name '*.la' -delete
find /usr/{bin,sbin,libexec} -type f -exec strip --strip-unneeded {} + 2>/dev/null || true
# libraries in use (libc, readline …) are stripped into a copy and swapped in atomically
find /usr/lib -type f -name '*.so*' ! -name '*dbg' | while read -r f; do
    if strip --strip-unneeded -o /tmp/strip.tmp "$f" 2>/dev/null; then chmod --reference="$f" /tmp/strip.tmp; mv -f /tmp/strip.tmp "$f"; fi
done
rm -rf /tmp/* /usr/share/doc/* /usr/share/info/*
echo "ESO Base core system:"; systemctl --version | head -1; python3 --version; openssl version; { du -shx --exclude=/sources / 2>/dev/null || true; } | tail -1
