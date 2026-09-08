#!/usr/bin/env bash
# ============================================================
# build.sh — 微信键盘免跳转 deb 一键构建（纯 Windows 原生交叉编译）
#   产出：WxKbNoJump.dylib(注入) + WxKbNoJumpPrefs.bundle(设置面板) + rootless .deb
#   依赖：本机制造插件的必备东西（LLVM/clang + iOS SDK + 脚本）
# ============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ="$SCRIPT_DIR"

# 工具链：优先 WXKIT 环境变量，否则按相对路径定位
if [ -n "$WXKIT" ]; then
  KIT="$WXKIT"
else
  KIT="$(cd "$SCRIPT_DIR/../../本机制造插件的必备东西" && pwd)"
fi
SCRIPTS="$KIT/1-构建脚本"
LLVM_BIN="$KIT/3-LLVM工具链/bin"
SDK="$KIT/2-iOS_SDK/iPhoneOS.sdk"

[ -d "$KIT" ] || { echo "ERROR: 工具链未找到 $KIT"; exit 1; }
[ -x "$LLVM_BIN/clang" ] || { echo "ERROR: clang 未找到 ($LLVM_BIN)"; exit 1; }
[ -d "$SDK" ] || { echo "ERROR: SDK 未找到 ($SDK)"; exit 1; }

CLANG="$LLVM_BIN/clang"
PY=""
BUNDLED_PY="$KIT/0-运行时/python/python.exe"
if [ -e "$BUNDLED_PY" ]; then PY="$BUNDLED_PY"; else
  for c in python3 python; do command -v "$c" >/dev/null 2>&1 && { PY="$c"; break; }; done
  [ -n "$PY" ] || PY="python"
fi

winpath() { cygpath -w "$1" 2>/dev/null || echo "$1"; }
SDK_W="$(winpath "$SDK")"; SCR_W="$(winpath "$SCRIPTS")"
SRC_W="$(winpath "$PROJ/src")"; PRE_W="$(winpath "$PROJ/Preferences")"
LD64_W="$(winpath "$LLVM_BIN/ld64.lld")"

BLD="$PROJ/构建中间"; OUT="$PROJ/out"
mkdir -p "$BLD/obj" "$OUT"

VER="$(grep -i '^Version:' "$PROJ/DEBIAN/control" | head -1 | awk '{print $2}')"
VER="${VER:-1.0.0}"

FLAGS=(
  -target arm64e-apple-ios16.0
  -isysroot "$SDK_W"
  -fobjc-arc -fobjc-exceptions
  -O2 -fvisibility=hidden -fno-modules
  -Wno-implicit-function-declaration -Wno-objc-method-access -Wno-format
  -Wno-deprecated-declarations -Wno-arc-performSelector-leaks
  -D__IPHONE_OS_VERSION_MIN_REQUIRED=160000
  -I"$SRC_W" -I"$PRE_W" -I"$SCR_W"
)

echo "=================================================="
echo "  工程   : WxKbNoJumpDeb"
echo "  版本   : $VER"
echo "  工具链 : $KIT"
echo "  clang  : $CLANG"
echo "=================================================="

# ---------- 1) 注入 dylib：Tweak.m ----------
echo "==> [1] 编译注入 dylib (Tweak.m)"
"$PY" "$(winpath "$SCRIPTS/preprocess.py")" "$(winpath "$PROJ/src/Tweak.m")" "$(winpath "$BLD/Tweak.gen.m")"
"$CLANG" -c "${FLAGS[@]}" -o "$(winpath "$BLD/obj/Tweak.o")" "$(winpath "$BLD/Tweak.gen.m")"
"$CLANG" -dynamiclib -target arm64e-apple-ios16.0 -isysroot "$SDK_W" \
  -fuse-ld=lld -nostdlib -Wl,-platform_version,ios,16.0,16.0 \
  -Wl,-install_name,@rpath/WxKbNoJump.dylib -Wl,-undefined,dynamic_lookup -O2 \
  -o "$(winpath "$OUT/WxKbNoJump.dylib")" "$(winpath "$BLD/obj/Tweak.o")"
# ★ 坑F：lld 会把 cpusubtype 抹回 0x0(arm64)，强制改回 0x2(arm64e)，A14 才能加载
"$PY" "$(winpath "$PROJ/tools/fixup_macho.py")" "$(winpath "$OUT/WxKbNoJump.dylib")" "$(winpath "$OUT/WxKbNoJump.dylib.fix")" --arm64e
mv -f "$OUT/WxKbNoJump.dylib.fix" "$OUT/WxKbNoJump.dylib"
"$PY" "$(winpath "$SCRIPTS/adhoc_sign.py")" "$(winpath "$OUT/WxKbNoJump.dylib")" "$(winpath "$OUT/WxKbNoJump.dylib.signed")"
mv -f "$OUT/WxKbNoJump.dylib.signed" "$OUT/WxKbNoJump.dylib"
echo "    -> WxKbNoJump.dylib (arm64e)"

