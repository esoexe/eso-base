#!/bin/bash
# ESO Base stage 5d, INSIDE the chroot: sound and video for the ESO apps.
#   codecs:     nasm, x264 (screen recorder), dav1d (AV1), Ogg/Vorbis/Opus, libsndfile, Little CMS
#   sound:      PulseAudio client library + pactl (PipeWire from stage 5b is the server)
#   GPU video:  VA-API (libva), Vulkan loader + headers
#   FFmpeg:     screen recording (x11grab + pulse), camera (v4l2), H.264 (x264 / VA-API), AAC, thumbnails
#   GStreamer:  core + base + good + a small set of bad + libav — the ESO media player (playbin, gtksink), camera,
#               recorder (pulsesrc) and, later, the browser's audio/video (WebKitGTK needs app/pbutils/video/tag/gl/
#               audio/fft + mpegts/transcoder)
#   mpv:        live wallpapers (libplacebo with OpenGL + Vulkan, libass subtitles)
# All from upstream sources. No network inside the chroot: every source is a pinned download in sources-stage5d.list.
set -euo pipefail
. /sources/versions.env
step() { echo; echo "=== $* ($(date -u +%H:%M:%S)) ==="; }
unpack() { rm -rf "/sources/$1"; mkdir -p "/sources/$1"; tar -xf "/sources/$2" -C "/sources/$1" --strip-components=1; cd "/sources/$1"; }
declare -A PFX=([gstpluginsbase]=gst-plugins-base [gstpluginsgood]=gst-plugins-good [gstpluginsbad]=gst-plugins-bad
                [gstlibav]=gst-libav)
src() { local p="${PFX[$1]:-$1}" f; f=$(ls /sources/"$p"-[0-9v]* 2>/dev/null | grep -E '\.(tar\.(xz|gz|bz2)|tgz)$' | head -1)
        [[ -n $f ]] || f=$(ls /sources/"$p"-* 2>/dev/null | grep -E "/$p-[0-9a-f]{40}\.tar\.gz$" | head -1)   # git commit archives
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
       quiet cmake -B build -G Ninja -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_POLICY_VERSION_MINIMUM=3.5 "$@"
       quiet ninja -C build; quiet ninja -C build install; done_ "$n"; }
export PKG_CONFIG_PATH=/usr/lib/pkgconfig:/usr/share/pkgconfig

# ───────────────────────────── codecs and helpers ─────────────────────────────
ac nasm
step "x264"; unpack x264 "$(src x264)"
quiet ./configure --prefix=/usr --enable-shared --enable-pic --disable-cli
quiet make; quiet make install; done_ x264
ms dav1d -Denable_tools=false -Denable_tests=false -Denable_examples=false -Denable_docs=false
ac libogg
ac libvorbis
ms opus -Dtests=disabled -Ddocs=disabled -Dextra-programs=disabled
cm libsndfile -DBUILD_SHARED_LIBS=ON -DENABLE_EXTERNAL_LIBS=OFF -DENABLE_MPEG=OFF -DBUILD_PROGRAMS=OFF \
    -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF -DBUILD_REGTEST=OFF -DINSTALL_MANPAGES=OFF -DENABLE_CPACK=OFF
ac lcms2

# ───────────────────────────── PulseAudio client (PipeWire is the server) ─────────────────────────────
ms pulseaudio -Ddaemon=false -Dclient=true -Ddoxygen=false -Dman=false -Dtests=false -Ddatabase=simple \
    -Dauto_features=disabled -Ddbus=enabled -Dglib=enabled -Dbashcompletiondir=no -Dzshcompletiondir=no
mkdir -p /etc/pulse/client.conf.d
printf '# ESO: PipeWire (pipewire-pulse) is the sound server; never start a PulseAudio daemon\nautospawn = no\n' \
    > /etc/pulse/client.conf.d/00-eso.conf

