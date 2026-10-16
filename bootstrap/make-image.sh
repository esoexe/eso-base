#!/bin/bash
# bootstrap/make-image.sh OUT.img (root): put the ESO Base tree in $ESO onto a bootable disk image (GPT, BIOS + UEFI GRUB)
set -euo pipefail
ESO=${ESO:-/mnt/eso}; IMG=${1:-eso-base.img}; SIZE=${SIZE:-8G}
rm -f "$IMG"; truncate -s "$SIZE" "$IMG"
sfdisk -q "$IMG" <<P
label: gpt
size=2MiB, type=21686148-6449-6E6F-744E-656564454649, name=bios
size=200MiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name=esp
type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709, name=root
P
LOOP=$(losetup --show -fP "$IMG")
partx -a "$LOOP" 2>/dev/null || true; udevadm settle 2>/dev/null || true
for n in 1 2 3; do      # partition nodes: udev normally creates them; build hosts without udev get them from /sys
    b=$(basename "$LOOP")p$n
    [[ -b /dev/$b ]] || { [[ -r /sys/class/block/$b/dev ]] && mknod "/dev/$b" b $(tr ':' ' ' < "/sys/class/block/$b/dev"); }
done
M=$(mktemp -d)
cleanup() { umount -R "$M" 2>/dev/null || true; losetup -d "$LOOP" 2>/dev/null || true; }
trap cleanup EXIT
mkfs.vfat -F32 -n ESO-ESP "${LOOP}p2" >/dev/null
mkfs.ext4 -q -L ESO-ROOT "${LOOP}p3"
mount "${LOOP}p3" "$M"
tar -C "$ESO" --exclude=./sources --exclude=./proc --exclude=./sys --exclude=./dev --exclude=./run -cpf - . | tar -C "$M" -xpf -
mkdir -p "$M"/{proc,sys,dev,run,boot/efi}
mount "${LOOP}p2" "$M/boot/efi"
for d in dev proc sys; do mount --rbind /$d "$M/$d"; mount --make-rslave "$M/$d"; done
KV=$(ls "$M/usr/lib/modules" | head -1)
chroot "$M" /usr/bin/env -i PATH=/usr/bin:/usr/sbin bash -c "
  grub-install --target=i386-pc --boot-directory=/boot '$LOOP' &&
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --boot-directory=/boot --removable --no-nvram"
cat > "$M/boot/grub/grub.cfg" <<G
set timeout=0
set timeout_style=hidden
set default=0
insmod part_gpt
insmod ext2
insmod all_video
# BIOS: a 32-bit (or 16-bit) VESA mode first - Xorg's fallback driver (fbdev, for GPUs without a kernel driver) cannot
# use packed 24-bit firmware framebuffers, which "1024x768"/"auto" pick on many older video BIOSes
if [ "\$grub_platform" = "efi" ]; then set gfxpayload=keep; else set gfxpayload=1024x768x32,1280x1024x32,1366x768x32,1280x800x32,800x600x32,640x480x32,1024x768x16,800x600x16,auto; fi
search --no-floppy --label ESO-ROOT --set=root
menuentry "ESO OS" {
    linux /boot/vmlinuz-$KV root=LABEL=ESO-ROOT ro preempt=full quiet loglevel=3 splash vt.global_cursor_default=0 udev.log_level=3 console=ttyS0,115200 console=tty0
    initrd /boot/initrd.img-$KV
}
G
sync
echo "image: $IMG ($(du -h "$IMG" | cut -f1) used, kernel $KV)"
