#!/bin/bash
# ESO Base stage 5b, INSIDE the chroot: what a real desktop session needs underneath.
#   login:   Linux-PAM, then shadow and systemd rebuilt with PAM (pam_systemd gives every login its session,
#            XDG_RUNTIME_DIR and seat access), sudo
#   network: Mozilla CA certificates, libpsl + curl, libnl/libndp, wpa_supplicant, iw, wireless-regdb,
#            NetworkManager (nmcli; Wi-Fi through wpa_supplicant over D-Bus)
#   desktop services: duktape + polkit, json-c + accountsservice, libgudev + upower, earlyoom
#   sound:   alsa-lib + UCM profiles + alsa-utils, Lua, PipeWire (with its PulseAudio and ALSA layers) + WirePlumber
# All from upstream sources. No network inside the chroot: every source is a pinned download in sources-stage5b.list.
set -euo pipefail
. /sources/versions.env
step() { echo; echo "=== $* ($(date -u +%H:%M:%S)) ==="; }
unpack() { rm -rf "/sources/$1"; mkdir -p "/sources/$1"; tar -xf "/sources/$2" -C "/sources/$1" --strip-components=1; cd "/sources/$1"; }
declare -A PFX=([linuxpam]=Linux-PAM [jsonc]=json-c [wpasupplicant]=wpa_supplicant [wirelessregdb]=wireless-regdb
                [alsalib]=alsa-lib [alsaucm]=alsa-ucm-conf [alsautils]=alsa-utils)
src() { local f; f=$(ls /sources/"${PFX[$1]:-$1}"-[0-9v]* 2>/dev/null | grep -E '\.(tar\.(xz|gz|bz2)|tgz)$' | head -1)
        [[ -n $f ]] || { echo "no source tarball for $1" >&2; exit 1; }; basename "$f"; }
done_() { cd /sources; rm -rf "/sources/$1"; }
quiet() { "$@" > /tmp/build.log 2>&1 || { tail -80 /tmp/build.log; echo "FAILED: $*"; exit 1; }; }
ac() { local n=$1; shift; step "$n"; unpack "$n" "$(src "$n")"
       quiet ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --disable-static "$@"
       quiet make; quiet make install; done_ "$n"; }
ms() { local n=$1; shift; step "$n"; unpack "$n" "$(src "$n")"
       quiet meson setup build --prefix=/usr --buildtype=release -Dwrap_mode=nodownload "$@"
       quiet ninja -C build; quiet ninja -C build install; done_ "$n"; }
cm() { local n=$1; shift; step "$n"; unpack "$n" "$(src "$n")"
       quiet cmake -B build -G Ninja -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_LIBDIR=lib "$@"
       quiet ninja -C build; quiet ninja -C build install; done_ "$n"; }
export PKG_CONFIG_PATH=/usr/lib/pkgconfig:/usr/share/pkgconfig
UNITS=/usr/lib/systemd/system
grp() { grep -q "^$1:" /etc/group || groupadd -r "$1"; }      # system group, free id

# ───────────────────────────── login: PAM ─────────────────────────────
ms linuxpam -Ddocs=disabled -Dexamples=false -Daudit=disabled -Deconf=disabled -Dselinux=disabled -Dnis=disabled \
   -Dpam_userdb=disabled -Dxtests=false
install -d -m755 /etc/pam.d /etc/security
cat > /etc/pam.d/system-account <<'EOF'
account   required    pam_unix.so
EOF
cat > /etc/pam.d/system-auth <<'EOF'
auth      required    pam_unix.so
EOF
cat > /etc/pam.d/system-session <<'EOF'
session   required    pam_unix.so
session   required    pam_loginuid.so
session   optional    pam_systemd.so
EOF
cat > /etc/pam.d/system-password <<'EOF'
password  required    pam_unix.so       yescrypt shadow try_first_pass
EOF
cat > /etc/pam.d/other <<'EOF'
auth      required    pam_warn.so
auth      required    pam_deny.so
account   required    pam_warn.so
account   required    pam_deny.so
password  required    pam_warn.so
password  required    pam_deny.so
session   required    pam_warn.so
session   required    pam_deny.so
EOF