# ───────────────────────────── GPU video: VA-API, Vulkan ─────────────────────────────
ms libva -Dwith_x11=yes -Dwith_glx=no -Dwith_wayland=yes -Denable_docs=false
cm vulkanheaders
cm vulkanloader -DBUILD_TESTS=OFF -DBUILD_WSI_XCB_SUPPORT=ON -DBUILD_WSI_XLIB_SUPPORT=ON -DBUILD_WSI_WAYLAND_SUPPORT=ON \
    -DCMAKE_INSTALL_SYSCONFDIR=/etc

# ───────────────────────────── subtitles (mpv, FFmpeg) ─────────────────────────────
ms libass -Dfontconfig=enabled -Dasm=enabled -Dlibunibreak=disabled -Dtest=disabled -Dcompare=disabled \
    -Dprofile=disabled -Dfuzz=disabled -Dcheckasm=disabled

# ───────────────────────────── FFmpeg ─────────────────────────────
step "FFmpeg $V_ffmpeg"; unpack ffmpeg "$(src ffmpeg)"
quiet ./configure --prefix=/usr --enable-gpl --enable-version3 --enable-shared --disable-static --disable-doc \
    --disable-debug --enable-libx264 --enable-libdav1d --enable-libopus --enable-libvorbis --enable-libass \
    --enable-libpulse --enable-libdrm --enable-vaapi --enable-libxcb --enable-openssl --enable-libfreetype \
    --enable-libfontconfig --enable-libfribidi --enable-libharfbuzz
quiet make; quiet make install; done_ ffmpeg

# ───────────────────────────── GStreamer ─────────────────────────────
GST_COMMON="-Dauto_features=disabled -Dnls=enabled -Dexamples=disabled -Dtests=disabled -Ddoc=disabled"
ms gstreamer -Dintrospection=enabled -Dnls=enabled -Dtools=enabled -Dexamples=disabled -Dtests=disabled \
    -Dbenchmarks=disabled -Ddoc=disabled -Dptp-helper=disabled -Dlibunwind=disabled -Dlibdw=disabled \
    -Dbash-completion=disabled -Dcheck=disabled -Dcoretracers=enabled
# shellcheck disable=SC2086
ms gstpluginsbase $GST_COMMON -Dintrospection=enabled -Dtools=enabled \
    -Dapp=enabled -Daudioconvert=enabled -Daudiomixer=enabled -Daudiorate=enabled -Daudioresample=enabled \
    -Daudiotestsrc=enabled -Dcompositor=enabled -Ddebugutils=enabled -Ddrm=enabled -Dencoding=enabled -Dgio=enabled \
    -Dgio-typefinder=enabled -Doverlaycomposition=enabled -Dpbtypes=enabled -Dplayback=enabled -Drawparse=enabled \
    -Dsubparse=enabled -Dtcp=enabled -Dtypefind=enabled -Dvideoconvertscale=enabled -Dvideorate=enabled \
    -Dvideotestsrc=enabled -Dvolume=enabled -Dalsa=enabled -Dogg=enabled -Dopus=enabled -Dvorbis=enabled \
    -Dpango=enabled -Dx11=enabled -Dxshm=enabled -Dxi=enabled \
    -Dgl=enabled -Dgl_api=opengl,gles2 -Dgl_platform=glx,egl -Dgl_winsys=x11,egl,wayland,gbm
