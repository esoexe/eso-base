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
chmod 755 /usr/local/sbin/eso-firstboot /usr/libexec/eso-zram /usr/libexec/eso-selftest /usr/libexec/eso-splash-quit /usr/libexec/eso-uitest \
      /usr/libexec/eso-session-run; chmod 440 /etc/sudoers.d/eso-live
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
# pam_unix checks the password of a non-root program (ESO Lock, the session's own polkit agent ...) through
# unix_chkpwd, which must run as root to read /etc/shadow. Upstream Linux-PAM installs it without the setuid bit
# (distributions add it), so the lock screen refused every password. unix_chkpwd only answers for the caller's own
# account.
CHK=$(command -v unix_chkpwd || ls /usr/sbin/unix_chkpwd /sbin/unix_chkpwd 2>/dev/null | head -1)
[[ -n $CHK ]] || { echo "FAILED: unix_chkpwd missing (Linux-PAM)"; exit 1; }
chown root:root "$CHK"; chmod 4755 "$CHK"; ls -l "$CHK"
[[ -f /etc/pam.d/sudo ]] && sed -i 's/^auth\( *\)include\( *\)system-auth/auth\1include\2common-auth/' /etc/pam.d/sudo
# OCR: tesseract built with CMake has no built-in data folder; without TESSDATA_PREFIX it searches the CURRENT
# directory, so every ESO app (Snip, Amenokal) got no languages and an empty result. One small wrapper fixes every
# caller; an explicit TESSDATA_PREFIX or --tessdata-dir still wins.
if [[ -x /usr/bin/tesseract && ! -e /usr/libexec/tesseract.bin ]] && ! grep -q "ESO-TESSDATA" /usr/bin/tesseract 2>/dev/null; then
    mv /usr/bin/tesseract /usr/libexec/tesseract.bin
    printf '#!/bin/sh\n# ESO-TESSDATA: tesseract with its language data (ESO Base)\n: "${TESSDATA_PREFIX:=/usr/share/tessdata}"\nexport TESSDATA_PREFIX\nexec /usr/libexec/tesseract.bin "$@"\n' > /usr/bin/tesseract
    chmod 755 /usr/bin/tesseract
fi
install -d /usr/lib/environment.d; echo 'TESSDATA_PREFIX=/usr/share/tessdata' > /usr/lib/environment.d/90-eso-tessdata.conf
(cd / && tesseract --list-langs 2>&1 | tr '\n' ' '); echo
install -d /etc/X11; printf 'allowed_users=anybody\nneeds_root_rights=auto\n' > /etc/X11/Xwrapper.config
# the 3.10 session starts xcape for "tap Windows key = Start"; ESO Base has eso-supertap for exactly that
[[ -e /usr/bin/xcape ]] || printf '#!/bin/sh\n# ESO Base: xcape compatibility. A lone Super tap sends Ctrl+Escape (Start), as eso-lite-session asks.\n# xcape forks into the background and the session goes on; eso-supertap does not fork, so start it in the background.\n/usr/bin/eso-supertap >/dev/null 2>&1 &\nexit 0\n' > /usr/bin/xcape
chmod 755 /usr/bin/xcape
# no feh / xwallpaper on ESO Base: without a root painter the screen stays black between the boot animation and
# eso-shell's first frame (~3 s). eso-rootpaint paints the wallpaper in a few ms; as "xwallpaper" eso-wallpaper uses it.
gcc -O2 -Wall -o /usr/bin/eso-rootpaint /sources/files/eso-rootpaint.c -ljpeg -lX11
chmod 755 /usr/bin/eso-rootpaint; ln -sf eso-rootpaint /usr/bin/xwallpaper

# ───────────────────────────── fonts ─────────────────────────────
step "JetBrainsMono Nerd Font $V_nerdfont (terminal + dock glyphs)"
install -d /usr/share/fonts/jetbrains-mono-nerd
tar -xJf /sources/JetBrainsMono.tar.xz -C /usr/share/fonts/jetbrains-mono-nerd --no-same-owner \
    JetBrainsMonoNerdFont-Regular.ttf JetBrainsMonoNerdFont-Bold.ttf JetBrainsMonoNerdFont-Italic.ttf \
    JetBrainsMonoNerdFont-BoldItalic.ttf