step "shadow $V_shadow (again, now with PAM)"
unpack shadow "$(src shadow)"
sed -i 's/groups$(EXEEXT) //' src/Makefile.in
find man -name Makefile.in -exec sed -i 's/groups\.1 / /;s/getspnam\.3 / /;s/passwd\.5 / /' {} \;
sed -e 's:#ENCRYPT_METHOD DES:ENCRYPT_METHOD YESCRYPT:' -e 's:/var/spool/mail:/var/mail:' \
    -e '/PATH=/{s@/sbin:@@;s@/bin:@@}' -i etc/login.defs
quiet ./configure --sysconfdir=/etc --disable-static --with-{b,yes}crypt --without-libbsd --with-group-name-max-length=32 \
    --with-libpam
grep -q '^#define USE_PAM' config.h || { echo "shadow: PAM not detected"; exit 1; }
quiet make; quiet make exec_prefix=/usr pamddir= install
done_ shadow
# settings PAM now handles (shadow warns about them otherwise)
for f in FAIL_DELAY FAILLOG_ENAB LASTLOG_ENAB MAIL_CHECK_ENAB OBSCURE_CHECKS_ENAB PORTTIME_CHECKS_ENAB QUOTAS_ENAB \
         CONSOLE MOTD_FILE FTMP_FILE NOLOGINS_FILE ENV_HZ PASS_MIN_LEN SU_WHEEL_ONLY PASS_CHANGE_TRIES PASS_ALWAYS_WARN \
         CHFN_AUTH ENCRYPT_METHOD ENVIRON_FILE; do sed -i "s/^${f}/# &/" /etc/login.defs; done
cat > /etc/pam.d/login <<'EOF'
auth      optional    pam_faildelay.so  delay=3000000
auth      requisite   pam_nologin.so
auth      include     system-auth
account   required    pam_access.so
account   include     system-account
session   required    pam_env.so
session   required    pam_limits.so
session   include     system-session
password  include     system-password
EOF
cat > /etc/pam.d/passwd <<'EOF'
password  include     system-password
EOF
cat > /etc/pam.d/su <<'EOF'
auth      sufficient  pam_rootok.so
auth      include     system-auth
account   include     system-account
session   required    pam_env.so
session   include     system-session
EOF
cat > /etc/pam.d/chpasswd <<'EOF'
auth      sufficient  pam_rootok.so
auth      include     system-auth
account   include     system-account
password  include     system-password
EOF
for p in newusers chgpasswd; do cp /etc/pam.d/chpasswd /etc/pam.d/$p; done
for p in chage chfn chsh groupadd groupdel groupmems groupmod useradd userdel usermod; do
    printf 'auth      sufficient  pam_rootok.so\nauth      include     system-auth\naccount   include     system-account\nsession   include     system-session\npassword  required    pam_permit.so\n' > /etc/pam.d/$p
done

step "systemd $V_systemd (again, now with PAM: pam_systemd for login sessions)"
unpack systemd "$(src systemd)"
sed -i 's/(ECANCELLED|EREFUSED)/(ECANCELLED|EREFUSED|EFSBADCRC|EFSCORRUPTED)/' src/basic/generate-errno-list.sh
mkdir build && cd build
quiet meson setup .. --prefix=/usr --buildtype=release -D default-dnssec=no -D firstboot=false -D install-tests=false \
    -D ldconfig=false -D sysusers=false -D rpmmacrosdir=no -D homed=disabled -D userdb=false -D man=disabled \
    -D mode=release -D pam=enabled -D pamconfdir=/etc/pam.d -D kmod=enabled -D blkid=enabled -D acl=enabled \
    -D dev-kvm-mode=0660 -D nobody-group=nogroup -D sysupdate=disabled -D ukify=disabled -D docdir=/usr/share/doc/systemd
quiet ninja; quiet ninja install
done_ systemd
ls /usr/lib/security/pam_systemd.so >/dev/null || { echo "pam_systemd.so missing"; exit 1; }

# ───────────────────────────── certificates, curl, sudo ─────────────────────────────
step "Mozilla CA certificates (curl.se bundle)"
install -d -m755 /etc/ssl/certs
install -m644 /sources/cacert.pem /etc/ssl/certs/ca-certificates.crt
ln -sfn certs/ca-certificates.crt /etc/ssl/cert.pem
( cd /etc/ssl/certs && awk 'BEGIN{n=0} /-----BEGIN CERTIFICATE-----/{n++; f=sprintf("eso-ca-%03d.pem",n)} n{print > f} /-----END CERTIFICATE-----/{close(f)}' ca-certificates.crt )
openssl rehash /etc/ssl/certs 2>/dev/null || true
echo "CA certificates: $(ls /etc/ssl/certs/eso-ca-*.pem | wc -l)"