# shellcheck disable=SC2086
ms gstpluginsgood $GST_COMMON -Dalpha=enabled -Dapetag=enabled -Daudiofx=enabled -Daudioparsers=enabled \
    -Dauparse=enabled -Dautodetect=enabled -Davi=enabled -Ddebugutils=enabled -Ddeinterlace=enabled \
    -Dequalizer=enabled -Dflv=enabled -Dicydemux=enabled -Did3demux=enabled -Dimagefreeze=enabled \
    -Dinterleave=enabled -Disomp4=enabled -Dlevel=enabled -Dmatroska=enabled -Dmultifile=enabled \
    -Dmultipart=enabled -Dreplaygain=enabled -Drtp=enabled -Drtpmanager=enabled -Drtsp=enabled -Dudp=enabled \
    -Dvideobox=enabled -Dvideocrop=enabled -Dvideofilter=enabled -Dvideomixer=enabled -Dwavenc=enabled \
    -Dwavparse=enabled -Dy4m=enabled -Dadaptivedemux2=enabled -Dcairo=enabled -Dgdk-pixbuf=enabled \
    -Dgtk3=enabled -Djpeg=enabled -Dpng=enabled -Dpulse=enabled -Dsoup=enabled -Dv4l2=enabled -Dv4l2-gudev=enabled \
    -Dximagesrc=enabled -Dximagesrc-xshm=enabled -Dximagesrc-xfixes=enabled -Dximagesrc-xdamage=enabled
# shellcheck disable=SC2086
ms gstpluginsbad $GST_COMMON -Dintrospection=enabled -Dvideoparsers=enabled -Dmpegtsdemux=enabled \
    -Dcodectimestamper=enabled -Dva=enabled -Dv4l2codecs=enabled -Dtranscode=enabled -Dopus=enabled -Dshm=enabled
ms gstlibav -Ddoc=disabled -Dtests=disabled