fc-cache -f >/dev/null

# ───────────────────────────── compositor: picom ─────────────────────────────
# ESO on Debian drew its windows through picom (vsync, no repaint trails, Ultra fades/zoom). ESO Base builds the same
# picom (12.5, Debian 13's version, which ESO's picom configs are tuned for). eso-perf runs it on PCs with a real GPU;
# VMs and PCs without one use xfwm4's built-in compositor instead (cheaper there, measured).
step "picom $V_picom + libev $V_libev + libconfig $V_libconfig + uthash $V_uthash (headers)"
had_event_h=0; [[ -e /usr/include/event.h ]] && had_event_h=1
unpack libev "libev-$V_libev.tar.gz"
quiet ./configure --prefix=/usr --disable-static; quiet make -j"$(nproc)"; quiet make install
[[ $had_event_h = 1 ]] || rm -f /usr/include/event.h          # libev's libevent-compat header: never shadow libevent
done_ libev
unpack libconfig "libconfig-$V_libconfig.tar.gz"
quiet ./configure --prefix=/usr --disable-static --disable-examples --disable-tests --disable-cxx
quiet make -j"$(nproc)"; quiet make install; done_ libconfig
unpack uthash "uthash-v$V_uthash.tar.gz"; install -m644 src/*.h /usr/include/; done_ uthash
unpack picom "picom-v$V_picom.tar.gz"
quiet meson setup build --prefix=/usr --buildtype=release -Dwrap_mode=nodownload -Dwith_docs=false -Dunittest=false \
    -Dregex=true -Dopengl=true -Ddbus=true -Dvsync_drm=false -Dcompton=false
quiet ninja -C build; quiet ninja -C build install
rm -f /etc/xdg/autostart/picom.desktop                         # eso-perf starts it, only where it belongs
ldconfig; picom --version; done_ picom

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
# the session from eso-desktop 3.12.2: the wallpaper is painted first, so no black screen after the boot animation
grep -q screen_size /usr/local/bin/eso-lite-session || install -m755 /sources/files/eso-lite-session /usr/local/bin/eso-lite-session
grep -q noreset /usr/local/bin/eso-auto-session || install -m755 /sources/files/eso-auto-session /usr/local/bin/eso-auto-session
step "PAM: ESO's service files in ESO Base syntax, then a real password test (as ESO Lock does it)"
# upstream Linux-PAM does not know Debian's "@include FILE" (the whole service fails): rewrite any that a package left
for f in /etc/pam.d/*; do
    grep -q '^@include' "$f" 2>/dev/null || continue
    sed -i -E 's/^@include[[:space:]]+common-(auth|account|session|password)[[:space:]]*$/\1      include     common-\1/' "$f"
    sed -i -E 's/^@include[[:space:]]+(.*)$/# (Debian syntax, not used on ESO Base) @include \1/' "$f"
    echo "  rewrote @include in $f"
done

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
# root is LOCKED: nobody can log in as root (console, serial, su). Administration goes through sudo from the user's
# own account (the live user "eso"; on an installed system the account made at first start, group "sudo").
passwd -l root >/dev/null
[[ $(passwd -S root | awk '{print $2}') == L ]] || { echo "FAILED: root account not locked"; exit 1; }
# setuid helpers: until this build, every stage ran "chown -R root:root" over /usr, which clears setuid bits. ESO Base
# then had no working sudo/pkexec for normal accounts (ESO Ultimate activation and Settings changes go through pkexec),
# the lock screen could not check passwords (unix_chkpwd), AppImage games could not mount (fusermount3), and system
# D-Bus services could not be started on demand (dbus-daemon-launch-helper). Same modes as the upstream installs.
for f in /usr/bin/sudo /usr/bin/pkexec /usr/lib/polkit-1/polkit-agent-helper-1 /usr/sbin/unix_chkpwd /usr/bin/su \
         /usr/bin/passwd /usr/bin/chsh /usr/bin/chfn /usr/bin/newgrp /usr/bin/gpasswd /usr/bin/newuidmap /usr/bin/newgidmap \
         /usr/bin/mount /usr/bin/umount /usr/bin/fusermount3 /usr/bin/fusermount /usr/libexec/Xorg.wrap; do
    [[ -f $f && ! -L $f ]] && { chown root:root "$f"; chmod 4755 "$f"; }
done
if [[ -f /usr/libexec/dbus-daemon-launch-helper ]]; then
    chown root:messagebus /usr/libexec/dbus-daemon-launch-helper; chmod 4750 /usr/libexec/dbus-daemon-launch-helper
fi
rm -f /var/mail/esobuild
echo "  setuid: $(find /usr -xdev -perm -4000 -type f | sort | tr '\n' ' ')"
asuser eso sudo -n true && echo "  sudo as the live user: ok" || { echo "FAILED: sudo does not work for the live user"; exit 1; }
# ESO Lock password check, for real: the live user (no password), and a test account with one (right and wrong)
cp /sources/files/eso-overlay/etc/pam.d/eso-lock /etc/pam.d/eso-lock      # the desktop package must not replace it
install -m755 /sources/files/eso-pamtest.py /usr/libexec/eso-pamtest
pt=0
asuser eso python3 /usr/libexec/eso-pamtest eso-lock "" || { echo "  FAILED: the live user (no password) cannot unlock"; pt=1; }
id esopam >/dev/null 2>&1 || useradd -m -s /bin/sh esopam
echo 'esopam:Eso-Lock-Test-42' | chpasswd
asuser esopam python3 /usr/libexec/eso-pamtest eso-lock "Eso-Lock-Test-42" || { echo "  FAILED: correct password refused"; pt=1; }
if asuser esopam python3 /usr/libexec/eso-pamtest eso-lock "wrong-password" >/dev/null; then echo "  FAILED: wrong password accepted"; pt=1
else echo "  wrong password refused: ok"; fi
userdel -r esopam 2>/dev/null || userdel esopam
[[ $pt = 0 ]] || exit 1
# text recognition for real: words drawn like on a screen, read back by tesseract (as Snip/Amenokal call it)
install -m755 /sources/files/eso-ocrtest.py /usr/libexec/eso-ocrtest
(cd /home/eso && asuser eso env -u TESSDATA_PREFIX python3 /usr/libexec/eso-ocrtest) || { echo "FAILED: text recognition (OCR)"; exit 1; }
wp=$(ls /etc/skel/.local/share/eso/wallpapers/*-1080p.jpg /usr/share/eso/src/assets/wallpapers/*-1080p.jpg 2>/dev/null | head -n1)
if [[ -n $wp ]]; then /usr/bin/eso-rootpaint --test /tmp/rp.ppm 1280 800 "$wp" && echo "  eso-rootpaint: wallpaper decoded" || { echo "FAILED: eso-rootpaint"; exit 1; }; rm -f /tmp/rp.ppm
else echo "  (no built-in wallpaper found for the eso-rootpaint test)"; fi
# stage 6d services: Bluetooth (starts only when an adapter exists), power profiles (Ultra), VM display agent
for u in bluetooth power-profiles-daemon spice-vdagentd eso-splash-quit; do
    [[ -e /usr/lib/systemd/system/$u.service ]] && { systemctl enable "$u.service" >/dev/null 2>&1 || echo "  WARNING: enable $u failed"; }
done
# the live user's desktop starts straight from the boot animation (greetd only without /etc/eso/autologin)
install -d /etc/systemd/system/graphical.target.wants
ln -sf /usr/lib/systemd/system/eso-session@.service /etc/systemd/system/graphical.target.wants/eso-session@eso.service
systemctl daemon-reload 2>/dev/null || true
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
# Boot animation: plymouth starts in the initramfs (eso-mkinitramfs, kernel option "splash") and keeps running into
# the real root. Not started a second time there (plymouth-start), and not ended by plymouth-quit(-wait), which would
# stop it before the desktop and hold boot jobs: greetd deactivates it, eso-splash-quit ends it on the desktop.
systemctl unmask plymouth-read-write.service systemd-ask-password-plymouth.path >/dev/null 2>&1 || true
systemctl mask plymouth-start.service plymouth-quit-wait.service plymouth-quit.service plymouth-switch-root.service \
    >/dev/null 2>&1 || true
install -d /etc/plymouth; printf '[Daemon]\nTheme=eso\nShowDelay=0\nDeviceTimeout=8\n' > /etc/plymouth/plymouthd.conf
[[ -f /usr/share/plymouth/themes/eso/eso.plymouth ]] || echo "  WARNING: ESO plymouth theme missing"
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
    Xvfb :12 -screen 0 1280x800x24 -nolisten tcp -noreset > /tmp/xvfb.log 2>&1 & XP=$!
    for i in $(seq 50); do [[ -S /tmp/.X11-unix/X12 ]] && break; sleep 0.2; done
    bad=0
    # eso-rootpaint on a real X server: the root window must show exactly the decoded wallpaper
    wp=$(ls /etc/skel/.local/share/eso/wallpapers/*-1080p.jpg 2>/dev/null | head -n1)
    if [[ -n $wp ]]; then
        eso-rootpaint --test /tmp/rp.ppm 1280 800 "$wp" >/dev/null
        t0=$(date +%s%N); asuser eso eso-rootpaint --zoom "$wp" || bad=1; t1=$(date +%s%N)
        python3 - "$(( (t1 - t0) / 1000000 ))" <<'PYEOF' || bad=1
import sys, gi
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk
w = Gdk.get_default_root_window()
pb = Gdk.pixbuf_get_from_window(w, 0, 0, 1280, 800)
ppm = open("/tmp/rp.ppm", "rb").read()
body = ppm[ppm.index(b"255\n") + 4:]
px, rs, n = pb.get_pixels(), pb.get_rowstride(), pb.get_n_channels()
diff = 0
for (x, y) in [(10, 10), (640, 400), (300, 700), (1000, 750), (1270, 790)]:
    a = px[y * rs + x * n: y * rs + x * n + 3]; b = body[(y * 1280 + x) * 3: (y * 1280 + x) * 3 + 3]
    diff = max(diff, max(abs(a[i] - b[i]) for i in range(3)))
print(f"  eso-rootpaint on X: wallpaper on the root window in {sys.argv[1]} ms, max pixel difference {diff}")
sys.exit(0 if diff <= 2 else 1)
PYEOF
        rm -f /tmp/rp.ppm
    fi
    # compositors: xfwm4's own (VMs, no GPU) and picom (GPU PCs) must both take over the screen on ESO Base
    cat > /tmp/comp.py <<'PYEOF'
import gi, sys
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk
sys.exit(0 if Gdk.Screen.get_default().is_composited() else 1)
PYEOF
    rc=0; asuser eso dbus-run-session -- sh -c '
        xfconf-query -c xfwm4 -p /general/use_compositing -n -t bool -s true
        xfconf-query -c xfwm4 -p /general/vblank_mode -n -t string -s xpresent
        xfwm4 --compositor=on --sm-client-disable > /tmp/xfwm4c.log 2>&1 & W=$!
        for i in 1 2 3 4 5 6 7 8 9 10; do sleep 0.5; python3 /tmp/comp.py && break; done
        python3 /tmp/comp.py; r=$?
        xfconf-query -c xfwm4 -p /general/use_compositing -s false; sleep 1
        python3 /tmp/comp.py && r=2
        picom --config /dev/null --backend xrender > /tmp/picom.log 2>&1 & P=$!
        for i in 1 2 3 4 5 6; do sleep 0.5; python3 /tmp/comp.py && break; done
        python3 /tmp/comp.py || r=3
        kill $P $W; exit $r' || rc=$?
    case $rc in
        0) echo "  compositors: xfwm4 (XPresent) composites, switches off live, picom takes over" ;;
        1) echo "  FAILED: xfwm4 compositor did not start"; cat /tmp/xfwm4c.log | tail -15; bad=1 ;;
        2) echo "  FAILED: xfwm4 compositor did not switch off"; bad=1 ;;
        *) echo "  FAILED: picom did not composite (rc $rc)"; tail -15 /tmp/picom.log; bad=1 ;;
    esac
    rm -f /tmp/comp.py
    for app in eso-settings eso-browser; do
        rc=0; asuser eso dbus-run-session -- timeout 25 "/usr/local/bin/$app" > /tmp/app.log 2>&1 || rc=$?
        if [[ $rc -eq 124 ]] && ! grep -q "Traceback" /tmp/app.log; then echo "  $app: running after 25 s, no errors"
        else echo "  $app: exit $rc"; tail -25 /tmp/app.log; bad=1; fi
    done
    # ESO Ultimate on ESO Base (CI only, from an encrypted copy): install it with ESO's own installer, start every
    # Ultimate app, then remove it again: the image stays ESO Standard (Ultimate arrives with an activation key).
    if [[ -s /sources/eso-ultimate.deb ]]; then
        step "ESO Ultimate on ESO Base: install, start each app, remove"
        if ESO_BASE_PKG=1 python3 /usr/share/eso/src/lib/eso/esobasepkg.py install-local /sources/eso-ultimate.deb > /tmp/ult.log 2>&1; then
            tail -1 /tmp/ult.log
            for app in ilyass eso-sheets eso-slides eso-studio eso-nano eso-defender eso-cosmos eso-gamebar; do
                f=/usr/local/bin/$app
                if grep -q ESO-ULTIMATE-STUB "$f" 2>/dev/null; then echo "  $app: still the Standard stub"; bad=1; continue; fi
                # the license check answers "activated" for this test run only (the app runs as on an activated PC)
                rc=0; asuser eso dbus-run-session -- timeout 20 python3 -c 'import runpy, sys
sys.path.insert(0, "/usr/local/lib/eso")
import esolicense; esolicense._cache = True
sys.argv = sys.argv[1:]; runpy.run_path(sys.argv[0], run_name="__main__")' "$f" > /tmp/app.log 2>&1 || rc=$?
                if [[ $rc -eq 124 || $rc -eq 0 ]] && ! grep -q "Traceback" /tmp/app.log; then echo "  $app (Ultimate): starts on ESO Base"
                else echo "  $app (Ultimate): exit $rc"; tail -20 /tmp/app.log; bad=1; fi
            done
            command -v clamscan >/dev/null && command -v ufw >/dev/null && echo "  Defender tools: clamscan + ufw present"
        else tail -30 /tmp/ult.log; echo "  eso-ultimate did not install"; bad=1; fi
        ESO_BASE_PKG=1 python3 /usr/share/eso/src/lib/eso/esobasepkg.py remove eso-ultimate > /tmp/ult.log 2>&1 || { tail -20 /tmp/ult.log; bad=1; }
        rm -f /sources/eso-ultimate.deb
        grep -q ESO-ULTIMATE-STUB /usr/local/bin/ilyass && [[ ! -e /var/lib/eso/pkgs/eso-ultimate.control ]] \
            && echo "  removed again: the image is ESO Standard" || { echo "  FAILED: Ultimate files left in the image"; bad=1; }
    fi
    kill $XP 2>/dev/null || true; rm -rf /tmp/xdg-eso /tmp/.X11-unix/X12 /tmp/.X12-lock
    rm -rf /home/eso/.cache; chown -R eso: /home/eso
    [[ $bad = 0 ]] || { echo "FAILED: an ESO app did not start"; exit 1; }
fi
# ───────────────────────────── device firmware ─────────────────────────────
# Without it AMD Radeon GPUs do not start at all (and NVIDIA/newer Intel get no acceleration): the desktop then runs
# on the plain firmware framebuffer, fixed at one mode, every pixel drawn by the CPU - the whole OS lags. Same for
# most Wi-Fi/Bluetooth chips and Realtek Ethernet. Installed uncompressed (works with every kernel; the ISO's
# squashfs compresses it). NVIDIA GSP blobs (RTX 20+ on nouveau, ~300 MB) are left out: those PCs use NVIDIA's driver.
step "linux-firmware $V_linuxfirmware: GPU (AMD, Intel, NVIDIA), Wi-Fi, Ethernet, Bluetooth"
rm -rf /sources/fw; mkdir -p /sources/fw
FWSEL=(WHENCE 'LICEN[CS]E*' 'GPL*' amdgpu radeon i915 xe nvidia 'iwlwifi-*' intel/ibt-'*' rtl_nic rtw88 rtw89 rtl_bt rtlwifi
       ath10k ath11k ath12k ath9k_htc mediatek 'mt7*' qca brcm 'rt2*' 'rt3*' 'rt5*' cypress)
tar -xf "/sources/linux-firmware-$V_linuxfirmware.tar.xz" -C /sources/fw --strip-components=1 --wildcards \
    --exclude='*/gsp/*' "${FWSEL[@]/#/*/}" 2>/dev/null || true