ms libpsl -Dtests=false -Ddocs=false
ac curl --with-openssl --with-libpsl --with-ca-path=/etc/ssl/certs --with-ca-bundle=/etc/ssl/certs/ca-certificates.crt \
   --enable-threaded-resolver --disable-manual
curl --version > /tmp/v.txt; head -1 /tmp/v.txt

ac sudo --libexecdir=/usr/lib --with-secure-path --with-env-editor --with-pam --docdir=/usr/share/doc/sudo \
   --with-passprompt="[sudo] password for %p: "
grp sudo
grep -qE '^[#@]includedir /etc/sudoers.d' /etc/sudoers || echo '@includedir /etc/sudoers.d' >> /etc/sudoers
install -d -m750 /etc/sudoers.d
echo '%sudo ALL=(ALL:ALL) ALL' > /etc/sudoers.d/00-eso-sudo; chmod 440 /etc/sudoers.d/00-eso-sudo
cat > /etc/pam.d/sudo <<'EOF'
auth      include     system-auth
account   include     system-account
session   required    pam_env.so
session   include     system-session
EOF

# ───────────────────────────── desktop services ─────────────────────────────
step "duktape $V_duktape (JavaScript engine for polkit rules)"
unpack duktape "$(src duktape)"
sed -i 's/-Os/-O2/' Makefile.sharedlibrary
quiet make -f Makefile.sharedlibrary INSTALL_PREFIX=/usr
quiet make -f Makefile.sharedlibrary INSTALL_PREFIX=/usr install
done_ duktape

grp polkitd
id polkitd >/dev/null 2>&1 || useradd -r -c "polkit daemon" -d /etc/polkit-1 -g polkitd -s /bin/false polkitd
ms polkit -Dman=false -Dsession_tracking=logind -Dtests=false -Dos_type=lfs -Dauthfw=pam -Dexamples=false \
   -Dgtk_doc=false -Dintrospection=true -Dsystemdsystemunitdir=$UNITS
[[ -f /etc/pam.d/polkit-1 ]] || printf 'auth      include     system-auth\naccount   include     system-account\npassword  include     system-password\nsession   include     system-session\n' > /etc/pam.d/polkit-1

cm jsonc -DBUILD_STATIC_LIBS=OFF -DBUILD_TESTING=OFF
# accountsservice reads its version from git or from an "accountsservice-X.Y.Z" directory name; give it the pinned one
step accountsservice; unpack accountsservice "$(src accountsservice)"
printf '#!/bin/sh\necho %s\n' "$V_accountsservice" > generate-version.sh; chmod +x generate-version.sh
quiet meson setup build --prefix=/usr --buildtype=release -Dwrap_mode=nodownload -Dadmin_group=sudo -Dvapi=false \
   -Dtests=false -Dintrospection=true -Ddocbook=false -Dgtk_doc=false -Dsystemdsystemunitdir=$UNITS
quiet ninja -C build; quiet ninja -C build install; done_ accountsservice
ms libgudev -Dtests=disabled -Dvapi=disabled -Dintrospection=enabled
ms upower -Dman=false -Dgtk-doc=false -Dintrospection=enabled -Didevice=disabled -Dpolkit=enabled \
   -Dinstalled_tests=false -Dsystemdsystemunitdir=$UNITS

step "earlyoom $V_earlyoom (kills the biggest app before the PC freezes when memory runs out)"
unpack earlyoom "$(src earlyoom)"
quiet make earlyoom earlyoom.service VERSION=v$V_earlyoom PREFIX=/usr SYSCONFDIR=/etc
install -m755 earlyoom /usr/bin/earlyoom; install -m644 earlyoom.service $UNITS/earlyoom.service
install -Dm644 earlyoom.default /etc/default/earlyoom
done_ earlyoom

# ───────────────────────────── network ─────────────────────────────
ac libnl
step "libndp $V_libndp (IPv6 router discovery for NetworkManager)"
unpack libndp "$(src libndp)"
quiet ./autogen.sh
quiet ./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --disable-static
quiet make; quiet make install; done_ libndp

