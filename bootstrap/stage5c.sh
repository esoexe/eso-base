#!/bin/bash
# ESO Base stage 5c (root): the ESO desktop session (X server, xfwm4, keys, notifications, fonts) inside the chroot
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ESO=${ESO:-/mnt/eso}
mkdir -p "$ESO/sources"; rm -rf "$ESO/sources/files"
cp -r "$HERE/files" "$ESO/sources/"
exec bash "$HERE/chroot-run.sh" sources-stage5c.list stage5c-chroot.sh