[[ -f /sources/fw/WHENCE ]] || { echo "FAILED: linux-firmware did not unpack"; exit 1; }
python3 - <<'PY'
import os, re, shutil
src, dst = "/sources/fw", "/usr/lib/firmware"
n = links = 0
for root, dirs, files in os.walk(src):
    for f in files:
        rel = os.path.relpath(os.path.join(root, f), src)
        if rel in ("WHENCE",) or rel.startswith(("LICEN", "GPL")) or rel.endswith((".py", ".sh", ".txt", ".md")):
            continue
        os.makedirs(os.path.dirname(os.path.join(dst, rel)), exist_ok=True)
        shutil.copy2(os.path.join(root, f), os.path.join(dst, rel)); n += 1
for line in open(os.path.join(src, "WHENCE"), errors="replace"):
    m = re.match(r"^Link:\s*(\S+)\s*->\s*(\S+)", line)
    if not m:
        continue
    link, target = m.group(1), m.group(2)
    full = os.path.normpath(os.path.join(dst, os.path.dirname(link), target))
    if os.path.exists(full) and not os.path.lexists(os.path.join(dst, link)):
        os.makedirs(os.path.dirname(os.path.join(dst, link)), exist_ok=True)
        os.symlink(target, os.path.join(dst, link)); links += 1
