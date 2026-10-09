#!/bin/bash
# ESO Base stage 6b, INSIDE the chroot: Node.js LTS, linked to ESO Base's own OpenSSL, zlib and ICU (smaller, and
# security fixes to those libraries reach Node too). Runs the ESO Search engine and Ilyass' tooling; npm included.
set -euo pipefail
. /sources/versions.env
step() { echo; echo "=== $* ($(date -u +%H:%M:%S)) ==="; }
quiet() { "$@" > /tmp/build.log 2>&1 || { tail -80 /tmp/build.log; echo "FAILED: $*"; exit 1; }; }
export PKG_CONFIG_PATH=/usr/lib/pkgconfig:/usr/share/pkgconfig
if ! command -v node >/dev/null; then
    step "Node.js $V_nodejs ($(nproc) cores)"
    rm -rf /sources/node; mkdir -p /sources/node
    tar -xf "/sources/node-v$V_nodejs.tar.xz" -C /sources/node --strip-components=1; cd /sources/node
    quiet ./configure --prefix=/usr --shared-openssl --shared-zlib --with-intl=system-icu
    quiet make -j"$(nproc)"
    quiet make install
    cd /sources; rm -rf /sources/node
fi
step "smoke test"
printf '  node %s | npm %s\n' "$(node --version)" "$(npm --version)"
node - <<'JS'
const crypto = require("crypto"), zlib = require("zlib"), http = require("http"), assert = require("assert");
// OpenSSL: hashing + TLS ciphers available
assert.equal(crypto.createHash("sha256").update("ESO").digest("hex").length, 64);
assert.ok(crypto.getCiphers().includes("aes-256-gcm"));
// zlib round trip
assert.equal(zlib.gunzipSync(zlib.gzipSync("ESO Base")).toString(), "ESO Base");
// system ICU: Arabic + French formatting (ESO is EN/AR/FR)
const ar = new Intl.DateTimeFormat("ar-DZ", { month: "long", timeZone: "UTC" }).format(new Date(Date.UTC(2026, 9, 9)));
const fr = new Intl.NumberFormat("fr-FR").format(1234567.5);
assert.ok(/[\u0600-\u06FF]/.test(ar), "Arabic month name expected, got " + ar);
console.log("  ICU", process.versions.icu, "| OpenSSL", process.versions.openssl, "| ar:", ar, "| fr:", fr);
// a real local HTTP server + client round trip (what the ESO Search engine does)
const srv = http.createServer((q, r) => r.end("ok " + q.url)).listen(0, "127.0.0.1", () => {
  http.get({ host: "127.0.0.1", port: srv.address().port, path: "/eso" }, res => {
    let b = ""; res.on("data", d => b += d); res.on("end", () => { assert.equal(b, "ok /eso"); console.log("  http: ok"); srv.close(); });
  });
});
JS
step "stage 6b done"; du -sh /usr/lib/node_modules /usr/bin/node
