#!/bin/bash
# ESO Base stage 5f (root): WebKitGTK 4.1 inside the chroot (resumable)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ESO=${ESO:-/mnt/eso}
mkdir -p "$ESO/sources"
exec bash "$HERE/chroot-run.sh" sources-stage5f.list stage5f-chroot.sh
