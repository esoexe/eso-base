#!/bin/bash
# ESO Base stage 3b (root): final glibc + toolchain inside the chroot
exec bash "$(dirname "$0")/chroot-run.sh" sources-stage3b.list stage3b-chroot.sh