ms networkmanager -Dsystemdsystemunitdir=$UNITS -Dudev_dir=/usr/lib/udev -Ddbus_conf_dir=/usr/share/dbus-1/system.d \
   -Dsession_tracking=systemd -Dsuspend_resume=systemd -Dsession_tracking_consolekit=false -Dsystemd_journal=true \
   -Dpolkit=true -Dselinux=false -Dlibaudit=no -Dwifi=true -Diwd=false -Dwext=false -Dppp=false -Dmodem_manager=false \
   -Dofono=false -Dconcheck=true -Dteamdctl=false -Dovs=false -Dnmcli=true -Dnmtui=false -Dnm_cloud_setup=false \
   -Dbluez5_dun=false -Debpf=false -Dnbft=false -Dclat=false -Difcfg_rh=false -Difupdown=false -Dintrospection=true \
   -Dvapi=false -Ddocs=false -Dman=false -Dtests=no -Dfirewalld_zone=false -Dlibpsl=true -Dcrypto=null -Dqt=false \
   -Dreadline=libreadline -Dmore_logging=false -Dconfig_dhcp_default=internal
install -d -m755 /etc/NetworkManager/conf.d
printf '[main]\nplugins=keyfile\n\n[device]\nwifi.backend=wpa_supplicant\n' > /etc/NetworkManager/conf.d/10-eso.conf
nmcli --version > /dev/null

step "wpa_supplicant $V_wpasupplicant (Wi-Fi security; NetworkManager drives it over D-Bus)"
unpack wpasupplicant "$(src wpasupplicant)"
cd wpa_supplicant
cat > .config <<'EOF'
CONFIG_BACKEND=file
CONFIG_CTRL_IFACE=y
CONFIG_CTRL_IFACE_DBUS_NEW=y
CONFIG_CTRL_IFACE_DBUS_INTRO=y
CONFIG_DEBUG_FILE=y
CONFIG_DEBUG_SYSLOG=y
CONFIG_DEBUG_SYSLOG_FACILITY=LOG_DAEMON
CONFIG_DRIVER_NL80211=y
CONFIG_DRIVER_WIRED=y
CONFIG_LIBNL32=y
CONFIG_EAP_GTC=y
CONFIG_EAP_MD5=y
CONFIG_EAP_MSCHAPV2=y
CONFIG_EAP_OTP=y
CONFIG_EAP_PEAP=y
CONFIG_EAP_TLS=y
CONFIG_EAP_TTLS=y
CONFIG_IEEE8021X_EAPOL=y
CONFIG_IPV6=y
CONFIG_PKCS12=y
CONFIG_READLINE=y
CONFIG_WPS=y
CONFIG_SAE=y
CONFIG_OWE=y
CONFIG_IEEE80211W=y
CONFIG_IEEE80211N=y
CONFIG_IEEE80211AC=y
CONFIG_IEEE80211AX=y
CONFIG_TLS=openssl
CFLAGS += -I/usr/include/libnl3
EOF
quiet make BINDIR=/usr/sbin LIBDIR=/usr/lib
install -m755 wpa_cli wpa_passphrase wpa_supplicant /usr/sbin/
install -m644 systemd/*.service $UNITS/
install -Dm644 dbus/fi.w1.wpa_supplicant1.service /usr/share/dbus-1/system-services/fi.w1.wpa_supplicant1.service
install -Dm644 dbus/dbus-wpa_supplicant.conf /usr/share/dbus-1/system.d/wpa_supplicant.conf
done_ wpasupplicant

step "iw $V_iw"; unpack iw "$(src iw)"
quiet make; quiet make SBINDIR=/usr/sbin install; done_ iw
step "wireless-regdb $V_wirelessregdb (Wi-Fi channels allowed in each country)"
unpack wirelessregdb "$(src wirelessregdb)"
install -Dm644 regulatory.db /usr/lib/firmware/regulatory.db
install -Dm644 regulatory.db.p7s /usr/lib/firmware/regulatory.db.p7s
done_ wirelessregdb

# ───────────────────────────── sound ─────────────────────────────
ac alsalib --without-debug
step "alsa-ucm-conf $V_alsaucm (sound profiles for laptops: Intel SOF, AMD ACP...)"
install -d /usr/share/alsa
tar -xf "/sources/$(src alsaucm)" -C /usr/share/alsa --strip-components=1 --wildcards '*/ucm2'
ac alsautils --disable-alsaconf --disable-bat --disable-xmlto --with-curses=ncursesw --with-systemdsystemunitdir=$UNITS

