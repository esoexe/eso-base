#!/bin/bash
# ESO Base stage 5 (root): GTK 3 desktop stack inside the chroot
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ESO=${ESO:-/mnt/eso}
. "$HERE/lib.sh"
mkdir -p "$ESO/sources"
# librsvg is Rust and its release tarball has no vendored crates, but the chroot has no network.  Download the pinned
# sources now, then let cargo (from the same pinned Rust release) fetch exactly the crates in librsvg's Cargo.lock —
# every crate is checked against the checksum in that lock file — so cargo can build offline inside the chroot.
fetch_list sources-stage5.list "$ESO/sources"          # chroot-run.sh verifies these again (no second download)
. "$ESO/sources/versions.env"
W=$(mktemp -d)
tar -xf "$ESO/sources/rust-$V_rust-x86_64-unknown-linux-gnu.tar.xz" -C "$W" --wildcards '*/cargo/bin/cargo' --strip-components=3
tar -xf "$ESO/sources/librsvg-$V_librsvg.tar.xz" -C "$W"
step "vendoring librsvg's Rust crates (Cargo.lock pinned)"
(cd "$W/librsvg-$V_librsvg" && CARGO_HOME="$W/home" "$W/cargo" vendor --locked --versioned-dirs vendor > /dev/null)
tar -cf "$ESO/sources/librsvg-vendor.tar" -C "$W/librsvg-$V_librsvg" vendor
echo "  $(ls "$W/librsvg-$V_librsvg/vendor" | wc -l) crates"
rm -rf "$W"
exec bash "$HERE/chroot-run.sh" sources-stage5.list stage5-chroot.sh
