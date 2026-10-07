#!/bin/bash
# runs INSIDE the ESO Base chroot
set -euo pipefail
. /sources/versions.env
step() { echo; echo "=== $* ($(date -u +%H:%M:%S)) ==="; }
unpack() { rm -rf "/sources/$1"; mkdir -p "/sources/$1"; tar -xf "/sources/$2" -C "/sources/$1" --strip-components=1; cd "/sources/$1"; }

step "file system layout"
mkdir -p /{boot,home,mnt,opt,srv} /etc/{opt,sysconfig} /lib/firmware /media/{floppy,cdrom} /usr/{,local/}{include,src} \
    /usr/lib/locale /usr/local/{bin,lib,sbin} /usr/{,local/}share/{color,dict,doc,info,locale,man,misc,terminfo,zoneinfo} \
    /usr/{,local/}share/man/man{1..8} /var/{cache,local,log,mail,opt,spool} /var/lib/{color,misc,locate,hwclock}
ln -sfn /run /var/run; ln -sfn /run/lock /var/lock
install -d -m 0750 /root; install -d -m 1777 /tmp /var/tmp
ln -sf /proc/self/mounts /etc/mtab
cat > /etc/hosts <<H
127.0.0.1  localhost eso
::1        localhost
H
cat > /etc/passwd <<P
root:x:0:0:root:/root:/bin/bash
bin:x:1:1:bin:/dev/null:/usr/bin/false
daemon:x:6:6:Daemon User:/dev/null:/usr/bin/false
messagebus:x:18:18:D-Bus Message Daemon User:/run/dbus:/usr/bin/false
uuidd:x:80:80:UUID Generation Daemon User:/dev/null:/usr/bin/false
nobody:x:65534:65534:Unprivileged User:/dev/null:/usr/bin/false
P
cat > /etc/group <<G
root:x:0:
bin:x:1:daemon
sys:x:2:
kmem:x:3:
tape:x:4:
tty:x:5:
daemon:x:6:
floppy:x:7:
disk:x:8:
lp:x:9:
dialout:x:10:
audio:x:11:
video:x:12:
utmp:x:13:
cdrom:x:15:
adm:x:16:
messagebus:x:18:
input:x:24:
mail:x:34:
kvm:x:61:
uuidd:x:80:
wheel:x:97:
users:x:999:
nogroup:x:65534:
G
touch /var/log/{btmp,lastlog,faillog,wtmp}
chgrp utmp /var/log/lastlog; chmod 664 /var/log/lastlog; chmod 600 /var/log/btmp

step "gettext $V_gettext (tools only)"
unpack gettext "gettext-$V_gettext.tar.xz"
./configure --disable-shared >/dev/null && make >/dev/null
cp gettext-tools/src/{msgfmt,msgmerge,xgettext} /usr/bin

step "bison $V_bison"
unpack bison "bison-$V_bison.tar.xz"
./configure --prefix=/usr --docdir=/usr/share/doc/bison >/dev/null && make >/dev/null && make install >/dev/null

step "perl $V_perl"
unpack perl "perl-$V_perl.tar.xz"
PV=${V_perl%.*}
sh Configure -des -D prefix=/usr -D vendorprefix=/usr -D useshrplib -D privlib=/usr/lib/perl5/$PV/core_perl \
    -D archlib=/usr/lib/perl5/$PV/core_perl -D sitelib=/usr/lib/perl5/$PV/site_perl \
    -D sitearch=/usr/lib/perl5/$PV/site_perl -D vendorlib=/usr/lib/perl5/$PV/vendor_perl \
    -D vendorarch=/usr/lib/perl5/$PV/vendor_perl >/dev/null
make >/dev/null && make install >/dev/null

step "Python $V_python"
unpack python "Python-$V_python.tar.xz"
./configure --prefix=/usr --enable-shared --without-ensurepip --without-static-libpython >/dev/null
make >/dev/null 2>&1 && make install >/dev/null 2>&1

step "texinfo $V_texinfo"
unpack texinfo "texinfo-$V_texinfo.tar.xz"
./configure --prefix=/usr >/dev/null && make >/dev/null && make install >/dev/null

step "util-linux $V_utillinux"
unpack utillinux "util-linux-$V_utillinux.tar.xz"
./configure --libdir=/usr/lib --runstatedir=/run --disable-chfn-chsh --disable-login --disable-nologin --disable-su \
    --disable-setpriv --disable-runuser --disable-pylibmount --disable-static --disable-liblastlog2 --without-python \
    ADJTIME_PATH=/var/lib/hwclock/adjtime --docdir=/usr/share/doc/util-linux >/dev/null
make >/dev/null && make install >/dev/null

step "clean up: the cross toolchain is no longer needed"
rm -rf /usr/share/{info,man,doc}/* /tools
find /usr/{lib,libexec} -name '*.la' -delete
for d in gettext bison perl python texinfo utillinux; do rm -rf "/sources/$d"; done
echo "ESO Base temporary system complete:"
gcc --version | head -1; python3 --version; perl -e 'print "perl $^V\n"'; bash --version | head -1