step "Lua $V_lua (shared library, for WirePlumber's policy scripts)"
unpack lua "$(src lua)"
cd src
quiet make linux-readline MYCFLAGS="-fPIC"
gcc -shared -Wl,-soname,liblua.so.5.4 -o "liblua.so.$V_lua" $(ls *.o | grep -vx -e lua.o -e luac.o) -lm -ldl
cd ..
quiet make install INSTALL_TOP=/usr INSTALL_MAN=/usr/share/man/man1
install -m755 "src/liblua.so.$V_lua" /usr/lib/
ln -sfn "liblua.so.$V_lua" /usr/lib/liblua.so.5.4; ln -sfn liblua.so.5.4 /usr/lib/liblua.so; rm -f /usr/lib/liblua.a
cat > /usr/lib/pkgconfig/lua.pc <<EOF
prefix=/usr
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: Lua
Description: An extensible extension language
Version: $V_lua
Libs: -L\${libdir} -llua -lm -ldl
Cflags: -I\${includedir}
EOF
ln -sfn lua.pc /usr/lib/pkgconfig/lua5.4.pc
done_ lua

ms pipewire -Dauto_features=disabled -Dexamples=disabled -Dtests=disabled -Dpipewire-jack=disabled \
   -Dpipewire-v4l2=disabled -Dflatpak=disabled "-Dsession-managers=[]" -Dalsa=enabled -Dpipewire-alsa=enabled \
   -Dudev=enabled -Dlibsystemd=enabled -Dlogind=enabled -Dsystemd-user-service=enabled -Dreadline=enabled \
   -Dman=disabled -Ddocs=disabled -Dsystemd-user-unit-dir=/usr/lib/systemd/user
ms wireplumber -Dsystem-lua=true -Dintrospection=disabled -Ddoc=disabled -Dtests=false -Ddbus-tests=false \
   -Delogind=disabled -Dsystemd=enabled -Dsystemd-user-service=true -Dsystemd-system-service=false \
   -Dsystemd-user-unit-dir=/usr/lib/systemd/user
# apps that talk plain ALSA go through PipeWire too
install -d /etc/alsa/conf.d
for f in 50-pipewire.conf 99-pipewire-default.conf; do
    [[ -f /usr/share/alsa/alsa.conf.d/$f ]] && ln -sfn /usr/share/alsa/alsa.conf.d/$f /etc/alsa/conf.d/$f
done

# ───────────────────────────── enable services ─────────────────────────────
step "enable services"
grp netdev; grp audio; grp video
systemctl enable NetworkManager.service earlyoom.service >/dev/null 2>&1 || true
systemctl enable accounts-daemon.service upower.service >/dev/null 2>&1 || true
systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service >/dev/null 2>&1 || true
ldconfig

step "smoke test"
for t in "curl --version" "sudo -V" "nmcli --version" "wpa_supplicant -v" "iw --version" "pipewire --version" \
         "wireplumber --version" "aplay --version" "lua -v" "earlyoom -v" "pkexec --version"; do
    printf '  %-22s ' "${t%% *}"; $t > /tmp/v.txt 2>&1 || { cat /tmp/v.txt; echo "FAILED: $t"; exit 1; }; head -1 /tmp/v.txt
done
for so in /usr/lib/security/pam_unix.so /usr/lib/security/pam_systemd.so /usr/lib/libpolkit-gobject-1.so \
          /usr/lib/libnm.so /usr/lib/libpipewire-0.3.so; do [[ -e $so ]] || { echo "missing $so"; exit 1; }; done
python3 - <<'PY'
import gi
for ns, v in (("NM", "1.0"), ("Polkit", "1.0"), ("AccountsService", "1.0"), ("UPowerGlib", "1.0"), ("GUdev", "1.0")):
    gi.require_version(ns, v); __import__("gi.repository." + ns)
print("  GObject introspection: NM, Polkit, AccountsService, UPowerGlib, GUdev OK")
PY
step "stage 5b done"; du -sh /usr/lib /usr/share
