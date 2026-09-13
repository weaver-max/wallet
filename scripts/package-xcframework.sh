#!/bin/bash
#
# 把两个架构的 libgemstone.a 打成 XCFramework 并输出 checksum
#
# 用法: ./scripts/package-xcframework.sh
#
# 前置: BUILD_MODE=release GEMSTONE_IOS_TARGETS='aarch64-apple-ios aarch64-apple-ios-sim' \
#         just generate-stone   (在 ios/ 目录下跑)
#
# 输出: 最后一行 stdout 是 checksum，供 release.sh 捕获。
#       所有日志走 stderr，不污染 stdout。
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STONE_DIR="$ROOT_DIR/core/gemstone"
GEN_DIR="$STONE_DIR/generated/swift"
BUILD_DIR="$ROOT_DIR/build"
OUT="$BUILD_DIR/GemstoneFFI.xcframework"
HEADERS="$BUILD_DIR/include"

log() { printf '    %s\n' "$1" >&2; }
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || die "XCFramework 只能在 macOS 上打包"
command -v xcodebuild >/dev/null || die "找不到 xcodebuild"
command -v swift      >/dev/null || die "找不到 swift"

rm -rf "$OUT" "$OUT.zip" "$HEADERS"
mkdir -p "$HEADERS"

# ── headers ──────────────────────────────────────────────
[ -f "$GEN_DIR/GemstoneFFI.h" ] \
    || die "找不到 $GEN_DIR/GemstoneFFI.h，先跑 just generate-stone"
cp "$GEN_DIR/GemstoneFFI.h" "$HEADERS/"
log "header: GemstoneFFI.h"

# ── modulemap ────────────────────────────────────────────
# UniFFI 产出的文件名在不同版本间可能是 GemstoneFFI.modulemap 或 module.modulemap，
# 而 XCFramework 要求叫 module.modulemap。
if [ -f "$GEN_DIR/GemstoneFFI.modulemap" ]; then
    cp "$GEN_DIR/GemstoneFFI.modulemap" "$HEADERS/module.modulemap"
    log "modulemap: GemstoneFFI.modulemap -> module.modulemap"
elif [ -f "$GEN_DIR/module.modulemap" ]; then
    cp "$GEN_DIR/module.modulemap" "$HEADERS/module.modulemap"
    log "modulemap: module.modulemap"
else
    {
        echo "error: 找不到 modulemap。"
        echo "       确认 core/gemstone/uniffi.toml 里 generate_module_map = true，"
        echo "       然后重跑 just generate-stone。"
        echo "       $GEN_DIR 当前内容："
        ls -1 "$GEN_DIR" 2>/dev/null | sed 's/^/         /'
    } >&2
    exit 1
fi

# ── 静态库 ───────────────────────────────────────────────
DEVICE_LIB="$ROOT_DIR/core/target/aarch64-apple-ios/release/libgemstone.a"
SIM_LIB="$ROOT_DIR/core/target/aarch64-apple-ios-sim/release/libgemstone.a"

for lib in "$DEVICE_LIB" "$SIM_LIB"; do
    [ -f "$lib" ] || die "缺少 $lib
       先跑: cd ios && BUILD_MODE=release \\
             GEMSTONE_IOS_TARGETS='aarch64-apple-ios aarch64-apple-ios-sim' just generate-stone"
done
log "device lib: $(du -h "$DEVICE_LIB" | cut -f1)"
log "sim    lib: $(du -h "$SIM_LIB"    | cut -f1)"

# ── 打包 ─────────────────────────────────────────────────
xcodebuild -create-xcframework \
    -library "$DEVICE_LIB" -headers "$HEADERS" \
    -library "$SIM_LIB"    -headers "$HEADERS" \
    -output "$OUT" >/dev/null 2>&1 \
    || die "xcodebuild -create-xcframework 失败，去掉 >/dev/null 重跑看详细报错"

# 自检：两个切片都在
SLICES=$(find "$OUT" -maxdepth 1 -type d -name "ios-*" | wc -l | tr -d ' ')
[ "$SLICES" -ge 2 ] || die "XCFramework 只有 $SLICES 个切片，期望 2（真机 + 模拟器）"
log "切片: $(find "$OUT" -maxdepth 1 -type d -name 'ios-*' -exec basename {} \; | tr '\n' ' ')"

(cd "$BUILD_DIR" && zip -qr GemstoneFFI.xcframework.zip GemstoneFFI.xcframework)
log "zip: $(du -h "$OUT.zip" | cut -f1)"

# ── checksum（唯一的 stdout 输出）──────────────────────────
swift package compute-checksum "$OUT.zip"
