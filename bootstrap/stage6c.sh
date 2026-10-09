#!/bin/bash
# ESO Base stage 6c (root): ESO OS on ESO Base — greetd login, the ESO desktop, system config
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ESO=${ESO:-/mnt/eso}
. "$HERE/lib.sh"
mkdir -p "$ESO/sources"; rm -rf "$ESO/sources/files"; cp -r "$HERE/files" "$ESO/sources/"
# greetd and tuigreet are Rust and the chroot has no network: download the pinned sources, then let cargo (ESO Base's
# own, from the official rust-lang.org release in /opt/rust, which runs on any glibc) fetch exactly the crates in
# each Cargo.lock — every crate is checked against the lock file's checksum — so the chroot builds offline.
fetch_list sources-stage6c.list "$ESO/sources"
. "$ESO/sources/versions.env"
CARGO=$ESO/opt/rust/bin/cargo; [[ -x $CARGO ]] || { echo "no cargo in ESO Base (stage 5)"; exit 1; }
W=$(mktemp -d)
for p in "greetd-$V_greetd" "tuigreet-$V_tuigreet"; do
    step "vendoring ${p%-*}'s Rust crates (Cargo.lock pinned)"
    mkdir -p "$W/$p"; tar -xf "$ESO/sources/$p.tar.gz" -C "$W/$p" --strip-components=1
    (cd "$W/$p" && PATH="$ESO/opt/rust/bin:$PATH" CARGO_HOME="$W/home" "$CARGO" vendor --locked --versioned-dirs vendor > /dev/null)
    tar -cf "$ESO/sources/${p%-*}-vendor.tar" -C "$W/$p" vendor
    echo "  $(ls "$W/$p/vendor" | wc -l) crates"
done
rm -rf "$W"
exec bash "$HERE/chroot-run.sh" sources-stage6c.list stage6c-chroot.sh
