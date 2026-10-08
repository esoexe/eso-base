#!/bin/bash
# ESO Base stage 3c (root): the rest of the base system inside the chroot.
# PART=1: up to vim; PART=2: systemd onward (resumable from the part-1 checkpoint); default: both.
set -euo pipefail
H=$(dirname "$0")
case ${PART:-all} in
    1)   bash "$H/chroot-run.sh" sources-stage3c.list stage3c-chroot.sh ;;
    2)   bash "$H/chroot-run.sh" sources-stage3c.list stage3c2-chroot.sh ;;
    *)   bash "$H/chroot-run.sh" sources-stage3c.list stage3c-chroot.sh
         bash "$H/chroot-run.sh" sources-stage3c.list stage3c2-chroot.sh ;;
esac
