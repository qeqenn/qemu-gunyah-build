#!/usr/bin/env bash
set -euo pipefail
NdkPath="$HOME/android-ndk-r30-beta1"
BuildDir="$(pwd)/build"
Prefix="$BuildDir/sysroot"
SysLib="$Prefix/lib"
SysBin="$Prefix/bin"
JniLibDir="$Prefix/jniLibs"
QvmDir="qvm"
QvmLib="$QvmDir/lib"
FwSrc="$Prefix/share/qemu"
QvmFw="$QvmDir/fw"
HostOS=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$HostOS" in
  linux)   HostTag="linux-x86_64" ;;
  darwin)  HostTag="darwin-x86_64" ;;
  *) echo "不支持此系统: $HostOS" >&2; exit 1 ;;
esac
Readelf="$NdkPath/toolchains/llvm/prebuilt/$HostTag/bin/llvm-readelf"
Strip="$NdkPath/toolchains/llvm/prebuilt/$HostTag/bin/llvm-strip"
rm -rf "$QvmDir"
mkdir -p "$QvmLib"
command -v patchelf >/dev/null 2>&1 || { echo "需要 patchelf" >&2; exit 1; }
need() { [ -f "$1" ] || { echo "缺少: $1" >&2; exit 1; }; }
retagSoname() { [ -f "$1" ] && patchelf --set-soname "$(basename "$1")" "$1"; }
rn() { patchelf --replace-needed "$1" "$2" "$3" 2>/dev/null || true; }
copyLib() { local src="$1" dst="$2"; need "$src"; cp -Lf "$src" "$dst"; }
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
[ -f "$SysLib/libusb-1.0.so" ]      && copyLib "$SysLib/libusb-1.0.so"      "$QvmLib/libusb-1.0.so"
soDir="$JniLibDir/libqemu-system-aarch64.so"
if [ -f "$soDir" ]; then
  copyLib "$soDir" "$QvmLib/libqemu-system-aarch64.so"
else
  echo "跳过缺失 $soDir"
fi
exe="$SysBin/qemu-system-aarch64"
if [ -f "$exe" ]; then
  $Strip --strip-all "$exe" -o "$QvmDir/qemu-system-aarch64"
else
  echo "跳过缺失 $exe"
fi
exe="$SysBin/qemu-img"
if [ -f "$exe" ]; then
  $Strip --strip-all "$exe" -o "$QvmDir/qemu-img"
else
  echo "跳过缺失 $exe"
fi
for so in "$QvmLib"/*.so; do
  retagSoname "$so"
done
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
so="$QvmLib/libqemu-system-aarch64.so"
if [ -f "$so" ]; then
  echo "修补 NEEDED 条目 $(basename "$so")"
  rn libslirp.so.0         libslirp.so         "$so"
  rn libgio-2.0.so.0       libgio-2.0.so       "$so"
  rn libgobject-2.0.so.0   libgobject-2.0.so   "$so"
  rn libglib-2.0.so.0      libglib-2.0.so      "$so"
  rn libgmodule-2.0.so.0   libgmodule-2.0.so   "$so"
  rn libintl.so.8          libintl.so          "$so"
  rn libepoxy.so.0         libepoxy.so         "$so"
  rn libvirglrenderer.so.1 libvirglrenderer.so "$so"
  rn libusb-1.0.so.0       libusb-1.0.so       "$so"
fi
exe="$QvmDir/qemu-system-aarch64"
if [ -f "$exe" ]; then
  echo "修补 NEEDED 条目 $(basename "$exe")"
  rn libslirp.so.0       libslirp.so       "$exe"
  rn libgio-2.0.so.0     libgio-2.0.so     "$exe"
  rn libgobject-2.0.so.0 libgobject-2.0.so "$exe"
  rn libglib-2.0.so.0    libglib-2.0.so    "$exe"
  rn libgmodule-2.0.so.0 libgmodule-2.0.so "$exe"
  rn libintl.so.8        libintl.so        "$exe"
  rn libepoxy.so.0       libepoxy.so       "$exe"
  rn libvirglrenderer.so.1 libvirglrenderer.so "$exe"
  rn libusb-1.0.so.0     libusb-1.0.so     "$exe"
fi
exe="$QvmDir/qemu-img"
if [ -f "$exe" ]; then
  echo "修补 NEEDED 条目 $(basename "$exe")"
  rn libgio-2.0.so.0     libgio-2.0.so     "$exe"
  rn libgobject-2.0.so.0 libgobject-2.0.so "$exe"
  rn libglib-2.0.so.0    libglib-2.0.so    "$exe"
  rn libgmodule-2.0.so.0 libgmodule-2.0.so "$exe"
  rn libintl.so.8        libintl.so        "$exe"
fi
for so in "$QvmLib"/*.so; do
  basename "$so"
  $Readelf -d "$so" | grep -E 'SONAME|NEEDED' || true
done
for exe in "$QvmDir"/qemu-system-* "$QvmDir"/qemu-img; do
  [ -f "$exe" ] || continue
  basename "$exe"
  $Readelf -d "$exe" | grep -E 'NEEDED' || true
done
if [ -d "$FwSrc" ]; then
  echo "复制固件从 $FwSrc 至 $QvmFw"
  mkdir -p "$QvmFw/keymaps"
  [ -f "$FwSrc/efi-virtio.rom" ]   && cp -a "$FwSrc/efi-virtio.rom"   "$QvmFw/"
  [ -f "$FwSrc/keymaps/en-us" ]    && cp -a "$FwSrc/keymaps/en-us"    "$QvmFw/keymaps/"
  echo "固件已复制至 $QvmFw"
fi
echo "产物已存至 $QvmDir"
tar --numeric-owner -cp qvm/* | xz -9e --arm64 --lzma2=dict=64MB,nice=273 -T 1 > qvm.xz
echo "产物压缩至 qvm.xz"