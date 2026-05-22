#!/usr/bin/env bash
set -euo pipefail
NdkPath="$HOME/android-ndk-r30-beta1"
ApiLevel="36"
NCpu="$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
BuildDir="$(pwd)/build"
Prefix="$BuildDir/sysroot"
OutDir="$BuildDir/out/qemu"
SrcDir="$BuildDir/src"
QemuVersion="10.0.2"
QemuGitUrl="https://github.com/wasdwasd0105/qemu-android-gunyah.git"
QemuGitRef="qemu-10.0.2"
QemuSrc="$SrcDir/qemu-${QemuVersion}"
LibucontextGitUrl="https://github.com/kaniini/libucontext.git"
LibucontextSrc="$BuildDir/libucontext"
HostOS=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$HostOS" in
  linux)   HostTag="linux-x86_64" ;;
  darwin)  HostTag="darwin-x86_64" ;;
  *) echo "不支持此系统: $HostOS" >&2; exit 1 ;;
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
export PKG_CONFIG_PATH=""
export PKG_CONFIG_LIBDIR="$Prefix/lib/pkgconfig"
export CFLAGS="-fPIC -fvisibility=default -mbranch-protection=none -ftls-model=global-dynamic -Wno-error -I$Prefix/include -DSDL_MAIN_HANDLED -I$Prefix/include/pixman-1 -DANDROID_PLATFORM="android-${ApiLevel}" "
export CPPFLAGS="$CFLAGS"
export LDFLAGS="-L$Prefix/lib -Wl,--export-dynamic -lucontext -lEGL -lGLESv2"
HostCc="${HOST_CC:-$(command -v cc || true)}"
if [ -z "$HostCc" ]; then
  echo "未找到本地 C 编译器" >&2
  exit 1
fi
ScriptDir="$(cd "$(dirname "$0")" && pwd)"
SlirpPatch="$ScriptDir/patch/slirp_android_dns.patch"
EglPatch="$ScriptDir/patch/qemu_android_egl.patch"
if [ ! -d "$QemuSrc" ]; then
  echo "克隆 QEMU 源码 ($QemuGitUrl) ref=$QemuGitRef 到 $QemuSrc"
  git clone --depth 1 --branch "$QemuGitRef" "$QemuGitUrl" "$QemuSrc"
else
  echo "使用已有的 QEMU 源码目录: $QemuSrc"
fi
if [ -f "$EglPatch" ]; then
  echo "应用 Android EGL 补丁"
  if git -C "$QemuSrc" apply --check "$EglPatch" 2>/dev/null; then
    git -C "$QemuSrc" apply "$EglPatch"
    echo "Android EGL 补丁应用成功"
  else
    echo "Android EGL 补丁已存在或不需要，跳过"
  fi
fi
if [ ! -d "$LibucontextSrc" ]; then
  echo "克隆 libucontext"
  git clone --depth 1 "$LibucontextGitUrl" "$LibucontextSrc"
fi
if [ ! -f "$Prefix/lib/libucontext.a" ]; then
  echo "编译 libucontext for Android aarch64"
  pushd "$LibucontextSrc" >/dev/null
  make clean 2>/dev/null || true
  make ARCH=aarch64 CC="$CC" AR="$AR" RANLIB="$RANLIB" FREESTANDING=yes EXPORT_UNPREFIXED=yes -j "$NCpu" libucontext.a
  mkdir -p "$Prefix/lib" "$Prefix/lib/pkgconfig" "$Prefix/include/libucontext"
  cp -f libucontext.a "$Prefix/lib/"
  cp -f libucontext.pc "$Prefix/lib/pkgconfig/" 2>/dev/null || true
  cp -f include/libucontext/libucontext.h "$Prefix/include/libucontext/" 2>/dev/null || true
  popd >/dev/null
  echo "创建 ucontext.h 兼容头文件到 $Prefix/include"
  cat > "$Prefix/include/ucontext.h" <<'UCONTEXT_SHIM'
#ifndef _ANDROID_UCONTEXT_SHIM_H
#define _ANDROID_UCONTEXT_SHIM_H
#include <libucontext/libucontext.h>
#endif
UCONTEXT_SHIM
  echo "libucontext 已安装"
