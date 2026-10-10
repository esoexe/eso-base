#!/bin/bash
# ESO Base stage 6d (root): Flatpak, Vulkan shaders for the video player, the tools ESO's apps call
# (OCR, screenshots, Bluetooth, power profiles, firewall, antivirus, git, ssh, 7-Zip, ...).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ESO=${ESO:-/mnt/eso}
. "$HERE/lib.sh"
mkdir -p "$ESO/sources"; rm -rf "$ESO/sources/files"; cp -r "$HERE/files" "$ESO/sources/"
fetch_list sources-stage6d.list "$ESO/sources"
. "$ESO/sources/versions.env"
# ripgrep is Rust and the chroot has no network: ESO Base's own cargo fetches exactly the crates in its Cargo.lock
# (each checked against the lock file's checksum). ClamAV ships its crates vendored in the release tarball.
CARGO=$ESO/opt/rust/bin/cargo; [[ -x $CARGO ]] || { echo "no cargo in ESO Base (stage 5)"; exit 1; }
W=$(mktemp -d)
for p in "ripgrep-$V_ripgrep"; do
    step "vendoring ${p%-*}'s Rust crates (Cargo.lock pinned)"
    mkdir -p "$W/$p"; tar -xf "$ESO/sources/$p.tar.gz" -C "$W/$p" --strip-components=1
    (cd "$W/$p" && PATH="$ESO/opt/rust/bin:$PATH" CARGO_HOME="$W/home" "$CARGO" vendor --locked --versioned-dirs vendor > /dev/null)
    tar -cf "$ESO/sources/${p%-*}-vendor.tar" -C "$W/$p" vendor
    echo "  $(ls "$W/$p/vendor" | wc -l) crates"
done
rm -rf "$W"
exec bash "$HERE/chroot-run.sh" sources-stage6d.list stage6d-chroot.sh
