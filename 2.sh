#!/usr/bin/env bash
set -euo pipefail
NdkPath="$HOME/android-ndk-r30-beta1"
ApiLevel="36"
NCpu="$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
BuildDir="$(pwd)/build"
Prefix="$BuildDir/sysroot"
OutDir="$BuildDir/out/qemu"
SrcDir="$BuildDir/src"
QvmGitUrl="https://github.com/AnyLaySys/qemu-gunyah.git"
QvmSrc="$SrcDir/qemu-gunyah-main"
LibucontextGitUrl="https://github.com/kaniini/libucontext.git"
LibucontextSrc="$BuildDir/libucontext"
HostOS=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$HostOS" in
  linux) HostTag="linux-x86_64" ;;
  darwin) HostTag="darwin-x86_64" ;;
  *) echo "Unsupported OS: $HostOS" >&2; exit 1 ;;
esac
Toolchain="$NdkPath/toolchains/llvm/prebuilt/$HostTag"
TargetTriple=aarch64-linux-android
export CC="$Toolchain/bin/${TargetTriple}${ApiLevel}-clang"
export CXX="$Toolchain/bin/${TargetTriple}${ApiLevel}-clang++"
export AR="$Toolchain/bin/llvm-ar"
export NM="$Toolchain/bin/llvm-nm"
export RANLIB="$Toolchain/bin/llvm-ranlib"
export STRIP="$Toolchain/bin/llvm-strip"
export OBJCOPY="$Toolchain/bin/llvm-objcopy"
export LD="$Toolchain/bin/ld.lld"
export PKG_CONFIG_PATH="$Prefix/lib/pkgconfig:$Prefix/share/pkgconfig"
export PKG_CONFIG_LIBDIR="$Prefix/lib/pkgconfig:$Prefix/share/pkgconfig"
export CFLAGS="-fPIC -fvisibility=default -mbranch-protection=none -ftls-model=global-dynamic -Wno-error -I$Prefix/include -DSDL_MAIN_HANDLED -I$Prefix/include/pixman-1 -DANDROID_PLATFORM=android-${ApiLevel}"
export CPPFLAGS="$CFLAGS"
export LDFLAGS="-L$Prefix/lib -Wl,--export-dynamic -lucontext -lEGL -lGLESv2"
HostCc="${HOST_CC:-$(command -v cc || true)}"
if [ -z "$HostCc" ]; then
  exit 1
fi
ScriptDir="$(cd "$(dirname "$0")" && pwd)"
SlirpPatch="$ScriptDir/patch/slirp_android_dns.patch"
if [ ! -d "$QvmSrc" ]; then
  git clone --depth 1 "$QvmGitUrl" "$QvmSrc"
fi
if [ ! -d "$LibucontextSrc" ]; then
  git clone --depth 1 "$LibucontextGitUrl" "$LibucontextSrc"
fi
if [ ! -f "$Prefix/lib/libucontext.a" ]; then
  pushd "$LibucontextSrc" >/dev/null
  make clean 2>/dev/null || true
  make ARCH=aarch64 CC="$CC" AR="$AR" RANLIB="$RANLIB" FREESTANDING=yes EXPORT_UNPREFIXED=yes -j "$NCpu" libucontext.a
  mkdir -p "$Prefix/lib" "$Prefix/lib/pkgconfig" "$Prefix/include/libucontext"
  cp -f libucontext.a "$Prefix/lib/"
  cp -f libucontext.pc "$Prefix/lib/pkgconfig/"
  cp -f include/libucontext/libucontext.h "$Prefix/include/libucontext/"
  popd >/dev/null
  cat > "$Prefix/include/ucontext.h" <<'EOF'
#ifndef _ANDROID_UCONTEXT_SHIM_H
#define _ANDROID_UCONTEXT_SHIM_H
#include <libucontext/libucontext.h>
#endif
EOF
fi
BitsInstalled="$Prefix/include/libucontext/bits.h"
if [ ! -f "$BitsInstalled" ]; then
  mkdir -p "$Prefix/include/libucontext"
  cat > "$BitsInstalled" <<'EOF'
