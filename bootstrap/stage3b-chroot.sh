#!/bin/bash
# ESO Base stage 3b, INSIDE the chroot: the final C library and toolchain of ESO Base.
set -euo pipefail
. /sources/versions.env
step() { echo; echo "=== $* ($(date -u +%H:%M:%S)) ==="; }
unpack() { rm -rf "/sources/$1"; mkdir -p "/sources/$1"; tar -xf "/sources/$2" -C "/sources/$1" --strip-components=1; cd "/sources/$1"; }
done_() { cd /sources; rm -rf "/sources/$1"; }
cfg() { ./configure --prefix=/usr "$@" >/dev/null; make >/dev/null; make install >/dev/null; }

step "iana-etc $V_ianaetc"
unpack ianaetc "iana-etc-$V_ianaetc.tar.gz"; cp services protocols /etc; done_ ianaetc

step "glibc $V_glibc (final)"
unpack glibc "glibc-$V_glibc.tar.xz"
mkdir build && cd build
echo "rootsbindir=/usr/sbin" > configparms
../configure --prefix=/usr --disable-werror --disable-nscd libc_cv_slibdir=/usr/lib --enable-stack-protector=strong \
    --enable-kernel=5.4 >/dev/null
make >/dev/null
touch /etc/ld.so.conf
sed '/test-installation/s@$(PERL)@echo not running@' -i ../Makefile
make install >/dev/null 2>&1
sed '/RTLDLIST=/s@/usr@@g' -i /usr/bin/ldd
mkdir -p /usr/lib/locale
for l in C:UTF-8 en_US:UTF-8 en_GB:UTF-8 fr_FR:UTF-8 ar_DZ:UTF-8 ar_SA:UTF-8 ar_MA:UTF-8 de_DE:UTF-8 es_ES:UTF-8; do
    localedef -i "${l%%:*}" -f "${l##*:}" "${l%%:*}.${l##*:}" 2>/dev/null || true
done
cat > /etc/nsswitch.conf <<N
passwd: files systemd
group: files systemd
shadow: files systemd
hosts: mymachines resolve [!UNAVAIL=return] files myhostname dns
networks: files
protocols: files
services: files
ethers: files
rpc: files
N
cat > /etc/ld.so.conf <<L
/usr/local/lib
/opt/lib
include /etc/ld.so.conf.d/*.conf
L
mkdir -p /etc/ld.so.conf.d
done_ glibc

step "tzdata $V_tzdata"
rm -rf /sources/tz && mkdir /sources/tz && tar -xf "/sources/tzdata$V_tzdata.tar.gz" -C /sources/tz && cd /sources/tz
Z=/usr/share/zoneinfo
mkdir -p $Z/{posix,right}
for t in etcetera southamerica northamerica europe africa antarctica asia australasia backward; do
    zic -L /dev/null -d $Z $t; zic -L /dev/null -d $Z/posix $t; zic -L leapseconds -d $Z/right $t
done
cp zone.tab zone1970.tab iso3166.tab $Z
zic -d $Z -p America/New_York
ln -sfn /usr/share/zoneinfo/Africa/Algiers /etc/localtime
done_ tz
ldconfig

step "zlib $V_zlib"; unpack zlib "zlib-$V_zlib.tar.gz"; cfg; rm -f /usr/lib/libz.a; done_ zlib

step "bzip2 $V_bzip2"
unpack bzip2 "bzip2-$V_bzip2.tar.gz"
sed -i 's@\(ln -s -f \)$(PREFIX)/bin/@\1@' Makefile
sed -i "s@(PREFIX)/man@(PREFIX)/share/man@g" Makefile
make -f Makefile-libbz2_so >/dev/null; make clean >/dev/null; make >/dev/null; make PREFIX=/usr install >/dev/null
cp -a libbz2.so.* /usr/lib; ln -sf libbz2.so.1.0.8 /usr/lib/libbz2.so
cp bzip2-shared /usr/bin/bzip2; for i in /usr/bin/{bzcat,bunzip2}; do ln -sf bzip2 "$i"; done
rm -f /usr/lib/libbz2.a; done_ bzip2

step "xz $V_xz"; unpack xz "xz-$V_xz.tar.xz"; cfg --disable-static --docdir=/usr/share/doc/xz; done_ xz
step "lz4 $V_lz4"; unpack lz4 "lz4-$V_lz4.tar.gz"
make BUILD_STATIC=no PREFIX=/usr >/dev/null; make BUILD_STATIC=no PREFIX=/usr install >/dev/null; done_ lz4
step "zstd $V_zstd"; unpack zstd "zstd-$V_zstd.tar.gz"
make prefix=/usr >/dev/null; make prefix=/usr install >/dev/null; rm -f /usr/lib/libzstd.a; done_ zstd
step "file $V_file"; unpack file "file-$V_file.tar.gz"; cfg; done_ file

step "readline $V_readline"
unpack readline "readline-$V_readline.tar.gz"
sed -i '/MV.*old/d' Makefile.in; sed -i '/{OLDSUFF}/c:' support/shlib-install
sed -i 's/-Wl,-rpath,[^ ]*//' support/shobj-conf
./configure --prefix=/usr --disable-static --with-curses --docdir=/usr/share/doc/readline >/dev/null
make SHLIB_LIBS="-lncursesw" >/dev/null; make install >/dev/null; done_ readline

