#!/bin/bash
# bootstrap/chroot-run.sh LIST INNER.sh  (root): download LIST into $ESO/sources (SHA-256 pinned), mount the kernel
# file systems and run INNER.sh inside the ESO Base chroot.  Nothing from the host is used inside.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ESO=${ESO:-/mnt/eso}
LIST=$1 INNER=$2
. "$HERE/lib.sh"
[[ $EUID -eq 0 ]] || { echo "needs root (chroot)"; exit 1; }
[[ -x $ESO/usr/bin/bash && -x $ESO/usr/bin/gcc ]] || { echo "no ESO system in $ESO"; exit 1; }
rm -f "$ESO/sources/versions.env"
fetch_list "$LIST" "$ESO/sources"
install -m755 "$HERE/$INNER" "$ESO/sources/inner.sh"
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
step "chroot into ESO Base: $INNER"
chroot "$ESO" /usr/bin/env -i HOME=/root TERM=xterm PATH=/usr/bin:/usr/sbin MAKEFLAGS="-j$(nproc)" LC_ALL=C \
    /bin/bash /sources/inner.sh
