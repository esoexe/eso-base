#!/bin/bash
# ESO Base stage 1: cross toolchain built from upstream sources only.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ESO=${ESO:-/mnt/eso}
TGT=x86_64-eso-linux-gnu
J=${J:-$(nproc)}
SRC=$ESO/sources
mkdir -p "$SRC" "$ESO"/{tools,etc,var,usr/{bin,lib,sbin}} "$ESO/lib64"
for d in bin lib sbin; do [[ -e $ESO/$d ]] || ln -s usr/$d "$ESO/$d"; done
export PATH=$ESO/tools/bin:/usr/bin:/bin LC_ALL=POSIX CONFIG_SITE=$ESO/usr/share/config.site
set +h; umask 022

# fetch + verify (sources.lock pins SHA-256; new entries are recorded on first download)
touch "$HERE/sources.lock"
while read -r name ver url; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    f=$SRC/${url##*/}
    [[ -s "$f" ]] || curl -fsSL --retry 4 -o "$f" "$url"
    sum=$(sha256sum "$f" | cut -d' ' -f1)
    pin=$(awk -v n="${url##*/}" '$2==n{print $1}' "$HERE/sources.lock")
    if [[ -n "$pin" && "$pin" != "$sum" ]]; then echo "CHECKSUM MISMATCH: ${url##*/}"; exit 1; fi
    if [[ -z "$pin" ]]; then echo "$sum  ${url##*/}" >> "$HERE/sources.lock"; fi
    eval "V_${name}=$ver"
done < "$HERE/sources.list"

step() { echo; echo "=== $* ($(date -u +%H:%M:%S)) ==="; }
unpack() { rm -rf "$SRC/$1"; mkdir -p "$SRC/$1"; tar -xf "$SRC/$2" -C "$SRC/$1" --strip-components=1; cd "$SRC/$1"; }

step "binutils $V_binutils (pass 1)"
unpack binutils "binutils-$V_binutils.tar.xz"
mkdir build && cd build
../configure --prefix="$ESO/tools" --with-sysroot="$ESO" --target=$TGT --disable-nls --enable-gprofng=no \
    --disable-werror --enable-new-dtags --enable-default-hash-style=gnu >/dev/null
make -j"$J" >/dev/null && make install >/dev/null

step "gcc $V_gcc (pass 1)"
unpack gcc "gcc-$V_gcc.tar.xz"
mkdir gmp mpfr mpc
tar -xf "$SRC/gmp-$V_gmp.tar.xz" -C gmp --strip-components=1
tar -xf "$SRC/mpfr-$V_mpfr.tar.xz" -C mpfr --strip-components=1
tar -xf "$SRC/mpc-$V_mpc.tar.gz" -C mpc --strip-components=1
sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64
mkdir build && cd build
../configure --target=$TGT --prefix="$ESO/tools" --with-glibc-version="$V_glibc" --with-sysroot="$ESO" \
    --with-newlib --without-headers --enable-default-pie --enable-default-ssp --disable-nls --disable-shared \
    --disable-multilib --disable-threads --disable-libatomic --disable-libgomp --disable-libquadmath \
    --disable-libssp --disable-libvtv --disable-libstdcxx --enable-languages=c,c++ >/dev/null
make -j"$J" >/dev/null && make install >/dev/null
cd ..
cat gcc/limitx.h gcc/glimits.h gcc/limity.h > "$(dirname "$($TGT-gcc -print-libgcc-file-name)")/include/limits.h"

step "Linux $V_linux API headers (ESO Kernel base)"
unpack linux "linux-$V_linux.tar.xz"
make mrproper >/dev/null && make headers >/dev/null
find usr/include -type f ! -name '*.h' -delete
cp -r usr/include "$ESO/usr"

step "glibc $V_glibc"
unpack glibc "glibc-$V_glibc.tar.xz"
ln -sf ../lib/ld-linux-x86-64.so.2 "$ESO/lib64"
ln -sf ../lib/ld-linux-x86-64.so.2 "$ESO/lib64/ld-lsb-x86-64.so.3"
mkdir build && cd build
echo "rootsbindir=/usr/sbin" > configparms
../configure --prefix=/usr --host=$TGT --build="$(../scripts/config.guess)" --enable-kernel=5.4 --disable-werror \
    --with-headers="$ESO/usr/include" --disable-nscd libc_cv_slibdir=/usr/lib >/dev/null
make -j"$J" >/dev/null && make DESTDIR="$ESO" install >/dev/null
sed '/RTLDLIST=/s@/usr@@g' -i "$ESO/usr/bin/ldd"

step "sanity check: the new toolchain links against ESO's own glibc"
cd "$SRC"
echo 'int main(void){return 0;}' | $TGT-gcc -x c - -o eso-test
readelf -l eso-test | grep -q '/lib64/ld-linux-x86-64.so.2' && echo "OK: ESO glibc dynamic linker"
rm -f eso-test

step "libstdc++ (from gcc $V_gcc)"
cd "$SRC/gcc" && rm -rf build && mkdir build && cd build
../libstdc++-v3/configure --host=$TGT --build="$(../config.guess)" --prefix=/usr --disable-multilib --disable-nls \
    --disable-libstdcxx-pch --with-gxx-include-dir="/tools/$TGT/include/c++/$V_gcc" >/dev/null
make -j"$J" >/dev/null && make DESTDIR="$ESO" install >/dev/null
rm -f "$ESO"/usr/lib/lib{stdc++{,exp,fs},supc++}.la

step "done"
"$TGT-gcc" --version | head -1
du -sh "$ESO/tools" "$ESO/usr"
