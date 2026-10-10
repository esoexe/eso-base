#!/bin/bash
# ESO Base stage 6c, INSIDE the chroot: ESO OS itself on ESO Base — no Debian anywhere.
#   login:    greetd + tuigreet (Rust, crates vendored on the host from their Cargo.lock), live autologin as "eso"
#   desktop:  the ESO desktop (the same eso-desktop package ESO 3.x installs, unpacked without dpkg and deployed by
#             its own eso-deploy-system.sh), JetBrainsMono Nerd Font, /etc/skel made by ESO's install.sh
#   system:   ESO's performance/limits/journald/polkit config, zram swap, first-boot cleanup, PAM names ESO expects
# All from upstream or ESO's own release files. No network inside the chroot: every source is pinned in
# sources-stage6c.list.
set -euo pipefail
. /sources/versions.env
step() { echo; echo "=== $* ($(date -u +%H:%M:%S)) ==="; }
unpack() { rm -rf "/sources/$1"; mkdir -p "/sources/$1"; tar -xf "/sources/$2" -C "/sources/$1" --strip-components=1; cd "/sources/$1"; }
done_() { cd /sources; rm -rf "/sources/$1"; }
quiet() { "$@" > /tmp/build.log 2>&1 || { tail -80 /tmp/build.log; echo "FAILED: $*"; exit 1; }; }
grp() { grep -q "^$1:" /etc/group || groupadd -r "$1"; }
export PKG_CONFIG_PATH=/usr/lib/pkgconfig:/usr/share/pkgconfig PATH=/opt/rust/bin:/usr/bin:/usr/sbin
# run a command as USER (no PAM needed inside the build chroot): asuser USER cmd...
asuser() { local u=$1; shift; python3 -c 'import os,pwd,sys
p=pwd.getpwnam(sys.argv[1]); os.initgroups(p.pw_name,p.pw_gid); os.setgid(p.pw_gid); os.setuid(p.pw_uid)
os.environ.update(HOME=p.pw_dir,USER=p.pw_name,LOGNAME=p.pw_name); os.execvp(sys.argv[2],sys.argv[2:])' "$u" "$@"; }
offline_cargo() { mkdir -p .cargo; printf '[source.crates-io]\nreplace-with = "vendored-sources"\n\n[source.vendored-sources]\ndirectory = "vendor"\n\n[net]\noffline = true\n' > .cargo/config.toml; }

# ───────────────────────────── login: greetd + tuigreet ─────────────────────────────
step "greetd $V_greetd + agreety (Rust, offline)"
unpack greetd "greetd-$V_greetd.tar.gz"; tar -xf /sources/greetd-vendor.tar; offline_cargo
CARGO_HOME=/tmp/cargo quiet cargo build --release --locked --offline
install -m755 target/release/greetd target/release/agreety /usr/bin/
sed 's|^ExecStart=greetd|ExecStart=/usr/bin/greetd|' greetd.service > /usr/lib/systemd/system/greetd.service
done_ greetd
step "tuigreet $V_tuigreet (Rust, offline)"
unpack tuigreet "tuigreet-$V_tuigreet.tar.gz"; tar -xf /sources/tuigreet-vendor.tar; offline_cargo
CARGO_HOME=/tmp/cargo quiet cargo build --release --locked --offline
install -m755 target/release/tuigreet /usr/bin/; done_ tuigreet; rm -rf /tmp/cargo
grp input; grp render; grp video; grp audio; grp netdev; grp sudo
id greeter >/dev/null 2>&1 || useradd -r -M -d /var/lib/greetd -s /usr/sbin/nologin -c "greetd greeter" greeter
usermod -aG video,render,input greeter
install -d -o greeter -g greeter -m755 /var/lib/greetd /var/cache/tuigreet

# ───────────────────────────── system config ─────────────────────────────
step "Python $V_python: the stdlib modules whose libraries came after stage 3c (sqlite3 for ESO Browser, ...)"
# same version + same configure as stage 3c; only extension modules that are missing get copied in
rm -rf /sources/pyx; mkdir -p /sources/pyx; tar -xf "/sources/Python-$V_python.tar.xz" -C /sources/pyx --strip-components=1
cd /sources/pyx
quiet ./configure --prefix=/usr --enable-shared --with-system-expat --without-static-libpython --without-ensurepip
quiet make -j"$(nproc)"
DYN=$(python3 -c 'import sysconfig; print(sysconfig.get_path("platstdlib") + "/lib-dynload")')
added=""
for so in build/lib.*/*.so; do
    [[ -e "$DYN/${so##*/}" ]] && continue
    install -m755 "$so" "$DYN/"; added+=" ${so##*/}"
