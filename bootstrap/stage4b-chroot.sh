#!/bin/bash
# ESO Base stage 4b, INSIDE the chroot: LLVM + Clang (for Mesa's shader compilers), SPIR-V tools, libclc, glslang,
# then the full Mesa: modern Intel (iris + anv Vulkan), AMD (radeonsi + radv Vulkan), llvmpipe/lavapipe (fast
# software rendering for PCs without a usable GPU), nouveau, virtual machines (virgl, svga) and zink.
set -euo pipefail
. /sources/versions.env
step() { echo; echo "=== $* ($(date -u +%H:%M:%S)) ==="; }
unpack() { rm -rf "/sources/$1"; mkdir -p "/sources/$1"; tar -xf "/sources/$2" -C "/sources/$1" --strip-components=1; cd "/sources/$1"; }
done_() { cd /sources; rm -rf "/sources/$1"; }
quiet() { "$@" > /tmp/build.log 2>&1 || { tail -80 /tmp/build.log; echo "FAILED: $*"; exit 1; }; }
J=$(nproc)
CM="-G Ninja -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release -DCMAKE_SKIP_INSTALL_RPATH=ON"

if ! command -v cmake >/dev/null; then
    step "CMake $V_cmake"; unpack cmake "cmake-$V_cmake.tar.gz"
    sed -i '/"lib64"/s/64//' Modules/GNUInstallDirs.cmake
    quiet ./bootstrap --prefix=/usr --parallel="$J" --no-system-libs --no-qt-gui --docdir=/share/doc/cmake -- \
        -DCMAKE_USE_OPENSSL=ON -DBUILD_TESTING=OFF
    quiet make -j"$J"; quiet make install; done_ cmake
fi

if [[ ! -x /usr/bin/clang ]]; then
    step "LLVM + Clang $V_llvm (X86 + AMDGPU, shared libLLVM/libclang-cpp)"
    unpack llvm "llvm-project-$V_llvm.src.tar.xz"
    quiet cmake -S llvm -B build $CM -DLLVM_ENABLE_PROJECTS=clang -DLLVM_TARGETS_TO_BUILD="X86;AMDGPU" \
        -DLLVM_BUILD_LLVM_DYLIB=ON -DLLVM_LINK_LLVM_DYLIB=ON -DCLANG_LINK_CLANG_DYLIB=ON -DLLVM_ENABLE_RTTI=ON \
        -DLLVM_ENABLE_FFI=ON -DLLVM_ENABLE_ZLIB=ON -DLLVM_ENABLE_ZSTD=ON -DLLVM_ENABLE_TERMINFO=OFF \
        -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_DOCS=OFF \
        -DCLANG_INCLUDE_TESTS=OFF -DCLANG_INCLUDE_DOCS=OFF -DLLVM_PARALLEL_LINK_JOBS=2 -DLLVM_INSTALL_UTILS=ON
    quiet ninja -C build -j"$J"; quiet ninja -C build install
    mkdir -p /sources/llvm-part/llvm          # libclc is in the same tarball, built after the SPIR-V translator
    cp -a libclc cmake /sources/llvm-part/; cp -a llvm/cmake /sources/llvm-part/llvm/
    done_ llvm
fi

step "SPIR-V Headers"; unpack spirvheaders "$(basename /sources/spirvheaders-*.tar.gz)"
quiet cmake -B build $CM; quiet ninja -C build install; done_ spirvheaders
# SPIRV-Tools must be built against the headers of its own SDK release (the newer headers above are for the
# LLVM translator only; their grammar has operand types this SPIRV-Tools does not know)
step "SPIR-V Tools"; unpack spirvsdkhdr "$(basename /sources/spirvsdkhdr-*.tar.gz)"
unpack spirvtools "$(basename /sources/spirvtools-*.tar.gz)"
quiet cmake -B build $CM -DSPIRV_WERROR=OFF -DBUILD_SHARED_LIBS=ON -DSPIRV_TOOLS_BUILD_STATIC=OFF \
    -DSPIRV-Headers_SOURCE_DIR=/sources/spirvsdkhdr -DSPIRV_SKIP_TESTS=ON