# trim: only what a PC can use. Intel Wi-Fi: newest API version per chip (the kernel loads the highest it knows);
# no router-only Qualcomm chips (IPQ/QCN/QCA99xx/40xx) and no phone/Chromebook MediaTek SoC firmware (mt8xxx).
import glob
best = {}
for f in glob.glob(dst + "/iwlwifi-*.ucode"):
    m = re.match(r"(.*)-(\d+)\.ucode$", os.path.basename(f))
    if m:
        best.setdefault(m.group(1), []).append((int(m.group(2)), f))
pruned = 0
for k, v in best.items():
    for _, f in sorted(v)[:-1]:
        os.remove(f); pruned += 1
for pat in ("ath1[012]k/IPQ*", "ath1[012]k/QCN*", "ath10k/QCA99*", "ath10k/QCA4019", "ath10k/QCA9888", "ath10k/QCA9984",
            "mediatek/mt8[0-9]*", "mediatek/sof*"):
    for d in glob.glob(os.path.join(dst, pat)):
        shutil.rmtree(d) if os.path.isdir(d) and not os.path.islink(d) else os.remove(d); pruned += 1
for root, dirs, files in os.walk(dst):                     # aliases whose target was trimmed
    for f in files + dirs:
        q = os.path.join(root, f)
        if os.path.islink(q) and not os.path.exists(q):
            os.remove(q)