done
cd /sources; rm -rf /sources/pyx
echo "  added:${added:- nothing}"
python3 -c 'import sqlite3; c = sqlite3.connect(":memory:"); print("  sqlite3", sqlite3.sqlite_version, "ok")'
python3 - <<'PY'
import importlib
for m in ("lzma", "bz2", "ctypes", "ssl", "readline", "curses", "uuid", "dbm.gnu", "zlib", "hashlib", "decimal"):
    try: importlib.import_module(m); print("   ", m, "ok")
    except Exception as e: print("   ", m, "MISSING:", e)
PY

step "ESO system config (overlay, PAM, zram, X)"
cp -a /sources/files/eso-overlay/. /
chmod 755 /usr/local/sbin/eso-firstboot /usr/libexec/eso-zram /usr/libexec/eso-selftest; chmod 440 /etc/sudoers.d/eso-live
chown -R root:root /etc/sudoers.d /etc/polkit-1/rules.d
# the PAM names ESO's apps use (Debian's), mapped onto ESO Base's stack; nullok = ESO's optional password works
cat > /etc/pam.d/common-auth <<'EOF'
auth      required    pam_unix.so nullok
EOF
for t in account session password; do echo "$t      include     system-$t" > /etc/pam.d/common-$t; done
cat > /etc/pam.d/greetd <<'EOF'
auth      requisite   pam_nologin.so
auth      include     common-auth
account   include     common-account
session   required    pam_env.so
session   required    pam_limits.so
session   include     common-session
password  include     common-password
EOF
# sudo/su for users with an empty password (ESO 3.1 optional password) behave like the login screen
[[ -f /etc/pam.d/sudo ]] && sed -i 's/^auth\( *\)include\( *\)system-auth/auth\1include\2common-auth/' /etc/pam.d/sudo
install -d /etc/X11; printf 'allowed_users=anybody\nneeds_root_rights=auto\n' > /etc/X11/Xwrapper.config
# the 3.10 session starts xcape for "tap Windows key = Start"; ESO Base has eso-supertap for exactly that
[[ -e /usr/bin/xcape ]] || printf '#!/bin/sh\n# ESO Base: xcape compatibility. A lone Super tap sends Ctrl+Escape (Start), as eso-lite-session asks.\n# xcape forks into the background and the session goes on; eso-supertap does not fork, so start it in the background.\n/usr/bin/eso-supertap >/dev/null 2>&1 &\nexit 0\n' > /usr/bin/xcape
chmod 755 /usr/bin/xcape

# ───────────────────────────── fonts ─────────────────────────────
step "JetBrainsMono Nerd Font $V_nerdfont (terminal + dock glyphs)"
install -d /usr/share/fonts/jetbrains-mono-nerd
tar -xJf /sources/JetBrainsMono.tar.xz -C /usr/share/fonts/jetbrains-mono-nerd --no-same-owner \
    JetBrainsMonoNerdFont-Regular.ttf JetBrainsMonoNerdFont-Bold.ttf JetBrainsMonoNerdFont-Italic.ttf \
    JetBrainsMonoNerdFont-BoldItalic.ttf
fc-cache -f >/dev/null

# ───────────────────────────── the ESO desktop ─────────────────────────────
step "ESO desktop $V_esodesktop (eso-desktop package, installed by ESO's own installer: no dpkg)"
python3 -c "import lzma, tarfile, hashlib, ssl" || { echo "FAILED: python3 lacks lzma/ssl (needed by ESO updates)"; exit 1; }
D=$(mktemp -d); cd "$D"; ar x "/sources/eso-desktop_${V_esodesktop}_all.deb"
tar -xf data.tar.* ./usr/share/eso/src/lib/eso/esobasepkg.py      # the installer comes from the package itself
cd /
# installs every file, records /var/lib/eso/pkgs/eso-desktop.{control,list} and runs its postinst (eso-deploy-system.sh)
ESO_BASE_PKG=1 python3 "$D/usr/share/eso/src/lib/eso/esobasepkg.py" install-local "/sources/eso-desktop_${V_esodesktop}_all.deb" \
    > /tmp/deploy.log 2>&1 || { tail -40 /tmp/deploy.log; echo "FAILED: installing eso-desktop"; exit 1; }
rm -rf "$D"; tail -1 /tmp/deploy.log
echo "  deployed: $(ls /usr/local/bin | wc -l) programs, $(ls /usr/local/lib/eso | wc -l) modules"
step "/etc/skel: a full per-user ESO setup made by ESO's install.sh"
SRC=/usr/share/eso/src; T=/tmp/eso-skel-home
rm -rf "$T"; install -d "$T"; cp -a /etc/skel/. "$T"/ 2>/dev/null || true
id esobuild >/dev/null 2>&1 || useradd -M -d "$T" -s /bin/bash esobuild
chown -R esobuild: "$T"
asuser esobuild bash -c "cd '$SRC' && HOME='$T' LANG=C.UTF-8 XDG_RUNTIME_DIR=/tmp bash install.sh --dotfiles-only --both --yes" \
    > /tmp/install.log 2>&1 || { tail -40 /tmp/install.log; cat "$T"/.local/share/eso/install-*.log 2>/dev/null | tail -40; echo "FAILED: install.sh"; exit 1; }
