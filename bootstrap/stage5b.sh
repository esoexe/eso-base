#!/bin/bash
# ESO Base stage 5b (root): login (PAM), network, polkit, sound and power services inside the chroot
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ESO=${ESO:-/mnt/eso}
mkdir -p "$ESO/sources"
exec bash "$HERE/chroot-run.sh" sources-stage5b.list stage5b-chroot.sh
