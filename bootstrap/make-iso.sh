#!/bin/bash
# bootstrap/make-iso.sh OUT.iso (root): the ESO Core live ISO from the ESO Base tree in $ESO.
# Boots on BIOS and UEFI, from a DVD or written raw to a USB stick (hybrid). Everything inside the ISO is ESO's own
# build (kernel, initramfs, GRUB, systemd ...); the host only packs it (xorriso, mksquashfs, mtools).
set -euo pipefail
# ESO_ISO_EDITION=core (default): ESO Core, root console.  ESO_ISO_EDITION=os: ESO OS with the ESO desktop (stage 6c).
ESO=${ESO:-/mnt/eso}; ED=${ESO_ISO_EDITION:-core}
case $ED in
    core) ISO=${1:-eso-core-x86_64.iso}; LABEL=ESO_CORE; NAME="ESO Core"; SQ=eso-core ;;
    os)   ISO=${1:-eso-os-x86_64.iso};   LABEL=ESO_OS;   NAME="ESO OS";   SQ=eso-os ;;
    *)    echo "ESO_ISO_EDITION must be core or os"; exit 1 ;;
esac
W=$(mktemp -d)
# kernel file systems for the chroot steps (eso-mkinitramfs and grub-mkimage need /dev/null, /proc ...)
mnt() { mkdir -p "$ESO"/{dev,proc,sys,run}; mount --bind /dev "$ESO/dev"; mount -t proc proc "$ESO/proc"
        mount -t sysfs sysfs "$ESO/sys"; mount -t tmpfs tmpfs "$ESO/run"; }
umnt() { local m; for m in dev/pts dev proc sys run; do if mountpoint -q "$ESO/$m"; then umount -l "$ESO/$m"; fi; done; }
trap 'umnt; rm -rf "$W"' EXIT
KV=$(ls "$ESO/usr/lib/modules" | sed -n 1p)
[[ -f $ESO/boot/vmlinuz-$KV && -f $ESO/boot/initrd.img-$KV ]] || { echo "kernel/initramfs $KV missing"; exit 1; }
mkdir -p "$W"/iso/{live,boot/grub}

# --- live system tweaks (only in the ISO; the disk image keeps its own fstab) ---
cp "$ESO/etc/fstab" "$W/fstab.disk"
printf '# ESO Core live: the root is a RAM overlay on the read-only medium (see /run/eso)\n' > "$ESO/etc/fstab"
if [[ $ED == core ]]; then
echo eso-core > "$ESO/etc/hostname"
cat > "$ESO/etc/issue" <<'I'

  ESO Core (live test build) - \r on \l
  Log in as "root" (no password in this test build).