print(f"  trimmed {pruned} old/unneeded entries")
os.makedirs("/usr/share/licenses/linux-firmware", exist_ok=True)
for f in os.listdir(src):
    if f.startswith(("LICEN", "GPL")) or f == "WHENCE":
        p = os.path.join(src, f)
        if os.path.isdir(p):
            shutil.copytree(p, os.path.join("/usr/share/licenses/linux-firmware", f), dirs_exist_ok=True)
        else:
            shutil.copy2(p, "/usr/share/licenses/linux-firmware/")
print(f"  {n} firmware files, {links} aliases")
PY
rm -rf /sources/fw "/sources/linux-firmware-$V_linuxfirmware.tar.xz"
du -sh /usr/lib/firmware/* 2>/dev/null | sort -rh | head -12 | sed 's|/usr/lib/firmware/||; s/^/  size /'
for d in amdgpu radeon i915 xe nvidia rtl_nic rtw89 mediatek; do printf '  %-9s %s\n' "$d" "$(du -sh /usr/lib/firmware/$d 2>/dev/null | cut -f1)"; done
echo "  iwlwifi: $(ls /usr/lib/firmware/iwlwifi-* 2>/dev/null | wc -l) files; total $(du -sh /usr/lib/firmware | cut -f1)"
ls /usr/lib/firmware/amdgpu/*.bin >/dev/null 2>&1 && ls /usr/lib/firmware/i915/*.bin >/dev/null 2>&1 \
    || { echo "FAILED: GPU firmware missing"; exit 1; }

step "stage 6c done"; du -sh /usr /usr/share/eso /etc/skel
