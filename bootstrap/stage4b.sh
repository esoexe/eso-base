#!/bin/bash
# ESO Base stage 4b (root): LLVM/Clang, SPIR-V, libclc, glslang and the full Mesa inside the chroot
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ESO=${ESO:-/mnt/eso}
mkdir -p "$ESO/sources"
exec bash "$HERE/chroot-run.sh" sources-stage4b.list stage4b-chroot.sh
