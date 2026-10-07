# ESO Base

The independent foundation of **ESO OS**: built entirely from the original upstream sources (GNU, kernel.org,
freedesktop, GNOME, Python), with no packages from Debian, Ubuntu, Arch or any other distribution.
ESO Base is still **Linux** (the ESO Kernel is a tuned Linux kernel), but every binary in it is compiled
by ESO's own build system, in ESO's own package format, managed by ESO's own package manager.

## Stages

| Stage | What it builds | Status |
|-------|----------------|--------|
| 1 | Cross toolchain: binutils, GCC, Linux headers (ESO Kernel 7.2.9), glibc, libstdc++ | in progress |
| 2 | Temporary tools (bash, coreutils, make, sed, tar, xz, python …) in a clean chroot | planned |
| 3 | Final system: toolchain rebuilt natively, systemd, util-linux, openssl, NetworkManager | planned |
| 4 | Graphics: Mesa, libinput, Xorg / Wayland, Hyprland | planned |
| 5 | Desktop stack: GLib, GTK 3/4, PyGObject, WebKitGTK, PipeWire | planned |
| 6 | ESO desktop + apps, installer, ISO | planned |

Packages are plain `.tar.zst` archives with a small `.ESOINFO` header, installed by `epm` (ESO package manager).

## Layout

- `bootstrap/stage1.sh` – the cross toolchain (LFS-style, target `x86_64-eso-linux-gnu`)
- `bootstrap/sources.list` – exact upstream URLs; `bootstrap/sources.lock` – SHA-256 pinned after the first verified build
- `.github/workflows/stage1.yml` – runs the stage on GitHub's free runners and publishes the toolchain artifact
