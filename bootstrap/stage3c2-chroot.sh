#!/bin/bash
# ESO Base stage 3c part 2 (systemd onward), INSIDE the chroot: the rest of the base system (shell, Perl, Python, OpenSSL, kmod, systemd,
# D-Bus, GRUB, util-linux, e2fsprogs …).  Generic x86-64 code so it runs on every 64-bit PC.
set -euo pipefail
. /sources/versions.env
step() { echo; echo "=== $* ($(date -u +%H:%M:%S)) ==="; }
unpack() { rm -rf "/sources/$1"; mkdir -p "/sources/$1"; tar -xf "/sources/$2" -C "/sources/$1" --strip-components=1; cd "/sources/$1"; }
done_() { cd /sources; rm -rf "/sources/$1"; }
nj() { ninja "$@" > /tmp/ninja.log 2>&1 || { tail -60 /tmp/ninja.log; exit 1; }; }
cfg() { ./configure --prefix=/usr "$@" >/dev/null; make >/dev/null; make install >/dev/null; }
pywheel() {  # name tarball
    unpack "$1" "$2"
    pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps "$PWD" >/dev/null
    pip3 install --no-index --find-links dist --no-deps "$3" >/dev/null
    done_ "$1"
}

step "systemd $V_systemd"
unpack systemd "systemd-$V_systemd.tar.gz"
grep -q '^render:' /etc/group || echo 'render:x:30:' >> /etc/group
grep -q '^sgx:' /etc/group || echo 'sgx:x:31:' >> /etc/group
grep -q '^systemd-journal:' /etc/group || echo 'systemd-journal:x:23:' >> /etc/group
mkdir build && cd build
meson setup .. --prefix=/usr --buildtype=release -D default-dnssec=no -D firstboot=false -D install-tests=false \
    -D ldconfig=false -D sysusers=false -D rpmmacrosdir=no -D homed=disabled -D userdb=false -D man=disabled \
    -D mode=release -D pam=disabled -D kmod=enabled -D blkid=enabled -D acl=enabled -D dev-kvm-mode=0660 -D nobody-group=nogroup -D sysupdate=disabled \
    -D ukify=disabled -D docdir=/usr/share/doc/systemd > /tmp/meson.log 2>&1 || { tail -40 /tmp/meson.log; exit 1; }
nj; nj install
systemd-machine-id-setup >/dev/null 2>&1 || true
systemctl preset-all >/dev/null 2>&1 || true
done_ systemd

step "D-Bus $V_dbus"; unpack dbus "dbus-$V_dbus.tar.xz"
mkdir build && cd build && meson setup --prefix=/usr --buildtype=release --wrap-mode=nofallback .. > /tmp/meson.log 2>&1 || { tail -40 /tmp/meson.log; exit 1; }
nj; nj install; mkdir -p /var/lib/dbus; ln -sf /etc/machine-id /var/lib/dbus/machine-id; done_ dbus
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
