#!/bin/bash
# ESO Base stage 3d (root): ESO Kernel + initramfs + configuration inside the chroot
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ESO=${ESO:-/mnt/eso}
mkdir -p "$ESO/sources"; rm -rf "$ESO/sources/kernel" "$ESO/sources/files"
cp -r "$HERE/kernel" "$HERE/files" "$ESO/sources/"
exec bash "$HERE/chroot-run.sh" sources-stage3d.list stage3d-chroot.sh