#ifndef LIBUCONTEXT_BITS_H
#define LIBUCONTEXT_BITS_H
#include <stddef.h>
typedef struct sigcontext {
	unsigned long long fault_address;
	unsigned long long regs[31];
	unsigned long long sp;
	unsigned long long pc;
	unsigned long long pstate;
	unsigned char __reserved[4096] __attribute__((__aligned__(16)));
} mcontext_t;
typedef struct {
	void *ss_sp;
	int ss_flags;
	size_t ss_size;
} libucontext_stack_t;
typedef struct libucontext_ucontext {
	unsigned long uc_flags;
	struct libucontext_ucontext *uc_link;
	libucontext_stack_t uc_stack;
	unsigned char __pad[128];
	mcontext_t uc_mcontext;
} libucontext_ucontext_t;
#endif
EOF
fi
LibucontextH="$Prefix/include/libucontext/libucontext.h"
if [ -f "$LibucontextH" ] && grep -q 'void (\*)()' "$LibucontextH"; then
  sed -i 's|void (\*)()|void (*)(void)|g' "$LibucontextH"
fi
if [ ! -d "$OutDir" ]; then
  mkdir -p "$OutDir"
fi
mkdir -p "$Prefix/lib" "$Prefix/bin"
WrapPc="$OutDir/android-pkg-config"
if [ ! -f "$WrapPc" ]; then
  cat > "$WrapPc" <<EOF
#!/usr/bin/env bash
export PKG_CONFIG_PATH="$Prefix/lib/pkgconfig:$Prefix/share/pkgconfig"
export PKG_CONFIG_LIBDIR="$Prefix/lib/pkgconfig:$Prefix/share/pkgconfig"
exec pkg-config "\$@"
EOF
fi
chmod +x "$WrapPc"
export PKG_CONFIG="$WrapPc"
if [ ! -f "$Prefix/lib/libX11.so" ]; then
  mkdir -p "$BuildDir/x11_tmp" && pushd "$BuildDir/x11_tmp" >/dev/null
  BASE_URL="https://packages.termux.dev/apt/termux-main/pool/main"
  fetch_deb() {
    local pkg=$1
    local subpath=$2
    local url="${BASE_URL}/${subpath}/"
    local deb_name=$(curl -sL -A "Mozilla/5.0" "$url" | grep -oE "${pkg}_[^_]+_aarch64\.deb" | sort -V | tail -n1 || true)
    if [ -z "$deb_name" ]; then
      deb_name=$(curl -sL -A "Mozilla/5.0" "$url" | grep -oE "${pkg}_[^_]+_all\.deb" | sort -V | tail -n1 || true)
    fi
    if [ -n "$deb_name" ]; then
      wget -q -c "${url}${deb_name}"
    fi
  }
  fetch_deb "libx11" "libx/libx11"
  fetch_deb "libxext" "libx/libxext"
  fetch_deb "libxcb" "libx/libxcb"
  fetch_deb "libxau" "libx/libxau"
  fetch_deb "libxdmcp" "libx/libxdmcp"
  fetch_deb "libxrender" "libx/libxrender"
  fetch_deb "libxfixes" "libx/libxfixes"
  fetch_deb "libxcursor" "libx/libxcursor"
  fetch_deb "libxrandr" "libx/libxrandr"
  fetch_deb "libxi" "libx/libxi"
  fetch_deb "xorgproto" "x/xorgproto"
  for deb in *.deb; do
    ar x "$deb"
    if [ -f data.tar.zst ]; then
      tar --zstd -xf data.tar.zst
    elif [ -f data.tar.xz ]; then
      tar -xf data.tar.xz
    fi
    rm -f "$deb" data.tar.* control.tar.* debian-binary
  done
  mkdir -p "$Prefix/include" "$Prefix/lib"
  for d in usr data/data/com.termux/files/usr; do
    [ -d "$d/include" ] && cp -rf "$d/include/"* "$Prefix/include/"
    [ -d "$d/lib" ] && cp -rf "$d/lib/"* "$Prefix/lib/"
  done
  find "$Prefix/lib/pkgconfig" -name "*.pc" -type f -exec sed -i "s|/data/data/com.termux/files/usr|$Prefix|g" {} +
  popd >/dev/null && rm -rf "$BuildDir/x11_tmp"
fi
SdlSrc="$SrcDir/SDL2"
if [ ! -d "$SdlSrc" ]; then
  git clone --depth 1 --branch SDL2 https://github.com/libsdl-org/SDL.git "$SdlSrc"