userdel esobuild 2>/dev/null || true
rm -f "$T"/.config/eso/{profile,tier,source,wallpaper} "$T"/.config/hypr/hyprland.conf "$T"/.config/hypr/hyprland.lua
[[ -f $SRC/dotfiles/hypr/eso/hw.lua ]] && install -D "$SRC/dotfiles/hypr/eso/hw.lua" "$T/.config/hypr/eso/hw.lua"
[[ -f $SRC/dotfiles/hypr/eso-conf/hw.conf ]] && install -D "$SRC/dotfiles/hypr/eso-conf/hw.conf" "$T/.config/hypr/eso-conf/hw.conf"
rm -rf "$T"/.local/share/eso/backup* "$T"/.local/share/eso/install-*.log "$T"/.local/share/eso/last-backup "$T"/.cache
for d in Desktop Documents Downloads Music Pictures Public Templates Videos; do rmdir "$T/$d" 2>/dev/null || true; done
rm -f "$T"/.config/user-dirs.dirs "$T"/.config/user-dirs.locale
grep -rlF "$T" "$T" 2>/dev/null | while read -r f; do
    case "$f" in
        */.local/share/eso/manifest) sed -i "s|$T|@HOME@|g" "$f" ;;
        *) sed -i "s|$T|\$HOME|g" "$f" ;;
    esac
done
chown -R root:root "$T"
[[ -f $SRC/system/eso-link-home.sh ]] && bash "$SRC/system/eso-link-home.sh" "$T"
cp -a "$T"/. /etc/skel/; rm -rf "$T"
echo "  /etc/skel: $(find /etc/skel -type f | wc -l) files"

# ───────────────────────────── identity, users, services ─────────────────────────────
step "ESO OS identity, live user, services"
ESOV=$(cat /usr/share/eso/VERSION 2>/dev/null || echo "$V_esodesktop")
cat > /usr/lib/os-release <<EOF
NAME="ESO OS"
ID=eso
PRETTY_NAME="ESO OS ${ESOV%.0} (ESO Base)"
VERSION="${ESOV} (ESO Base)"
VERSION_ID="${ESOV}"
BUILD_ID="$(date -u +%Y%m%d)"
HOME_URL="https://esoos.dpdns.org"
LOGO=eso-logo
EOF
ln -sf ../usr/lib/os-release /etc/os-release
echo "ESO OS ${ESOV%.0} \\n \\l" > /etc/issue
echo eso-os > /etc/hostname
install -d /etc/default; sed -i 's|^#\? *SHELL=.*|SHELL=/usr/bin/zsh|' /etc/default/useradd 2>/dev/null || true
grep -q '^SHELL=' /etc/default/useradd 2>/dev/null || echo 'SHELL=/usr/bin/zsh' >> /etc/default/useradd
touch /etc/subuid /etc/subgid
install -d /etc/gtk-3.0
printf '[Settings]\ngtk-theme-name=ESO-Metal\ngtk-icon-theme-name=ESO-Metal\ngtk-application-prefer-dark-theme=1\ngtk-font-name=Inter 10\n' > /etc/gtk-3.0/settings.ini
# live user "eso": no password (autologin; sudo without password only in the live system, see /etc/sudoers.d/eso-live)
id eso >/dev/null 2>&1 || useradd -m -s /usr/bin/zsh -c "ESO Live" -G sudo,audio,video,input,render,netdev eso
passwd -d eso >/dev/null
for u in greetd eso-firstboot eso-zram eso-selftest eso-selftest-console NetworkManager earlyoom; do
    systemctl enable "$u.service" >/tmp/en.log 2>&1 || { echo "  WARNING: systemctl enable $u failed:"; cat /tmp/en.log; }
done
for l in multi-user.target.wants/eso-selftest.service sysinit.target.wants/eso-selftest-console.service; do
    [[ -e /etc/systemd/system/$l ]] || { mkdir -p "/etc/systemd/system/${l%/*}"; ln -sf "/usr/lib/systemd/system/${l##*/}" "/etc/systemd/system/$l"; echo "  linked $l by hand"; }
