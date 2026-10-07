# shared helpers for ESO Base stages 3+ (sourced)
step() { echo; echo "=== $* ($(date -u +%H:%M:%S)) ==="; }
# GNU's main server is often slow from CI: try it briefly, then official mirrors (same files, checked by SHA-256)
fetch() {
    local url=$1 out=$2 u
    for u in "${url/https:\/\/ftp.gnu.org\/gnu\//https://mirrors.kernel.org/gnu/}" \
             "${url/https:\/\/ftp.gnu.org\/gnu\//https://ftpmirror.gnu.org/}" "$url"; do
        if curl -fsSL --retry 2 --connect-timeout 10 --max-time 900 -o "$out.part" "$u"; then mv "$out.part" "$out"; return 0; fi
        echo "download failed: $u" >&2
    done
    rm -f "$out.part"; return 1
}
# fetch_list LIST DIR: download + verify against sources.lock; writes VERSIONS (name=ver) to DIR/versions.env
fetch_list() {
    local list=$1 dir=$2 name ver url f fn sum pin
    mkdir -p "$dir"; touch "$HERE/sources.lock"
    while read -r name ver url; do
        [[ -z "$name" || "$name" == \#* ]] && continue
        fn=${url##*/}
        if [[ $fn == download ]]; then fn=${url%/download}; fn=${fn##*/}; fi    # sourceforge .../file.tar.xz/download
        f=$dir/$fn
        [[ -s "$f" ]] || fetch "$url" "$f"
        sum=$(sha256sum "$f" | cut -d' ' -f1)
        pin=$(awk -v n="$fn" '$2==n{print $1}' "$HERE/sources.lock")
        if [[ -n "$pin" && "$pin" != "$sum" ]]; then echo "CHECKSUM MISMATCH: $fn"; exit 1; fi
        if [[ -z "$pin" ]]; then echo "$sum  $fn" >> "$HERE/sources.lock"; fi
        echo "V_${name}=$ver" >> "$dir/versions.env"
    done < "$HERE/$list"
}
