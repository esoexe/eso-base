# ESO Base

The independent foundation of **ESO OS**: built entirely from the original upstream sources (GNU, kernel.org,
freedesktop, GNOME, Python), with no packages from Debian, Ubuntu, Arch or any other distribution.
ESO Base is still **Linux** (the ESO Kernel is a tuned Linux kernel), but every binary in it is compiled
by ESO's own build system, in ESO's own package format, managed by ESO's own package manager.

## Stages

| Stage | What it builds | Status |
|-------|----------------|--------|
| 1 | Cross toolchain: binutils, GCC, Linux headers (ESO Kernel 7.2.9), glibc, libstdc++ | done |
| 2 | Temporary tools (bash, coreutils, make, sed, tar, xz, python ...) in a clean chroot | done |
| 3 | Final system: native toolchain, systemd, util-linux, OpenSSL, GRUB, the ESO Kernel; bootable ESO Core ISO | done |
| 4 | Graphics: X11 libraries, Wayland, Mesa, libinput, Xwayland, fonts | done |
| 4b | LLVM + Clang, SPIR-V tools, libclc, glslang, full Mesa (Intel, AMD, NVIDIA nouveau, virtual GPUs, Vulkan) | building |
| 5 | GTK 3 stack: GLib, GObject introspection, Cairo, Pango (Arabic shaping), librsvg, GTK 3, PyGObject, GtkSourceView, VTE | ready |
| 5b | Login (Linux-PAM, sudo), CA certificates, curl, polkit, NetworkManager + Wi-Fi, PipeWire sound, UPower, accounts | ready |
| 5c | Desktop session: X server, xfwm4, libwnck, small X tools, fonts | planned |
| 5d | Media and web: GStreamer, FFmpeg, libsoup, WebKitGTK (ESO Browser) | planned |
| 6 | ESO desktop + apps, Node.js, installer, ESO ISO with no Debian inside | planned |

Each stage runs on GitHub's free runners inside the ESO chroot (no network inside: every source is a pinned
download listed in `bootstrap/sources-*.list`) and hands the finished system to the next stage as an artifact.

Packages are plain `.tar.zst` archives with a small `.ESOINFO` header, installed by `epm` (ESO package manager).

## Layout

- `bootstrap/stage1.sh` – the cross toolchain (LFS-style, target `x86_64-eso-linux-gnu`)
- `bootstrap/sources.list` – exact upstream URLs; `bootstrap/sources.lock` – SHA-256 pinned after the first verified build
- `.github/workflows/stage1.yml` – runs the stage on GitHub's free runners and publishes the toolchain artifact
