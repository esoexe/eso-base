#!/bin/bash
# ESO Base stage 6b (root): Node.js LTS inside the chroot
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ESO=${ESO:-/mnt/eso}
mkdir -p "$ESO/sources"
exec bash "$HERE/chroot-run.sh" sources-stage6b.list stage6b-chroot.sh