# ---------- 2) 设置面板 bundle 可执行：WxKbNoJumpSettingsController.m ----------
echo "==> [2] 编译设置面板可执行 (WxKbNoJumpPrefs)"
"$PY" "$(winpath "$SCRIPTS/preprocess.py")" "$(winpath "$PROJ/Preferences/WxKbNoJumpSettingsController.m")" "$(winpath "$BLD/Prefs.gen.m")"
"$CLANG" -c "${FLAGS[@]}" -o "$(winpath "$BLD/obj/Prefs.o")" "$(winpath "$BLD/Prefs.gen.m")"
"$CLANG" -dynamiclib -target arm64e-apple-ios16.0 -isysroot "$SDK_W" \
  -fuse-ld=lld -nostdlib -Wl,-platform_version,ios,16.0,16.0 \
  -Wl,-install_name,@rpath/WxKbNoJumpPrefs -Wl,-undefined,dynamic_lookup -O2 \
  -o "$(winpath "$BLD/obj/WxKbNoJumpPrefs")" "$(winpath "$BLD/obj/Prefs.o")"
# ★ 坑F：强制 arm64e 切片；坑E：注入 UIKit/Foundation/PreferencesUI 的 LC_LOAD_DYLIB（lld 解析不了 .tbd，只能后处理注入）
"$PY" "$(winpath "$PROJ/tools/fixup_macho.py")" "$(winpath "$BLD/obj/WxKbNoJumpPrefs")" "$(winpath "$BLD/obj/WxKbNoJumpPrefs.fix")" \
  --arm64e \
  --add-dylib "/System/Library/Frameworks/Foundation.framework/Foundation" \
              "/System/Library/Frameworks/UIKit.framework/UIKit" \
              "/System/Library/PrivateFrameworks/PreferencesUI.framework/PreferencesUI"
mv -f "$BLD/obj/WxKbNoJumpPrefs.fix" "$BLD/obj/WxKbNoJumpPrefs"
"$PY" "$(winpath "$SCRIPTS/adhoc_sign.py")" "$(winpath "$BLD/obj/WxKbNoJumpPrefs")" "$(winpath "$BLD/obj/WxKbNoJumpPrefs.signed")"
mv -f "$BLD/obj/WxKbNoJumpPrefs.signed" "$BLD/obj/WxKbNoJumpPrefs"
echo "    -> WxKbNoJumpPrefs (bundle 可执行, arm64e + 框架链接)"

# ---------- 3) 铺 rootless deb 布局 ----------
echo "==> [3] 组装 rootless deb 布局"
DEB_SRC="$BLD/deb_src"
rm -rf "$DEB_SRC"
mkdir -p "$DEB_SRC/DEBIAN" \
         "$DEB_SRC/var/jb/usr/lib/TweakInject" \
         "$DEB_SRC/var/jb/Library/PreferenceBundles/WxKbNoJumpPrefs.bundle" \
         "$DEB_SRC/var/jb/Library/PreferenceLoader/Preferences"

cp -f "$PROJ/DEBIAN/control" "$DEB_SRC/DEBIAN/control"
cp -f "$PROJ/DEBIAN/postinst" "$DEB_SRC/DEBIAN/postinst"
cp -f "$OUT/WxKbNoJump.dylib" "$DEB_SRC/var/jb/usr/lib/TweakInject/WxKbNoJump.dylib"
cp -f "$PROJ/src/Filter.plist"  "$DEB_SRC/var/jb/usr/lib/TweakInject/WxKbNoJump.plist"
cp -f "$BLD/obj/WxKbNoJumpPrefs" "$DEB_SRC/var/jb/Library/PreferenceBundles/WxKbNoJumpPrefs.bundle/WxKbNoJumpPrefs"
cp -f "$PROJ/Preferences/Info.plist" "$DEB_SRC/var/jb/Library/PreferenceBundles/WxKbNoJumpPrefs.bundle/Info.plist"
cp -f "$PROJ/Preferences/Root.plist"  "$DEB_SRC/var/jb/Library/PreferenceBundles/WxKbNoJumpPrefs.bundle/Root.plist"
cp -f "$PROJ/PreferenceLoader/WxKbNoJump.plist" "$DEB_SRC/var/jb/Library/PreferenceLoader/Preferences/WxKbNoJump.plist"

# ★ 必须：bundle 可执行与注入 dylib 需带执行位，否则 PreferenceLoader dlopen / TweakInject 加载失败
chmod 0755 "$DEB_SRC/var/jb/usr/lib/TweakInject/WxKbNoJump.dylib"
chmod 0755 "$DEB_SRC/var/jb/Library/PreferenceBundles/WxKbNoJumpPrefs.bundle/WxKbNoJumpPrefs"

# ---------- 4) 打包 ----------
echo "==> [4] 打包 .deb"
DEB="$OUT/WxKbNoJump_v${VER}_iphoneos-arm64.deb"
"$PY" "$(winpath "$SCRIPTS/../5-打包发布/build_deb_dir.py")" "$(winpath "$DEB_SRC")" "$(winpath "$DEB")"
rm -rf "$DEB_SRC"

echo ""
echo "ALL_DONE  产物: $OUT"
ls -la "$OUT"