fi
if [ -d "$SdlSrc" ]; then
  if git -C "$SdlSrc" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$SdlSrc" checkout -- CMakeLists.txt include/SDL_config_android.h src/SDL.c src/video/x11/SDL_x11xinput2.h
  fi
  SdlConfigH="$SdlSrc/include/SDL_config_android.h"
  if [ -f "$SdlConfigH" ]; then
    sed -i '/SDL_VIDEO_DRIVER_X11/d;/SDL_VIDEO_DRIVER_ANDROID/d' "$SdlConfigH"
    sed -i '/\/\* Enable various video drivers \*\//a #define SDL_VIDEO_DRIVER_X11 1' "$SdlConfigH"
    sed -i '/SDL_VIDEO_OPENGL_ES/d;/SDL_VIDEO_OPENGL_ES2/d;/SDL_VIDEO_OPENGL_EGL/d;/SDL_VIDEO_RENDER_OGL_ES/d;/SDL_VIDEO_RENDER_OGL_ES2/d' "$SdlConfigH"
  fi
  if [ -f "$SdlSrc/src/SDL.c" ]; then
    sed -i 's/if (!SDL_MainIsReady)/if (0 \&\& !SDL_MainIsReady)/g' "$SdlSrc/src/SDL.c"
  fi
  SdlXinput2H="$SdlSrc/src/video/x11/SDL_x11xinput2.h"
  if [ -f "$SdlXinput2H" ]; then
    sed -i '/^#ifndef SDL_VIDEO_DRIVER_X11_SUPPORTS_GENERIC_EVENTS$/,/^#endif$/d' "$SdlXinput2H"
  fi
  if ! grep -q 'ANDROID_X11_LIBS' "$SdlSrc/CMakeLists.txt"; then
    sed -i "0,/if(ANDROID)/s@if(ANDROID)@if(ANDROID)\\
  link_directories($Prefix/lib)\\
  set(HAVE_X11 TRUE)\\
  set(HAVE_SDL_VIDEO TRUE)\\
  set(SDL_VIDEO_DRIVER_X11 1)\\
  set(ANDROID_X11_LIBS X11 Xext xcb Xau Xdmcp Xrender X11-xcb)\\
  file(GLOB X11_SOURCES \${SDL2_SOURCE_DIR}/src/video/x11/*.c)\\
  list(APPEND SOURCE_FILES \${X11_SOURCES})\\
  list(APPEND SOURCE_FILES \${SDL2_SOURCE_DIR}/src/core/unix/SDL_poll.c)\\
  foreach(_LIB \${ANDROID_X11_LIBS})\\
    list(APPEND EXTRA_LIBS $Prefix/lib/lib\${_LIB}.so)\\
  endforeach()@" "$SdlSrc/CMakeLists.txt"
  fi
  sed -i 's/set(SDL_X11_DEFAULT OFF)/set(SDL_X11_DEFAULT OFF)/g' "$SdlSrc/CMakeLists.txt"
  sed -i 's/set(SDL_X11 OFF)/set(SDL_X11 OFF)/g' "$SdlSrc/CMakeLists.txt"
fi

rm -rf "$SdlSrc/build-android"
rm -f "$Prefix/lib/libSDL2.so" "$Prefix/lib/pkgconfig/sdl2.pc"
mkdir -p "$SdlSrc/build-android"
pushd "$SdlSrc/build-android" >/dev/null
cmake .. \
  -DCMAKE_TOOLCHAIN_FILE="$NdkPath/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-$ApiLevel \
  -DCMAKE_INSTALL_PREFIX="$Prefix" \
  -DCMAKE_FIND_ROOT_PATH="$Prefix" \
  -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH \
  -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
  -DCMAKE_PREFIX_PATH="$Prefix" \
  -DCMAKE_INCLUDE_PATH="$Prefix/include" \
  -DCMAKE_LIBRARY_PATH="$Prefix/lib" \
  -DCMAKE_C_FLAGS="$CFLAGS" \
  -DCMAKE_CXX_FLAGS="$CPPFLAGS" \
  -DCMAKE_SHARED_LINKER_FLAGS="-L$Prefix/lib" \
  -DCMAKE_EXE_LINKER_FLAGS="-L$Prefix/lib" \
  -DCMAKE_VERBOSE_MAKEFILE=ON \
  -DSDL_STATIC=OFF \
  -DSDL_SHARED=ON \
  -DSDL_X11=OFF \
  -DSDL_X11_SHARED=OFF \
  -DSDL_VULKAN=OFF \
  -DSDL_OPENGL=OFF \
  -DSDL_OPENGLES=OFF \
  -DSDL_ANDROID=ON \
  -DHAVE_X11_XLIB_H=1 \
  -DX11_X11_LIB="$Prefix/lib/libX11.so" \
  -DX11_Xext_LIB="$Prefix/lib/libXext.so" \
  -DX11_Xrender_LIB="$Prefix/lib/libXrender.so"
make -j "$NCpu" install
popd >/dev/null
if pkg-config --exists pixman-1; then
  PixmanOpt="--enable-pixman"
else
  PixmanOpt="--disable-pixman"
fi
DisplayOpts=(--disable-gtk -Dgtk=disabled -Dvnc=enabled -Dvnc_jpeg=disabled -Dvnc_sasl=disabled)
if pkg-config --exists sdl2; then
  DisplayOpts+=(--enable-sdl -Dsdl=enabled -Dopengl=enabled)
else
  DisplayOpts+=(--disable-sdl -Dsdl=disabled)
fi
cd "$OutDir"
"$QvmSrc/configure" --prefix="$Prefix" --host-cc="$HostCc" --cross-prefix="${TargetTriple}-" --cc="$CC" --cxx="$CXX" --extra-cflags="$CFLAGS" --extra-ldflags="$LDFLAGS -lX11 -lXext -lxcb -lXau -lXdmcp -lXrender -lX11-xcb" --with-coroutine=ucontext --disable-docs --disable-guest-agent --disable-cocoa --disable-curses --disable-capstone --disable-gnutls --disable-gcrypt --disable-plugins --disable-libusb --disable-usb-redir --disable-tpm --disable-vhost-kernel --disable-vhost-net --disable-vhost-vdpa --audio-drv-list=[] --enable-slirp --disable-vhost-user --disable-virtfs -Dcoroutine_pool=false -Dopengl=enabled -Dvirglrenderer=enabled -Dgunyah=enabled -Dcoroutine_backend=sigaltstack -Dwhpx=disabled -Dhvf=disabled -Dnvmm=disabled -Dxen=disabled -Dxen_pci_passthrough=disabled "$PixmanOpt" "${DisplayOpts[@]}" --target-list="aarch64-softmmu"
Meson="$OutDir/pyvenv/bin/meson"
if [ ! -x "$Meson" ]; then
  Meson="$(command -v meson)"
fi
Ninja="$(command -v ninja || true)"
if [ -f "$SlirpPatch" ] && git -C "$QvmSrc/subprojects/slirp" apply --check "$SlirpPatch" 2>/dev/null; then
  git -C "$QvmSrc/subprojects/slirp" apply "$SlirpPatch"
fi
if [ -n "$Ninja" ]; then
  "$Ninja" -C "$OutDir" -t clean qemu-system-aarch64 qemu-img >/dev/null
fi
"$Meson" compile -C "$OutDir" qemu-system-aarch64 qemu-img -j "$NCpu"
mkdir -p "$Prefix/bin" "$Prefix/share/qemu/keymaps"
cp -f "$OutDir/qemu-system-aarch64" "$Prefix/bin/qemu-system-aarch64"
cp -f "$OutDir/qemu-img" "$Prefix/bin/qemu-img"
if [ -f "$OutDir/subprojects/slirp/libslirp.so.0.4.0" ]; then
  cp -Lf "$OutDir/subprojects/slirp/libslirp.so.0.4.0" "$Prefix/lib/libslirp.so.0.4.0"
  ln -sf libslirp.so.0.4.0 "$Prefix/lib/libslirp.so.0"
  ln -sf libslirp.so.0 "$Prefix/lib/libslirp.so"
fi
[ -f "$QvmSrc/pc-bios/efi-virtio.rom" ] && cp -f "$QvmSrc/pc-bios/efi-virtio.rom" "$Prefix/share/qemu/efi-virtio.rom"
[ -f "$QvmSrc/pc-bios/keymaps/en-us" ] && cp -f "$QvmSrc/pc-bios/keymaps/en-us" "$Prefix/share/qemu/keymaps/en-us"
cd "$ScriptDir"
SysLib="$Prefix/lib"
SysBin="$Prefix/bin"
QvmDir="qemu-gunyah"
QvmLib="$QvmDir/lib"
FwSrc="$Prefix/share/qemu"
QvmFw="$QvmDir/fw"
Readelf="$NdkPath/toolchains/llvm/prebuilt/$HostTag/bin/llvm-readelf"
Strip="$NdkPath/toolchains/llvm/prebuilt/$HostTag/bin/llvm-strip"
rm -rf "$QvmDir"
mkdir -p "$QvmLib"
retagSoname() { [ -f "$1" ] && patchelf --set-soname "$(basename "$1")" "$1"; }
rn() { patchelf --replace-needed "$1" "$2" "$3" 2>/dev/null || true; }
strip_needed() { [ -f "$2" ] && patchelf --remove-needed "$1" "$2" 2>/dev/null || true; }
copyLib() { local src="$1" dst="$2"; [ -f "$src" ] && cp -Lf "$src" "$dst"; }
copyLib "$SysLib/libgio-2.0.so.0"     "$QvmLib/libgio-2.0.so"
copyLib "$SysLib/libgobject-2.0.so.0" "$QvmLib/libgobject-2.0.so"
copyLib "$SysLib/libglib-2.0.so.0"    "$QvmLib/libglib-2.0.so"
copyLib "$SysLib/libgmodule-2.0.so.0" "$QvmLib/libgmodule-2.0.so"
copyLib "$SysLib/libintl.so.8"        "$QvmLib/libintl.so"
copyLib "$SysLib/libpcre2-8.so"       "$QvmLib/libpcre2-8.so"
copyLib "$SysLib/libslirp.so.0"       "$QvmLib/libslirp.so"
copyLib "$SysLib/libpixman-1.so"      "$QvmLib/libpixman-1.so"
[ -f "$SysLib/libgthread-2.0.so.0" ] && copyLib "$SysLib/libgthread-2.0.so.0" "$QvmLib/libgthread-2.0.so"
[ -f "$SysLib/libffi.so" ]           && copyLib "$SysLib/libffi.so"           "$QvmLib/libffi.so"
[ -f "$SysLib/libepoxy.so" ]         && copyLib "$SysLib/libepoxy.so"         "$QvmLib/libepoxy.so"
[ -f "$SysLib/libvirglrenderer.so" ] && copyLib "$SysLib/libvirglrenderer.so" "$QvmLib/libvirglrenderer.so"
[ -f "$SysLib/libSDL2.so" ]          && copyLib "$SysLib/libSDL2.so"          "$QvmLib/libSDL2.so"
[ -f "$SysLib/libX11.so" ]           && copyLib "$SysLib/libX11.so"           "$QvmLib/libX11.so"
[ -f "$SysLib/libXext.so" ]          && copyLib "$SysLib/libXext.so"          "$QvmLib/libXext.so"
[ -f "$SysLib/libxcb.so" ]           && copyLib "$SysLib/libxcb.so"           "$QvmLib/libxcb.so"
[ -f "$SysLib/libXau.so" ]           && copyLib "$SysLib/libXau.so"           "$QvmLib/libXau.so"
[ -f "$SysLib/libXdmcp.so" ]         && copyLib "$SysLib/libXdmcp.so"         "$QvmLib/libXdmcp.so"
[ -f "$SysLib/libXrender.so" ]       && copyLib "$SysLib/libXrender.so"       "$QvmLib/libXrender.so"
[ -f "$SysLib/libX11-xcb.so" ]      && copyLib "$SysLib/libX11-xcb.so"      "$QvmLib/libX11-xcb.so"
[ -f "$SysBin/qemu-system-aarch64" ] && $Strip --strip-all "$SysBin/qemu-system-aarch64" -o "$QvmDir/qemu-system-aarch64"
[ -f "$SysBin/qemu-img" ] && $Strip --strip-all "$SysBin/qemu-img" -o "$QvmDir/qemu-img"
for so in "$QvmLib"/*.so; do retagSoname "$so"; done
strip_needed libandroid-support.so "$QvmLib/libX11.so"
strip_needed libandroid-support.so "$QvmLib/libX11-xcb.so"
rn libglib-2.0.so.0    libglib-2.0.so    "$QvmLib/libgio-2.0.so"
rn libgobject-2.0.so.0 libgobject-2.0.so "$QvmLib/libgio-2.0.so"
rn libgmodule-2.0.so.0 libgmodule-2.0.so "$QvmLib/libgio-2.0.so"
rn libintl.so.8        libintl.so        "$QvmLib/libgio-2.0.so"
rn libglib-2.0.so.0    libglib-2.0.so    "$QvmLib/libgobject-2.0.so"
rn libintl.so.8        libintl.so        "$QvmLib/libgobject-2.0.so"
rn libglib-2.0.so.0    libglib-2.0.so    "$QvmLib/libgmodule-2.0.so"
rn libintl.so.8        libintl.so        "$QvmLib/libglib-2.0.so"
rn libglib-2.0.so.0    libglib-2.0.so    "$QvmLib/libslirp.so"
rn libintl.so.8        libintl.so        "$QvmLib/libslirp.so"
if [ -f "$QvmLib/libvirglrenderer.so" ]; then
  rn libepoxy.so.0       libepoxy.so       "$QvmLib/libvirglrenderer.so"
  rn libglib-2.0.so.0    libglib-2.0.so    "$QvmLib/libvirglrenderer.so"
  rn libintl.so.8        libintl.so        "$QvmLib/libvirglrenderer.so"
fi
if [ -f "$QvmLib/libSDL2.so" ]; then
  rn libX11.so.6   libX11.so   "$QvmLib/libSDL2.so"
  rn libXext.so.6  libXext.so  "$QvmLib/libSDL2.so"
  rn libXrender.so.1 libXrender.so "$QvmLib/libSDL2.so"
  rn libX11-xcb.so.1 libX11-xcb.so "$QvmLib/libSDL2.so"
fi
[ -f "$QvmLib/libX11.so" ] && rn libxcb.so.1 libxcb.so "$QvmLib/libX11.so"
[ -f "$QvmLib/libX11-xcb.so" ] && rn libxcb.so.1 libxcb.so "$QvmLib/libX11-xcb.so"
if [ -f "$QvmLib/libxcb.so" ]; then
  rn libXau.so.6   libXau.so   "$QvmLib/libxcb.so"
  rn libXdmcp.so.6 libXdmcp.so "$QvmLib/libxcb.so"
fi
exe="$QvmDir/qemu-system-aarch64"
if [ -f "$exe" ]; then
  rn libslirp.so.0       libslirp.so       "$exe"
  rn libgio-2.0.so.0     libgio-2.0.so     "$exe"
  rn libgobject-2.0.so.0 libgobject-2.0.so "$exe"
  rn libglib-2.0.so.0    libglib-2.0.so    "$exe"
  rn libgmodule-2.0.so.0 libgmodule-2.0.so "$exe"
  rn libintl.so.8        libintl.so        "$exe"
  rn libepoxy.so.0       libepoxy.so       "$exe"
  rn libvirglrenderer.so.1 libvirglrenderer.so "$exe"
  rn libSDL2-2.0.so.0    libSDL2.so        "$exe"
  rn libX11.so.6         libX11.so         "$exe"
  rn libXext.so.6        libXext.so        "$exe"
  rn libxcb.so.1         libxcb.so         "$exe"
fi
exe="$QvmDir/qemu-img"
if [ -f "$exe" ]; then
  rn libgio-2.0.so.0     libgio-2.0.so     "$exe"
  rn libgobject-2.0.so.0 libgobject-2.0.so "$exe"
  rn libglib-2.0.so.0    libglib-2.0.so    "$exe"
  rn libgmodule-2.0.so.0 libgmodule-2.0.so "$exe"
  rn libintl.so.8        libintl.so        "$exe"
fi
if [ -d "$FwSrc" ]; then
  mkdir -p "$QvmFw/keymaps"
  [ -f "$FwSrc/efi-virtio.rom" ] && cp -a "$FwSrc/efi-virtio.rom" "$QvmFw/"
  [ -f "$FwSrc/keymaps/en-us" ] && cp -a "$FwSrc/keymaps/en-us" "$QvmFw/keymaps/"
fi
adb push "$QvmDir" /data/local/tmp/als
