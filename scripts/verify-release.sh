#!/bin/bash
#
# gemstone 发布验收（GitHub）
#
# 「发布成功」的定义不是「脚本跑完没报错」，是「下游能拉下来跑起来」。
#
# 用法: ./scripts/verify-release.sh 2.114.10
#       ./scripts/verify-release.sh 2.114.10 --skip-samples   (只做快检，不编示例工程)
#
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

VERSION=""
SKIP_SAMPLES=0
for arg in "$@"; do
    case "$arg" in
        --skip-samples) SKIP_SAMPLES=1 ;;
        -*)             echo "未知参数: $arg" >&2; exit 1 ;;
        *)              VERSION="$arg" ;;
    esac
done
[ -n "$VERSION" ] || { echo "用法: $0 <version> [--skip-samples]" >&2; exit 1; }

if [ -f scripts/release.env ]; then
    # shellcheck disable=SC1091
    source scripts/release.env
fi
MAVEN_GROUP="${MAVEN_GROUP:-com.gemwallet.gemstone}"
MAVEN_ARTIFACT="${MAVEN_ARTIFACT:-gemstone}"

FAIL=0
ok()      { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()     { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=1; }
skip()    { printf '  \033[90m-\033[0m %s\n' "$1"; }
section() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

section "AAR 结构（本机 ~/.m2）"
M2_DIR="$HOME/.m2/repository/$(echo "$MAVEN_GROUP" | tr '.' '/')/$MAVEN_ARTIFACT"
AAR=$(find "$M2_DIR" -name "${MAVEN_ARTIFACT}-${VERSION}.aar" 2>/dev/null | head -1)
if [ -n "$AAR" ]; then
    for abi in arm64-v8a armeabi-v7a x86_64; do
        if unzip -l "$AAR" 2>/dev/null | grep -q "jni/${abi}/libgemstone.so"; then
            ok "ABI ${abi}"
        else
            bad "AAR 缺少 ${abi}"
        fi
    done
    SRC_JAR="${AAR%.aar}-sources.jar"
    if [ -f "$SRC_JAR" ] && unzip -l "$SRC_JAR" 2>/dev/null | grep -q "gemstone.kt"; then
        ok "sources jar 含 gemstone.kt"
    else
        bad "sources jar 缺少绑定源码"
    fi
else
    skip "本机 ~/.m2 无 ${VERSION}（只在 publishToMavenLocal 后可查）"
fi

section "XCFramework 结构（本机 build/）"
XCF="$ROOT_DIR/build/GemstoneFFI.xcframework"
if [ -d "$XCF" ]; then
    N=$(find "$XCF" -maxdepth 1 -type d -name "ios-*" | wc -l | tr -d ' ')
    if [ "$N" -ge 2 ]; then
        ok "切片 ${N} 个: $(find "$XCF" -maxdepth 1 -type d -name 'ios-*' -exec basename {} \; | tr '\n' ' ')"
    else
        bad "只有 ${N} 个切片，期望 2（真机 + 模拟器）"
    fi
    if find "$XCF" -name "module.modulemap" | grep -q .; then
        ok "含 module.modulemap"
    else
        bad "缺少 module.modulemap"
    fi
else
    skip "本机无 build/GemstoneFFI.xcframework"
fi

section "GitHub 远端"
if ! command -v gh >/dev/null 2>&1 || [ -z "${GH_TOKEN:-}" ]; then
    skip "gh 未装或 GH_TOKEN 未设置，跳过远端检查"
else
    # ── Maven 包 ──
    if [ -n "${CORE_REPO:-}" ]; then
        OWNER="${CORE_REPO%%/*}"
        PKG="${MAVEN_GROUP}.${MAVEN_ARTIFACT}"
        FOUND=""
        for scope in "orgs/${OWNER}" "users/${OWNER}"; do
            if gh api "${scope}/packages/maven/${PKG}/versions" --paginate 2>/dev/null \
                 | jq -e --arg v "$VERSION" 'any(.[]; .name == $v)' >/dev/null 2>&1; then
                FOUND="$scope"; break
            fi
        done
        if [ -n "$FOUND" ]; then
            ok "GitHub Packages 有 ${PKG}:${VERSION}"
        else
            bad "GitHub Packages 找不到 ${PKG}:${VERSION}"
            skip "  （若包名不是 ${PKG}，本检查会误报，可手动确认 https://github.com/${CORE_REPO}/packages）"
        fi
    fi

    # ── Release 与资产 ──
    if [ -n "${SWIFT_REPO:-}" ]; then
        if gh release view "$VERSION" --repo "$SWIFT_REPO" >/dev/null 2>&1; then
            ok "Release ${VERSION} 存在"
            if gh release view "$VERSION" --repo "$SWIFT_REPO" --json assets \
                 --jq '.assets[].name' 2>/dev/null | grep -q "GemstoneFFI.xcframework.zip"; then
                ok "Release 资产含 GemstoneFFI.xcframework.zip"
            else
                bad "Release 里没有 GemstoneFFI.xcframework.zip"
            fi
        else
            bad "找不到 Release ${VERSION}"
        fi

        # ── tag 与 Package.swift 一致性 ──
        PKGSWIFT=$(gh api "repos/${SWIFT_REPO}/contents/Package.swift?ref=${VERSION}" \
                     --jq '.content' 2>/dev/null | base64 -d 2>/dev/null)
        if [ -n "$PKGSWIFT" ]; then
            if grep -q "releases/download/${VERSION}/GemstoneFFI" <<<"$PKGSWIFT"; then
                ok "tag ${VERSION} 的 Package.swift URL 指向本版本"
            else
                bad "tag ${VERSION} 的 Package.swift URL 没更新（下游会拉到旧 zip）"
            fi
            if grep -qE 'checksum: "[0-9a-f]{64}"' <<<"$PKGSWIFT"; then
                ok "Package.swift 的 checksum 格式正常"
            else
                bad "Package.swift 的 checksum 缺失或格式异常"
            fi
        else
            skip "读不到 tag ${VERSION} 下的 Package.swift"
        fi

        # ── 🔴 匿名可达性：SPM binaryTarget 不带鉴权头 ──
        ZIP_URL="https://github.com/${SWIFT_REPO}/releases/download/${VERSION}/GemstoneFFI.xcframework.zip"
        if curl -fsSL --max-time 20 -o /dev/null -w '' "$ZIP_URL" 2>/dev/null; then
            ok "zip 匿名可下载（SPM binaryTarget 能拉到）"
        else
            bad "zip 匿名下载失败 —— 下游 SPM 会 404"
            skip "  仓库若是 private，binaryTarget 拉不到。见 脚本发布教程.md §2.4"
        fi
    fi
fi

section "下游消费验证"
if [ "$SKIP_SAMPLES" -eq 1 ]; then
    skip "--skip-samples，跳过示例工程编译"
else
    printf '  [Android] 示例工程拉远端 AAR 编译中...\n'
    if (cd core/gemstone/tests/android/GemTest && ./gradlew --quiet assembleDebug) \
         >/tmp/gem-verify-android.log 2>&1; then
        ok "Android 示例工程编译通过"
    else
        bad "Android 示例工程编译失败（详见 /tmp/gem-verify-android.log）"
        tail -10 /tmp/gem-verify-android.log | sed 's/^/      /'
    fi

    if [ "$(uname)" = "Darwin" ]; then
        printf '  [iOS] 示例工程拉远端 SPM 包编译中...\n'
        if (cd core/gemstone/tests/ios/GemTest && \
            xcodebuild -scheme GemTest \
                -destination "platform=iOS Simulator,name=${SIMULATOR_NAME:-iPhone 17}" \
                build) >/tmp/gem-verify-ios.log 2>&1; then
            ok "iOS 示例工程编译通过"
        else
            bad "iOS 示例工程编译失败（详见 /tmp/gem-verify-ios.log）"
            tail -10 /tmp/gem-verify-ios.log | sed 's/^/      /'
        fi
    else
        skip "非 macOS，跳过 iOS 示例工程"
    fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
    printf '\033[32m✅ 验收通过，可以通知下游升级到 %s\033[0m\n' "$VERSION"
    exit 0
fi
printf '\033[31m❌ 验收失败 —— 不要通知下游升级\033[0m\n'
printf '   排查后可用 ./scripts/rollback.sh %s 撤回\n' "$VERSION"
exit 1
