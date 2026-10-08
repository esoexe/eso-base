#!/bin/bash
# ESO Base stage 3d, INSIDE the chroot: ESO Kernel, ESO initramfs, system configuration -> a bootable ESO Base.
set -euo pipefail
. /sources/versions.env
step() { echo; echo "=== $* ($(date -u +%H:%M:%S)) ==="; }
unpack() { rm -rf "/sources/$1"; mkdir -p "/sources/$1"; tar -xf "/sources/$2" -C "/sources/$1" --strip-components=1; cd "/sources/$1"; }

step "cpio $V_cpio"; unpack cpio "cpio-$V_cpio.tar.bz2"
./configure --prefix=/usr --enable-mt --with-rmt=/usr/libexec/rmt >/dev/null 2>&1 \
    && make >/dev/null 2>&1 && make install >/dev/null; cd /sources; rm -rf cpio

step "ESO Kernel $V_linux (BORE $V_bore, 1000 Hz)"
unpack linux "linux-$V_linux.tar.xz"
patch -p1 -s < "/sources/$(ls /sources | grep -m1 'bore.*\.patch$')"
cp /sources/kernel/base.config .config
scripts/kconfig/merge_config.sh -m .config /sources/kernel/eso.config >/dev/null
make -s olddefconfig
# modules are compressed; depmod/modprobe must be able to read them, otherwise ship them uncompressed
if ! kmod --version | grep -q '+XZ'; then
    echo "kmod has no XZ support: modules stay uncompressed"
    scripts/config --disable MODULE_COMPRESS_XZ --disable MODULE_COMPRESS_ZSTD --disable MODULE_COMPRESS_GZIP \
                   --disable MODULE_COMPRESS
    make -s olddefconfig
fi
kmod --version | tail -1
for o in SCHED_BORE HZ_1000 MODULE_SIG_ALL DEBUG_INFO_NONE DEVTMPFS; do
    grep -q "^CONFIG_$o=[ym]" .config || { echo "config check failed: $o"; exit 1; }
done
export KBUILD_BUILD_USER=eso KBUILD_BUILD_HOST=esoos.dpdns.org KBUILD_BUILD_TIMESTAMP="ESO Kernel"
make -j"$(nproc)" bzImage modules >/dev/null
KV=$(make -s kernelrelease)
make INSTALL_MOD_STRIP=1 modules_install >/dev/null
cp arch/x86/boot/bzImage "/boot/vmlinuz-$KV"; cp System.map "/boot/System.map-$KV"; cp .config "/boot/config-$KV"
cd /sources; rm -rf linux
echo "kernel $KV: $(du -sh /boot/vmlinuz-$KV | cut -f1), modules $(du -sh /usr/lib/modules/$KV | cut -f1)"

step "ESO initramfs"
install -m755 /sources/files/eso-mkinitramfs /usr/sbin/eso-mkinitramfs
eso-mkinitramfs "$KV"

step "system configuration"
# service users for systemd (built with sysusers=false, so they must exist in /etc/passwd before first boot)
addsys() {  # name uid comment
    grep -q "^$1:" /etc/group  || echo "$1:x:$2:" >> /etc/group
    grep -q "^$1:" /etc/passwd || echo "$1:x:$2:$2:$3:/:/usr/bin/false" >> /etc/passwd
}
addsys systemd-journal-gateway 73 "systemd Journal Gateway"
addsys systemd-journal-remote  74 "systemd Journal Remote"
addsys systemd-journal-upload  75 "systemd Journal Upload"
addsys systemd-network         76 "systemd Network Management"
addsys systemd-resolve         77 "systemd Resolver"
addsys systemd-timesync        78 "systemd Time Synchronization"
addsys systemd-coredump        79 "systemd Core Dumper"
addsys systemd-oom             81 "systemd Userspace OOM Killer"
pwconv 2>/dev/null || true; grpconv 2>/dev/null || true
cat > /etc/os-release <<O
NAME="ESO OS"
PRETTY_NAME="ESO OS (ESO Base)"
ID=eso
VERSION_ID="base-1"
VERSION="ESO Base 1"
HOME_URL="https://esoos.dpdns.org"
BUG_REPORT_URL="https://esoos.dpdns.org/support/"
ANSI_COLOR="0;36"
O
ln -sf ../usr/lib/os-release /etc/os-release.lnk 2>/dev/null; rm -f /etc/os-release.lnk
cp /etc/os-release /usr/lib/os-release
echo "ESO OS (ESO Base) \\r \\l" > /etc/issue
echo eso > /etc/hostname
printf 'LANG=en_US.UTF-8\n' > /etc/locale.conf
printf 'KEYMAP=us\n' > /etc/vconsole.conf
cat > /etc/fstab <<F
# file system  mount  type  options  dump  fsck
LABEL=ESO-ROOT  /      ext4  defaults,noatime  1  1
LABEL=ESO-ESP   /boot/efi  vfat  umask=0077,nofail  0  2
F
mkdir -p /etc/systemd/network
printf '[Match]\nName=en* eth*\n\n[Network]\nDHCP=yes\n' > /etc/systemd/network/20-wired.network
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
cat > /etc/shells <<S
/bin/sh
/bin/bash
S
cat > /etc/profile <<'P'
export PATH=/usr/bin:/usr/sbin
export LANG=${LANG:-en_US.UTF-8}
[ "$PS1" ] && PS1='\u@\h:\w\$ '
P
# first boot: root has no password on the test image only; the ESO installer sets real accounts
passwd -d root >/dev/null
systemctl enable systemd-networkd systemd-resolved systemd-timesyncd >/dev/null 2>&1 || true
systemctl enable serial-getty@ttyS0.service >/dev/null 2>&1 || true
echo "ESO Base is bootable: kernel $KV"
