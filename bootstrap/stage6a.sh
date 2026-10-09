#!/bin/bash
# ESO Base stage 6a (root): the system apps the ESO desktop calls (GnuPG, zsh, poppler, plymouth, polkit agent, ...)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ESO=${ESO:-/mnt/eso}
mkdir -p "$ESO/sources"
exec bash "$HERE/chroot-run.sh" sources-stage6a.list stage6a-chroot.sh