else
  echo "libucontext 已存在，跳过"
fi
BitsInstalled="$Prefix/include/libucontext/bits.h"
mkdir -p "$Prefix/include/libucontext"
echo "生成 freestanding bits.h for aarch64"
cat > "$BitsInstalled" <<'GEN_BITS_H'
#ifndef LIBUCONTEXT_BITS_H
#define LIBUCONTEXT_BITS_H
#include <stddef.h>
#ifndef _UAPI__ASM_SIGCONTEXT_H
typedef struct sigcontext {
	unsigned long long fault_address;
	unsigned long long regs[31];
	unsigned long long sp;
	unsigned long long pc;
	unsigned long long pstate;
	unsigned char __reserved[4096] __attribute__((__aligned__(16)));
} mcontext_t;
#else
typedef struct sigcontext mcontext_t;
#endif
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
GEN_BITS_H
echo "bits.h 生成完毕"
LibucontextH="$Prefix/include/libucontext/libucontext.h"
if [ -f "$LibucontextH" ] && grep -q 'void (\*)()' "$LibucontextH"; then
  echo "修复 libucontext.h 函数原型"
  sed -i.bak 's|void (\*)()|void (*)(void)|g' "$LibucontextH"
  rm -f "$LibucontextH.bak"
  echo "libucontext.h 已修复"
fi
rm -rf "$OutDir"
mkdir -p "$OutDir"
mkdir -p "$Prefix/lib" "$Prefix/bin"
WrapPc="$OutDir/android-pkg-config"
cat > "$WrapPc" <<'EOF'
#!/usr/bin/env bash
exec pkg-config "$@"
EOF
chmod +x "$WrapPc"
export PKG_CONFIG="$WrapPc"
echo "pkg-config 检查 (Android 交叉编译依赖在 $Prefix)"
for lib in glib-2.0 pixman-1 epoxy virglrenderer libusb-1.0; do
  echo "$lib: $(pkg-config --modversion $lib 2>/dev/null || echo '未找到')"
done
if pkg-config --exists pixman-1; then
  PixmanOpt="--enable-pixman"
else
  PixmanOpt="--disable-pixman"
fi
cd "$OutDir"
"$QemuSrc/configure" --prefix="$Prefix" --host-cc="$HostCc" --cross-prefix="${TargetTriple}-" --cc="$CC" --cxx="$CXX" --extra-cflags="$CFLAGS" --extra-ldflags="$LDFLAGS" --with-coroutine=ucontext --disable-docs --disable-guest-agent --disable-sdl --disable-gtk --disable-cocoa --disable-curses --disable-capstone --disable-gnutls --disable-gcrypt --enable-libusb --disable-usb-redir --audio-drv-list=[] --enable-slirp --disable-vhost-user --disable-virtfs -Dcoroutine_pool=false -Dopengl=enabled -Dvirglrenderer=enabled -Dvnc=enabled -Dvnc_jpeg=disabled -Dvnc_sasl=disabled -Dgunyah=enabled $PixmanOpt --target-list="aarch64-softmmu"
Meson="$OutDir/pyvenv/bin/meson"
if [ ! -x "$Meson" ]; then
  Meson="$(command -v meson)"
fi
if [ ! -x "$Meson" ]; then
  echo "未找到 meson" >&2
  exit 1
fi
if [ -f "$SlirpPatch" ]; then
  echo "应用 SLIRP Android DNS 补丁"
  if git -C "$QemuSrc/subprojects/slirp" apply --check "$SlirpPatch" 2>/dev/null; then
    git -C "$QemuSrc/subprojects/slirp" apply "$SlirpPatch"
    echo "SLIRP 补丁应用成功"
  else
    echo "SLIRP 补丁已存在或不需要，跳过"
  fi
fi
"$Meson" compile -C "$OutDir" \
  qemu-system-aarch64 \
  qemu-img \
  -j "$NCpu"
"$Meson" install -C "$OutDir"
echo "编译安装完成"
echo "二进制文件安装到: $Prefix/bin"
ls -l "$Prefix/bin"/qemu-system-* 2>/dev/null || true
ls -l "$Prefix/bin"/qemu-img 2>/dev/null || true