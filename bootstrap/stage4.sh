#!/bin/bash
# ESO Base stage 4 (root): graphics stack inside the chroot (X11 libs, Wayland, Mesa, libinput, Xwayland)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ESO=${ESO:-/mnt/eso}
mkdir -p "$ESO/sources"
exec bash "$HERE/chroot-run.sh" sources-stage4.list stage4-chroot.sh
