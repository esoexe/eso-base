#!/bin/bash
# ESO Base stage 5d (root): sound and video (FFmpeg, GStreamer, mpv, PulseAudio client, VA-API, Vulkan loader)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ESO=${ESO:-/mnt/eso}
mkdir -p "$ESO/sources"
exec bash "$HERE/chroot-run.sh" sources-stage5d.list stage5d-chroot.sh