quiet ninja -C build; quiet ninja -C build install; done_ spirvtools; done_ spirvsdkhdr
step "SPIR-V LLVM Translator $V_spirvllvm"; unpack spirvllvm "$(basename /sources/spirvllvm-*.tar.gz)"
quiet cmake -B build $CM -DBUILD_SHARED_LIBS=ON -DLLVM_EXTERNAL_SPIRV_HEADERS_SOURCE_DIR=/usr \
    -DLLVM_EXTERNAL_LIT=/bin/true -DLLVM_INCLUDE_TESTS=OFF
quiet ninja -C build; quiet ninja -C build install; done_ spirvllvm
step "libclc (OpenCL built-ins for Mesa)"
if [[ ! -d /sources/llvm-part/libclc ]]; then    # resumed run: LLVM was already installed, take libclc from its tarball
    rm -rf /sources/llvm-part; mkdir -p /sources/llvm-part
    tar -xf "/sources/llvm-project-$V_llvm.src.tar.xz" -C /sources/llvm-part --strip-components=1 \
        "llvm-project-$V_llvm.src/libclc" "llvm-project-$V_llvm.src/cmake" "llvm-project-$V_llvm.src/llvm/cmake"
fi
cd /sources/llvm-part/libclc                     # built inside a partial LLVM tree: it uses ../cmake/Modules
quiet cmake -B build $CM -DLIBCLC_TARGETS_TO_BUILD="spirv-mesa3d-;spirv64-mesa3d-"
quiet ninja -C build; quiet ninja -C build install; cd /sources; rm -rf llvm-part
step "glslang $V_glslang"; unpack glslang "$(basename /sources/glslang-*.tar.gz)"
quiet cmake -B build $CM -DALLOW_EXTERNAL_SPIRV_TOOLS=ON -DBUILD_SHARED_LIBS=ON -DGLSLANG_TESTS=OFF -DENABLE_OPT=ON
quiet ninja -C build; quiet ninja -C build install; done_ glslang

step "Mesa $V_mesa (full: iris, radeonsi, llvmpipe, nouveau, virgl, svga, zink + Vulkan anv/radv/lavapipe)"
unpack mesa "mesa-$V_mesa.tar.xz"
quiet meson setup build --prefix=/usr --buildtype=release -Dwrap_mode=nodownload \
    -Dplatforms=x11,wayland -Dgallium-drivers=iris,crocus,i915,radeonsi,r600,nouveau,virgl,svga,llvmpipe,softpipe,zink \
    -Dvulkan-drivers=intel,amd,swrast -Dllvm=enabled -Dshared-llvm=enabled -Dglx=dri -Degl=enabled -Dgbm=enabled \
    -Dgles1=disabled -Dgles2=enabled -Dglvnd=disabled -Dvalgrind=disabled -Dlibunwind=disabled -Dintel-rt=disabled \
    -Dvideo-codecs= -Dvulkan-layers=device-select
quiet ninja -C build; quiet ninja -C build install; done_ mesa

step "smoke test: OpenGL on llvmpipe inside ESO Base"
cat > /tmp/gltest.c <<'C'
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <stdio.h>
int main(void) {
    PFNEGLGETPLATFORMDISPLAYEXTPROC gpd = (void *)eglGetProcAddress("eglGetPlatformDisplayEXT");
    EGLDisplay d = gpd(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
    EGLint ma, mi; if (!eglInitialize(d, &ma, &mi)) { puts("eglInitialize failed"); return 1; }
    eglBindAPI(EGL_OPENGL_ES_API);
    EGLint ca[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
    EGLContext c = eglCreateContext(d, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, ca);
    if (!c || !eglMakeCurrent(d, EGL_NO_SURFACE, EGL_NO_SURFACE, c)) { puts("context failed"); return 1; }
    printf("GL renderer: %s\nGL version: %s\n", glGetString(GL_RENDERER), glGetString(GL_VERSION));
    return 0;
}
C
gcc /tmp/gltest.c -o /tmp/gltest -lEGL -lGLESv2 && LIBGL_ALWAYS_SOFTWARE=1 /tmp/gltest; rm -f /tmp/gltest*
ls /usr/share/vulkan/icd.d/ 2>/dev/null
step "stage 4b done"; du -sh /usr/lib