step "m4 $V_m4"; unpack m4 "m4-$V_m4.tar.xz"; cfg; done_ m4
step "bc $V_bc"; unpack bc "bc-$V_bc.tar.xz"
CC='gcc -std=c99' ./configure --prefix=/usr -G -O3 -r >/dev/null; make >/dev/null; make install >/dev/null; done_ bc
step "flex $V_flex"; unpack flex "flex-$V_flex.tar.gz"; cfg --disable-static --docdir=/usr/share/doc/flex
ln -sf flex /usr/bin/lex; done_ flex
step "pkgconf $V_pkgconf"; unpack pkgconf "pkgconf-$V_pkgconf.tar.xz"; cfg --disable-static
ln -sf pkgconf /usr/bin/pkg-config; done_ pkgconf

step "binutils $V_binutils (final)"
unpack binutils "binutils-$V_binutils.tar.xz"
mkdir build && cd build
../configure --prefix=/usr --sysconfdir=/etc --enable-ld=default --enable-plugins --enable-shared --disable-werror \
    --enable-64-bit-bfd --enable-new-dtags --with-system-zlib --enable-default-hash-style=gnu --enable-gprofng=no >/dev/null
make tooldir=/usr >/dev/null; make tooldir=/usr install >/dev/null
rm -f /usr/lib/lib{bfd,ctf,ctf-nobfd,gprofng,opcodes,sframe}.a; done_ binutils

# generic x86-64 code (runs on every 64-bit PC), not tuned to the build machine
step "gmp $V_gmp"; unpack gmp "gmp-$V_gmp.tar.xz"
./configure --prefix=/usr --enable-cxx --disable-static --host=none-linux-gnu >/dev/null; make >/dev/null; make install >/dev/null
done_ gmp
step "mpfr $V_mpfr"; unpack mpfr "mpfr-$V_mpfr.tar.xz"; cfg --disable-static --enable-thread-safe; done_ mpfr
step "mpc $V_mpc"; unpack mpc "mpc-$V_mpc.tar.gz"; cfg --disable-static; done_ mpc
step "attr $V_attr"; unpack attr "attr-$V_attr.tar.gz"; cfg --disable-static --sysconfdir=/etc; done_ attr
step "acl $V_acl"; unpack acl "acl-$V_acl.tar.xz"; cfg --disable-static; done_ acl
step "libcap $V_libcap"; unpack libcap "libcap-$V_libcap.tar.xz"
sed -i '/install -m.*STA/d' libcap/Makefile
make prefix=/usr lib=lib >/dev/null; make prefix=/usr lib=lib install >/dev/null; done_ libcap
step "libxcrypt $V_libxcrypt"; unpack libxcrypt "libxcrypt-$V_libxcrypt.tar.xz"
cfg --enable-hashes=strong,glibc --enable-obsolete-api=no --disable-static --disable-failure-tokens; done_ libxcrypt

step "shadow $V_shadow"
unpack shadow "shadow-$V_shadow.tar.xz"
sed -i 's/groups$(EXEEXT) //' src/Makefile.in
find man -name Makefile.in -exec sed -i 's/groups\.1 / /;s/getspnam\.3 / /;s/passwd\.5 / /' {} \;
sed -e 's:#ENCRYPT_METHOD DES:ENCRYPT_METHOD YESCRYPT:' -e 's:/var/spool/mail:/var/mail:' \
    -e '/PATH=/{s@/sbin:@@;s@/bin:@@}' -i etc/login.defs
touch /usr/bin/passwd
./configure --sysconfdir=/etc --disable-static --with-{b,yes}crypt --without-libbsd --with-group-name-max-length=32 >/dev/null
make >/dev/null; make exec_prefix=/usr install >/dev/null
pwconv; grpconv; mkdir -p /etc/default; useradd -D --gid 999
done_ shadow

step "gcc $V_gcc (final, native)"
unpack gcc "gcc-$V_gcc.tar.xz"
sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64
mkdir build && cd build
../configure --prefix=/usr LD=ld --enable-languages=c,c++ --enable-default-pie --enable-default-ssp --enable-host-pie \
    --disable-multilib --disable-libsanitizer --disable-bootstrap --disable-fixincludes --with-system-zlib >/dev/null
make >/dev/null; make install >/dev/null
ln -sfr /usr/bin/cpp /usr/lib/cpp
mkdir -p /usr/lib/bfd-plugins
ln -sf "../../libexec/gcc/$(gcc -dumpmachine)/$V_gcc/liblto_plugin.so" /usr/lib/bfd-plugins/
mkdir -p /usr/share/gdb/auto-load/usr/lib; mv /usr/lib/*gdb.py /usr/share/gdb/auto-load/usr/lib 2>/dev/null || true
done_ gcc

step "sanity check"
echo 'int main(){return 0;}' > /tmp/t.c
v=$(cc /tmp/t.c -o /tmp/t -Wl,--verbose 2>&1)
[[ "$v" == *succeeded*crt1.o* ]] || { echo "SANITY: crt1.o not found"; exit 1; }
[[ "$(readelf -l /tmp/t)" == *ld-linux-x86-64.so.2* ]] || { echo "SANITY: wrong dynamic linker"; exit 1; }
/tmp/t || { echo "SANITY: test program does not run"; exit 1; }
echo "toolchain sanity OK"; rm -f /tmp/t /tmp/t.c
gcc --version | sed -n 1p; ld --version | sed -n 1p; ldd --version 2>&1 | sed -n 1p