done
# ESO OS: NetworkManager owns the network (Wi-Fi, tray, Settings); ESO Core's systemd-networkd would fight it
systemctl disable systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/*.wants/systemd-networkd*.service /etc/systemd/system/*.wants/systemd-networkd.socket
for d in /etc/systemd/system/*.wants; do echo "  ${d##*/}: $(ls "$d" | tr '\n' ' ')"; done
ln -sf /usr/lib/systemd/system/greetd.service /etc/systemd/system/display-manager.service
# Plymouth is not in the initramfs yet: its late start in the real root leaves "plymouth --wait" holding the boot
# (graphical.target never reached). Off until it is wired into the initramfs; ESO's intro animates the sign-in.
systemctl mask plymouth-start.service plymouth-quit-wait.service plymouth-quit.service plymouth-read-write.service \
    plymouth-switch-root.service systemd-ask-password-plymouth.path >/dev/null 2>&1 || true
systemctl set-default graphical.target >/dev/null 2>&1 || ln -sf /usr/lib/systemd/system/graphical.target /etc/systemd/system/default.target
systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service >/dev/null 2>&1 || true
for s in "$SRC/system/tune/install-tune.sh" "$SRC/system/account/install-account.sh" "$SRC/system/tune/slim-services.sh"; do
    [[ -f $s ]] || continue
    bash "$s" > /tmp/s.log 2>&1 || { echo "  note: ${s##*/} reported a problem:"; tail -5 /tmp/s.log; }
done
glib-compile-schemas /usr/share/glib-2.0/schemas 2>/dev/null || true
gtk-update-icon-cache -qf /usr/share/icons/hicolor 2>/dev/null || true

# ───────────────────────────── ESO updates on ESO Base ─────────────────────────────
step "ESO updates: eso-update runs in ESO Base mode (no apt/dpkg), signing key + verifier present"
command -v gpgv >/dev/null || { echo "FAILED: gpgv missing (ESO updates verify signatures with it)"; exit 1; }
[[ -s /usr/share/keyrings/eso-archive-keyring.pgp ]] || { echo "FAILED: ESO signing key missing"; exit 1; }
python3 - <<'PY' || { echo "FAILED: eso-update ESO Base mode"; exit 1; }
import importlib.machinery, importlib.util, sys
l = importlib.machinery.SourceFileLoader("eu", "/usr/local/libexec/eso-update")
s = importlib.util.spec_from_loader("eu", l); m = importlib.util.module_from_spec(s); l.exec_module(m)
assert m.BASE, "eso-update did not detect ESO Base"
v = m.installed_version()
assert v and m.vcmp(v, "3.10.0") > 0, f"installed version {v!r}"
print(f"  eso-update: ESO Base mode, ESO {v} installed, kernel updates {'on' if m.kernel_allowed() else 'off (built in)'}")
PY

# ───────────────────────────── smoke test ─────────────────────────────
step "smoke test: ESO's own programs start on ESO Base (Xvfb, no Debian)"
for f in /usr/bin/greetd /usr/bin/tuigreet /usr/local/bin/eso-auto-session /usr/local/bin/eso-lite-session \
         /usr/local/bin/eso-settings /usr/local/bin/eso-browser /usr/local/lib/eso/esoui.py /etc/greetd/config.toml; do
    [[ -e $f ]] || { echo "missing $f"; exit 1; }
done
greetd --help >/dev/null 2>&1 || true
tuigreet --version
PYTHONPATH=/usr/local/lib/eso python3 -c "
import esoui
print('  ESO', esoui.VERSION, 'Python modules import on ESO Base')"
if command -v Xvfb >/dev/null; then
    export DISPLAY=:12 XDG_RUNTIME_DIR=/tmp/xdg-eso; mkdir -p -m700 $XDG_RUNTIME_DIR; chown eso: $XDG_RUNTIME_DIR
    export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 WEBKIT_DISABLE_DMABUF_RENDERER=1 LIBGL_ALWAYS_SOFTWARE=1
    Xvfb :12 -screen 0 1280x800x24 -nolisten tcp > /tmp/xvfb.log 2>&1 & XP=$!
    for i in $(seq 50); do [[ -S /tmp/.X11-unix/X12 ]] && break; sleep 0.2; done
    bad=0
    for app in eso-settings eso-browser; do
        rc=0; asuser eso dbus-run-session -- timeout 25 "/usr/local/bin/$app" > /tmp/app.log 2>&1 || rc=$?
        if [[ $rc -eq 124 ]] && ! grep -q "Traceback" /tmp/app.log; then echo "  $app: running after 25 s, no errors"
        else echo "  $app: exit $rc"; tail -25 /tmp/app.log; bad=1; fi
    done
    kill $XP 2>/dev/null || true; rm -rf /tmp/xdg-eso /tmp/.X11-unix/X12 /tmp/.X12-lock
    rm -rf /home/eso/.cache; chown -R eso: /home/eso
    [[ $bad = 0 ]] || { echo "FAILED: an ESO app did not start"; exit 1; }
fi
step "stage 6c done"; du -sh /usr /usr/share/eso /etc/skel
