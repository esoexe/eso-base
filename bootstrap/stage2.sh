#!/bin/bash
# ESO Base stage 2: temporary tools, cross-compiled with the stage 1 toolchain (upstream sources only).
# After this, $ESO has its own shell, coreutils, compiler and make: stage 3 builds the final system inside it.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ESO=${ESO:-/mnt/eso}
TGT=x86_64-eso-linux-gnu
J=${J:-$(nproc)}
SRC=$ESO/sources
export PATH=$ESO/tools/bin:/usr/bin:/bin LC_ALL=POSIX CONFIG_SITE=$ESO/usr/share/config.site
set +h; umask 022
[[ -x $ESO/tools/bin/$TGT-gcc ]] || { echo "stage 1 toolchain missing in $ESO/tools"; exit 1; }

# GNU's main server is often slow from CI: try it briefly, then official mirrors (same files, checked by SHA-256)
fetch() {
    local url=$1 out=$2 u
    for u in "$url" "${url/https:\/\/ftp.gnu.org\/gnu\//https://mirrors.kernel.org/gnu/}" \
             "${url/https:\/\/ftp.gnu.org\/gnu\//https://ftpmirror.gnu.org/}" \
             "${url/https:\/\/astron.com\/pub\/file\//https://ftp.astron.com/pub/file/}"; do
        if curl -fsSL --retry 2 --connect-timeout 20 --max-time 900 -o "$out.part" "$u"; then mv "$out.part" "$out"; return 0; fi
        echo "download failed: $u" >&2
    done
    rm -f "$out.part"; return 1
}
mkdir -p "$SRC" "$ESO"/{etc,var,usr/{bin,lib,sbin}} "$ESO/lib64"
for d in bin lib sbin; do [[ -e $ESO/$d ]] || ln -s usr/$d "$ESO/$d"; done

