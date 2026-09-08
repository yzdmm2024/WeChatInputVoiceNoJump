#!/usr/bin/env bash
# ============================================================
#  WxKeyboardNoJump 构建脚本  (TrollStore / TrollFools 注入式 dylib)
#  纯 Windows 原生交叉编译：LLVM/clang + lld + iOS16 SDK
#  不依赖 Logos / CydiaSubstrate / ElleKit（零依赖，任意注入工具可加载）
#  产物：out/WxKeyboardNoJump.dylib  +  out/Settings.bundle
# ============================================================
set -e

KIT="/c/Users/Administrator/Desktop/8月/本机制造插件的必备东西"
SCRIPTS="$KIT/1-构建脚本"
LLVM_BIN="$KIT/3-LLVM工具链/bin"
SDK="$KIT/2-iOS_SDK/iPhoneOS.sdk"
CLANG="$LLVM_BIN/clang"

PROJ="$(cd "$(dirname "$0")" && pwd)"
SRC="$PROJ/src"
OUT="$PROJ/out"
BLD="$PROJ/build"
mkdir -p "$OUT" "$BLD"

PY="/c/Users/Administrator/.workbuddy/binaries/python/versions/3.13.12/python.exe"

winpath() { cygpath -w "$1" 2>/dev/null || echo "$1"; }

[ -x "$CLANG" ] || { echo "ERROR: clang 缺失 ($CLANG)"; exit 1; }
[ -d "$SDK" ]   || { echo "ERROR: SDK 缺失 ($SDK)"; exit 1; }

SDK_W="$(winpath "$SDK")"
SRC_W="$(winpath "$SRC")"
INC_W="$(winpath "$SCRIPTS")"

NAME="WxKeyboardNoJump"

# ---------- 1) 中文转义（Windows clang 会丢弃非 ASCII 字面量）----------
echo "==> [1/4] 中文字面量转义"
"$PY" "$(winpath "$SCRIPTS/preprocess.py")" "$(winpath "$SRC/$NAME.m")" "$(winpath "$BLD/$NAME.gen.m")"

# ---------- 2) 编译 .gen.m -> .o ----------
echo "==> [2/4] 编译 (arm64 / iOS16 / ARC)"
FLAGS=(
  -target arm64-apple-ios16.0
  -isysroot "$SDK_W"
  -fobjc-arc -fobjc-exceptions
  -O2 -fvisibility=hidden -fno-modules
  -Wno-implicit-function-declaration -Wno-objc-method-access -Wno-format
  -Wno-deprecated-declarations -Wno-arc-performSelector-leaks
  -D__IPHONE_OS_VERSION_MIN_REQUIRED=160000
  -I"$SRC_W" -I"$INC_W"
)
"$CLANG" -c "${FLAGS[@]}" -o "$(winpath "$BLD/$NAME.o")" "$(winpath "$BLD/$NAME.gen.m")"

# ---------- 3) 链接为 dylib（注入型：-undefined,dynamic_lookup）----------
echo "==> [3/4] 链接 $NAME.dylib"
OUT_DYLIB="$OUT/$NAME.dylib"
"$CLANG" -dynamiclib \
  -target arm64-apple-ios16.0 \
  -isysroot "$SDK_W" \
  -fuse-ld=lld -nostdlib \
  -Wl,-platform_version,ios,16.0,16.0 \
  -Wl,-install_name,@rpath/$NAME.dylib \
  -Wl,-undefined,dynamic_lookup \
  -O2 \
  -o "$(winpath "$OUT_DYLIB")" \
  "$(winpath "$BLD/$NAME.o")"

# ---------- 4) adhoc 签名 + 拷贝 Settings.bundle ----------
echo "==> [4/4] adhoc 签名 + 打包 Settings.bundle"
"$PY" "$(winpath "$SCRIPTS/adhoc_sign.py")" "$(winpath "$OUT_DYLIB")" "$(winpath "$OUT_DYLIB.signed")"
mv -f "$OUT_DYLIB.signed" "$OUT_DYLIB"
rm -rf "$OUT/Settings.bundle"
cp -r "$PROJ/Settings.bundle" "$OUT/Settings.bundle"

echo ""
echo "ALL_DONE  产物目录: $OUT"
ls -la "$OUT"