I
fi
# initramfs with live support (eso-mkinitramfs knows eso.live)
mnt
chroot "$ESO" /usr/bin/env -i PATH=/usr/bin:/usr/sbin bash -c "eso-mkinitramfs '$KV' /boot/initrd.img-$KV" >/dev/null
# the initramfs must contain /init and a shell, or the kernel panics with "No working init found"
chroot "$ESO" /usr/bin/env -i PATH=/usr/bin:/usr/sbin bash -c "
  f=/boot/initrd.img-$KV; d=\$(mktemp -d); cd \$d
  { zstd -dc \$f 2>/dev/null || xz -dc \$f 2>/dev/null || gzip -dc \$f 2>/dev/null || cat \$f; } | cpio -id --quiet 2>/dev/null
  ok=1; for x in init bin/sh; do [ -e \$x ] || { echo \"initramfs is missing /\$x\"; ok=0; }; done
  echo \"initramfs: \$(find . | wc -l) files\"; cd /; rm -rf \$d; [ \$ok = 1 ]"
umnt
cp "$ESO/boot/vmlinuz-$KV" "$W/iso/boot/vmlinuz"; cp "$ESO/boot/initrd.img-$KV" "$W/iso/boot/initrd.img"

# --- root filesystem ---
mksquashfs "$ESO" "$W/iso/live/$SQ.squashfs" -comp zstd -Xcompression-level 19 -noappend -quiet -no-progress \
    -wildcards -e sources 'proc/*' 'sys/*' 'dev/*' 'run/*' 'tmp/*' 'var/cache/*' 'root/.cache'
cp "$W/fstab.disk" "$ESO/etc/fstab"

# --- GRUB (ESO's own build): BIOS El Torito + UEFI, one menu ---
cat > "$W/early.cfg" <<E
search --no-floppy --set=root --label $LABEL
set prefix=(\$root)/boot/grub
E
MODS="iso9660 part_msdos part_gpt fat ext2 normal search search_label linux configfile echo ls cat test true all_video gzio"
cp "$W/early.cfg" "$ESO/tmp/early.cfg"
mnt
chroot "$ESO" /usr/bin/env -i PATH=/usr/bin:/usr/sbin bash -c "
  grub-mkimage -O i386-pc-eltorito -c /tmp/early.cfg -p /boot/grub -o /tmp/eltorito.img biosdisk $MODS &&
  grub-mkimage -O x86_64-efi       -c /tmp/early.cfg -p /boot/grub -o /tmp/bootx64.efi $MODS efi_gop efi_uga"
umnt
mv "$ESO/tmp/eltorito.img" "$W/iso/boot/grub/"; mv "$ESO/tmp/bootx64.efi" "$W/"; rm -f "$ESO/tmp/early.cfg"
cp -r "$ESO/usr/lib/grub/i386-pc" "$ESO/usr/lib/grub/x86_64-efi" "$W/iso/boot/grub/"
rm -f "$W"/iso/boot/grub/*/*.{image,module,exec} 2>/dev/null || true
mkdir -p "$W/iso/EFI/BOOT"; cp "$W/bootx64.efi" "$W/iso/EFI/BOOT/BOOTX64.EFI"
truncate -s 8M "$W/efi.img"; mkfs.vfat -n ESOEFI "$W/efi.img" >/dev/null
mmd -i "$W/efi.img" ::/EFI ::/EFI/BOOT; mcopy -i "$W/efi.img" "$W/bootx64.efi" ::/EFI/BOOT/BOOTX64.EFI
# ESO OS: quiet boot with the ESO animation (plymouth, from the initramfs); ESO Core keeps the plain console
SPLASHARGS="loglevel=3"; [[ $ED == os ]] && SPLASHARGS="quiet loglevel=3 splash vt.global_cursor_default=0 udev.log_level=3"
cat > "$W/iso/boot/grub/grub.cfg" <<G
set timeout=2
set default=0
insmod all_video
# the boot animation needs a graphics mode handed to the kernel: UEFI keeps the firmware's (GOP) mode, BIOS asks VESA
if [ "\$grub_platform" = "efi" ]; then set gfxpayload=keep; else set gfxpayload=1024x768x32,1024x768,auto; fi
menuentry "$NAME (live)" {
    linux /boot/vmlinuz eso.live eso.label=$LABEL $SPLASHARGS console=ttyS0,115200 console=tty0
    initrd /boot/initrd.img
}
menuentry "$NAME (live, safe graphics)" {
    linux /boot/vmlinuz eso.live eso.label=$LABEL loglevel=3 nomodeset console=ttyS0,115200 console=tty0
    initrd /boot/initrd.img
}
G
echo "$NAME, ESO Base kernel $KV, built $(date -u +%F)" > "$W/iso/$SQ.txt"

# --- hybrid ISO (DVD + USB, BIOS + UEFI) ---
xorriso -as mkisofs -r -J -V "$LABEL" -o "$ISO" \
    --grub2-mbr "$ESO/usr/lib/grub/i386-pc/boot_hybrid.img" -partition_offset 16 --mbr-force-bootable \
    -append_partition 2 0xef "$W/efi.img" -appended_part_as_gpt \
    -c boot/boot.cat \
    -b boot/grub/eltorito.img -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info \
    -eltorito-alt-boot -e --interval:appended_partition_2:all:: -no-emul-boot \
    "$W/iso" 2>&1 | grep -v "^xorriso : UPDATE" | tail -3
echo "ISO: $ISO ($(du -h "$ISO" | cut -f1), kernel $KV)"
