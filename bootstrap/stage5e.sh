#!/bin/bash
# ESO Base stage 5e (root): WebKitGTK dependencies (ICU, libsoup 3, TLS, web formats, sandbox, Ruby)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ESO=${ESO:-/mnt/eso}
mkdir -p "$ESO/sources"
exec bash "$HERE/chroot-run.sh" sources-stage5e.list stage5e-chroot.sh
