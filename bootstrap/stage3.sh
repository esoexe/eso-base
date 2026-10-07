#!/bin/bash
# ESO Base stage 3a (run as root): enter the new system with chroot and build the last tools it needs to build
# itself: gettext, bison, perl, Python, texinfo, util-linux.  From here on nothing from the host is used at all.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ESO=${ESO:-/mnt/eso}
. "$HERE/lib.sh"
[[ $EUID -eq 0 ]] || { echo "stage 3 runs as root (chroot)"; exit 1; }
[[ -x $ESO/usr/bin/bash && -x $ESO/usr/bin/gcc ]] || { echo "stage 2 system missing in $ESO"; exit 1; }
rm -f "$ESO/sources/versions.env"
fetch_list sources-stage3.list "$ESO/sources"
install -m755 "$HERE/stage3-chroot.sh" "$ESO/sources/stage3-chroot.sh"

step "own the tree as root, mount the kernel file systems"
chown -R root:root "$ESO"/{usr,var,etc,lib64}
[[ -d $ESO/tools ]] && chown -R root:root "$ESO/tools"
mkdir -p "$ESO"/{dev,proc,sys,run}
cleanup() { for m in dev/pts dev proc sys run; do mountpoint -q "$ESO/$m" && umount -l "$ESO/$m"; done; true; }
trap cleanup EXIT
mount --bind /dev "$ESO/dev"
mount -t devpts devpts -o gid=5,mode=0620 "$ESO/dev/pts"
mount -t proc proc "$ESO/proc"
mount -t sysfs sysfs "$ESO/sys"
mount -t tmpfs tmpfs "$ESO/run"

step "chroot into ESO Base"
chroot "$ESO" /usr/bin/env -i HOME=/root TERM=xterm PATH=/usr/bin:/usr/sbin MAKEFLAGS="-j$(nproc)" \
    /bin/bash /sources/stage3-chroot.sh
