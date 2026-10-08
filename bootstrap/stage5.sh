#!/bin/bash
# ESO Base stage 5 (root): GTK 3 desktop stack inside the chroot
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ESO=${ESO:-/mnt/eso}
mkdir -p "$ESO/sources"
exec bash "$HERE/chroot-run.sh" sources-stage5.list stage5-chroot.sh