# ───────────────────────────── mpv (live wallpapers) ─────────────────────────────
step "libplacebo $V_libplacebo"
# glslang (stage 4b) compiles libplacebo's Vulkan shaders. glslang 15 keeps libSPIRV only as an empty stub, and a CMake
# build may have put the libraries in /usr/lib64: make them visible in /usr/lib, or build without it (OpenGL still works)
for l in glslang SPIRV glslang-default-resource-limits SPIRV-Tools-opt SPIRV-Tools; do
    for d in /usr/lib64 /usr/local/lib /usr/local/lib64; do
        for f in "$d"/lib$l.so*; do [[ -e $f && ! -e /usr/lib/${f##*/} ]] && ln -s "$f" "/usr/lib/${f##*/}"; done
    done
done
[[ -e /usr/lib/libSPIRV.so || ! -e /usr/lib/libglslang.so ]] || ln -s libglslang.so /usr/lib/libSPIRV.so
ldconfig
echo "  glslang libraries: $(cd /usr/lib && ls libglslang.so libSPIRV.so 2>/dev/null | tr '\n' ' ')"
GLSLANG=enabled; [[ -e /usr/lib/libSPIRV.so ]] || { GLSLANG=disabled; echo "  WARNING: no glslang library, libplacebo without the Vulkan shader compiler"; }
unpack libplacebo "$(src libplacebo)"
# git submodules of libplacebo, from their own pinned releases
for p in glad:glad jinja:jinja2 markupsafe:markupsafe fast_float:fastfloat Vulkan-Headers:vulkanheaders; do
    mkdir -p "3rdparty/${p%%:*}"; tar -xf "/sources/$(src "${p#*:}")" -C "3rdparty/${p%%:*}" --strip-components=1
done
quiet meson setup build --prefix=/usr --buildtype=release -Dwrap_mode=nodownload -Dvulkan=enabled -Dvk-proc-addr=enabled \
    -Dopengl=enabled -Dgl-proc-addr=enabled -Dd3d11=disabled -Dglslang=$GLSLANG -Dshaderc=disabled -Dlcms=enabled \
    -Ddovi=enabled -Dlibdovi=disabled -Dunwind=disabled -Dxxhash=disabled -Ddemos=false -Dtests=false -Dbench=false \
    -Dfuzz=false
quiet ninja -C build; quiet ninja -C build install; done_ libplacebo
ms mpv -Dlibmpv=true -Dcplayer=true -Dlua=disabled -Djavascript=disabled -Dmanpage-build=disabled \
    -Dhtml-build=disabled -Dpdf-build=disabled -Dpipewire=enabled -Dpulse=enabled -Dalsa=enabled -Dx11=enabled \
    -Dwayland=enabled -Degl=enabled -Dgl=enabled -Dgl-x11=enabled -Degl-x11=enabled -Dvulkan=enabled \
    -Dvaapi=enabled -Dvaapi-x11=enabled -Ddrm=disabled -Dlcms2=enabled -Djpeg=enabled -Dtests=false
ldconfig

# ───────────────────────────── smoke test ─────────────────────────────
step "smoke test"
for t in "ffmpeg -hide_banner -version" "gst-inspect-1.0 --version" "mpv --version" "pactl --version" "nasm -v"; do
    printf '  %-16s ' "${t%% *}"; $t > /tmp/v.txt 2>&1 || { cat /tmp/v.txt; echo "FAILED: $t"; exit 1; }; head -1 /tmp/v.txt
done
ffmpeg -hide_banner -encoders 2>/dev/null | grep -qE " libx264 " || { echo "ffmpeg: no libx264"; exit 1; }
ffmpeg -hide_banner -encoders 2>/dev/null | grep -qE " h264_vaapi " || { echo "ffmpeg: no h264_vaapi"; exit 1; }
ffmpeg -hide_banner -devices 2>/dev/null | grep -qE "x11grab" || { echo "ffmpeg: no x11grab"; exit 1; }
ffmpeg -hide_banner -devices 2>/dev/null | grep -qE " pulse " || { echo "ffmpeg: no pulse"; exit 1; }
ffmpeg -hide_banner -devices 2>/dev/null | grep -qE "video4linux2" || { echo "ffmpeg: no v4l2"; exit 1; }
echo "  ffmpeg: libx264, h264_vaapi, x11grab, pulse, v4l2 all present"
# encode a real 2-second clip with x264 + AAC, then play it through GStreamer (playbin -> fakesink) and mpv (null outputs)
ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=320x240:rate=25 -f lavfi -i sine=frequency=440 \
    -t 2 -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac /tmp/eso-test.mp4
gst-launch-1.0 -q playbin uri=file:///tmp/eso-test.mp4 video-sink=fakesink audio-sink=fakesink > /tmp/gst.log 2>&1 \
    || { cat /tmp/gst.log; echo "FAILED: GStreamer could not play an H.264/AAC file"; exit 1; }
echo "  GStreamer playbin decoded H.264 + AAC"
mpv --no-config --vo=null --ao=null --really-quiet /tmp/eso-test.mp4 || { echo "FAILED: mpv playback"; exit 1; }
echo "  mpv decoded H.264 + AAC"
# (VA-API / v4l2 stateless decoders only register when a GPU or camera is present, so they are not checked here)
printf '  GStreamer elements: '
for e in playbin playbin3 gtksink pulsesrc pulsesink autoaudiosink alsasink ximagesrc v4l2src avdec_h264 avdec_aac \
         avdec_vp9 avdec_libdav1d matroskademux qtdemux glimagesink opusdec vorbisdec; do
    if gst-inspect-1.0 --exists "$e"; then printf '%s ' "$e"; else echo; echo "missing GStreamer element $e"; exit 1; fi
done; echo
python3 - <<'PY'
import gi
for ns, v in (("Gst", "1.0"), ("GstVideo", "1.0"), ("GstPbutils", "1.0"), ("GstApp", "1.0")):
    gi.require_version(ns, v); __import__("gi.repository." + ns)
print("  GObject introspection: Gst, GstVideo, GstPbutils, GstApp OK")
PY
for pc in gstreamer-app-1.0 gstreamer-pbutils-1.0 gstreamer-video-1.0 gstreamer-tag-1.0 gstreamer-gl-1.0 \
          gstreamer-audio-1.0 gstreamer-fft-1.0 gstreamer-mpegts-1.0 gstreamer-transcoder-1.0 vulkan libva mpv lcms2; do
    pkg-config --exists $pc || { echo "missing $pc.pc"; exit 1; }
done; echo "  pkg-config: everything WebKitGTK and the ESO apps link against is present"
rm -f /tmp/eso-test.mp4
step "stage 5d done"; du -sh /usr/lib /usr/share
