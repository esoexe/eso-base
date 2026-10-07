#!/bin/bash
# ESO Base stage 3c (root): the rest of the base system inside the chroot
exec bash "$(dirname "$0")/chroot-run.sh" sources-stage3c.list stage3c-chroot.sh