for list in sources.list sources-stage2.list; do
    while read -r name ver url; do
        [[ -z "$name" || "$name" == \#* ]] && continue
        f=$SRC/${url##*/}
        [[ -s "$f" ]] || fetch "$url" "$f"
        sum=$(sha256sum "$f" | cut -d' ' -f1)
        pin=$(awk -v n="${url##*/}" '$2==n{print $1}' "$HERE/sources.lock")
        if [[ -n "$pin" && "$pin" != "$sum" ]]; then echo "CHECKSUM MISMATCH: ${url##*/}"; exit 1; fi
        if [[ -z "$pin" ]]; then echo "$sum  ${url##*/}" >> "$HERE/sources.lock"; fi
        eval "V_${name}=$ver"
    done < "$HERE/$list"
done

step() { echo; echo "=== $* ($(date -u +%H:%M:%S)) ==="; }
unpack() { rm -rf "$SRC/$1"; mkdir -p "$SRC/$1"; tar -xf "$SRC/$2" -C "$SRC/$1" --strip-components=1; cd "$SRC/$1"; }
BUILD() { local g; for g in build-aux/config.guess support/config.guess config.guess; do
    if [[ -x $g ]]; then "./$g"; return; fi; done; echo "no config.guess in $PWD" >&2; return 1; }
std() {  # name tarball [extra configure args]
    local n=$1 t=$2; shift 2
    step "$n"
    unpack "$n" "$t"
    ./configure --prefix=/usr --host=$TGT --build="$(BUILD)" "$@" >/dev/null
    make -j"$J" >/dev/null && make DESTDIR="$ESO" install >/dev/null
}

std m4 "m4-$V_m4.tar.xz"

step "ncurses $V_ncurses"
unpack ncurses "ncurses-$V_ncurses.tar.gz"
mkdir build && pushd build >/dev/null
../configure --prefix="$ESO/tools" AWK=gawk >/dev/null
make -C include >/dev/null && make -C progs tic >/dev/null && install progs/tic "$ESO/tools/bin"
popd >/dev/null
./configure --prefix=/usr --host=$TGT --build="$(./config.guess)" --mandir=/usr/share/man --with-manpage-format=normal \
    --with-shared --without-normal --with-cxx-shared --without-debug --without-ada --disable-stripping AWK=gawk >/dev/null
make -j"$J" >/dev/null && make DESTDIR="$ESO" install >/dev/null
ln -sf libncursesw.so "$ESO/usr/lib/libncurses.so"
sed -e 's/^#if.*XOPEN.*$/#if 1/' -i "$ESO/usr/include/curses.h"

std bash "bash-$V_bash.tar.gz" --without-bash-malloc bash_cv_strtold_broken=no
ln -sf bash "$ESO/bin/sh"

std coreutils "coreutils-$V_coreutils.tar.xz" --enable-install-program=hostname --enable-no-install-program=kill,uptime
mv "$ESO/usr/bin/chroot" "$ESO/usr/sbin" 2>/dev/null || true

step "diffutils"; unpack diffutils "diffutils-$V_diffutils.tar.xz"
./configure --prefix=/usr --host=$TGT --build="$(./build-aux/config.guess)" gl_cv_func_strcasecmp_works=y >/dev/null
make -j"$J" >/dev/null && make DESTDIR="$ESO" install >/dev/null

step "file $V_file"
unpack file "file-$V_file.tar.gz"
mkdir build && pushd build >/dev/null
../configure --disable-bzlib --disable-libseccomp --disable-xzlib --disable-zlib >/dev/null && make -j"$J" >/dev/null
popd >/dev/null
./configure --prefix=/usr --host=$TGT --build="$(./config.guess)" >/dev/null
make FILE_COMPILE="$(pwd)/build/src/file" -j"$J" >/dev/null && make DESTDIR="$ESO" install >/dev/null
rm -f "$ESO/usr/lib/libmagic.la"

std findutils "findutils-$V_findutils.tar.xz" --localstatedir=/var/lib/locate
step "gawk (prep)"; unpack gawk "gawk-$V_gawk.tar.xz"; sed -i 's/extras//' Makefile.in
./configure --prefix=/usr --host=$TGT --build="$(./build-aux/config.guess)" >/dev/null
make -j"$J" >/dev/null && make DESTDIR="$ESO" install >/dev/null
std grep "grep-$V_grep.tar.xz"
step "gzip"; unpack gzip "gzip-$V_gzip.tar.xz"
./configure --prefix=/usr --host=$TGT >/dev/null && make -j"$J" >/dev/null && make DESTDIR="$ESO" install >/dev/null
std make "make-$V_make.tar.gz" --without-guile
std patch "patch-$V_patch.tar.xz"
std sed "sed-$V_sed.tar.xz"
std tar "tar-$V_tar.tar.xz"
std xz "xz-$V_xz.tar.xz" --disable-static --docdir=/usr/share/doc/xz
rm -f "$ESO/usr/lib/liblzma.la"

step "binutils $V_binutils (pass 2)"
unpack binutils "binutils-$V_binutils.tar.xz"
sed '6031s/$add_dir//' -i ltmain.sh
mkdir build && cd build
../configure --prefix=/usr --build="$(../config.guess)" --host=$TGT --disable-nls --enable-shared --enable-gprofng=no \
    --disable-werror --enable-64-bit-bfd --enable-new-dtags --enable-default-hash-style=gnu >/dev/null
make -j"$J" >/dev/null && make DESTDIR="$ESO" install >/dev/null
rm -f "$ESO"/usr/lib/lib{bfd,ctf,ctf-nobfd,opcodes,sframe}.{a,la}

step "gcc $V_gcc (pass 2)"
unpack gcc "gcc-$V_gcc.tar.xz"
mkdir gmp mpfr mpc
tar -xf "$SRC/gmp-$V_gmp.tar.xz" -C gmp --strip-components=1
tar -xf "$SRC/mpfr-$V_mpfr.tar.xz" -C mpfr --strip-components=1
tar -xf "$SRC/mpc-$V_mpc.tar.gz" -C mpc --strip-components=1
sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64
sed '/thread_header =/s/@.*@/gthr-posix.h/' -i libgcc/Makefile.in libstdc++-v3/include/Makefile.in
mkdir build && cd build
../configure --build="$(../config.guess)" --host=$TGT --target=$TGT LDFLAGS_FOR_TARGET=-L"$PWD/$TGT/libgcc" \
    --prefix=/usr --with-build-sysroot="$ESO" --enable-default-pie --enable-default-ssp --disable-nls --disable-multilib \
    --disable-libatomic --disable-libgomp --disable-libquadmath --disable-libsanitizer --disable-libssp --disable-libvtv \
    --enable-languages=c,c++ >/dev/null
make -j"$J" >/dev/null && make DESTDIR="$ESO" install >/dev/null
ln -sf gcc "$ESO/usr/bin/cc"

step "done: ESO Base temporary system"
ls "$ESO/usr/bin" | wc -l
du -sh "$ESO/usr"
