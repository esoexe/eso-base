#!/bin/bash
# ESO Base stage 3a (root): chroot in, build gettext, bison, perl, Python, texinfo, util-linux
exec bash "$(dirname "$0")/chroot-run.sh" sources-stage3.list stage3-chroot.sh
