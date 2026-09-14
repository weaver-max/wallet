#!/bin/bash
#
# gemstone 发布验收（GitHub）
#
# 「发布成功」的定义不是「脚本跑完没报错」，是「下游能拉下来跑起来」。
#
# 用法: ./scripts/verify-release.sh 2.114.10
#       ./scripts/verify-release.sh 2.114.10 --skip-samples    (只做快检，不编示例工程)
#       ./scripts/verify-release.sh 2.114.10 --ios-only        (只验 iOS，与 release.sh 对齐)
#       ./scripts/verify-release.sh 2.114.10 --android-only    (只验 Android)
#
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

VERSION=""
SKIP_SAMPLES=0
# 与 release.sh 的 --android-only / --ios-only 对齐：
# 只发了一端时，不该去验另一端（否则必然误报失败）
CHECK_ANDROID=1
CHECK_IOS=1
for arg in "$@"; do
    case "$arg" in
        --skip-samples) SKIP_SAMPLES=1 ;;
        --android-only) CHECK_IOS=0 ;;
        --ios-only)     CHECK_ANDROID=0 ;;
        -*)             echo "未知参数: $arg" >&2
                        echo "用法: $0 <version> [--skip-samples] [--android-only|--ios-only]" >&2
                        exit 1 ;;
        *)              VERSION="$arg" ;;
    esac
done
[ -n "$VERSION" ] \
    || { echo "用法: $0 <version> [--skip-samples] [--android-only|--ios-only]" >&2; exit 1; }

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

if [ "$CHECK_ANDROID" -eq 1 ]; then
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
fi

if [ "$CHECK_IOS" -eq 1 ]; then
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
fi

section "GitHub 远端"
if ! command -v gh >/dev/null 2>&1 || [ -z "${GH_TOKEN:-}" ]; then
    skip "gh 未装或 GH_TOKEN 未设置，跳过远端检查"
else
    # ── Maven 包 ──
    if [ "$CHECK_ANDROID" -eq 1 ] && [ -n "${CORE_REPO:-}" ]; then
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
    if [ "$CHECK_IOS" -eq 1 ] && [ -n "${SWIFT_REPO:-}" ]; then
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
        # 只取前 1KB 验证可达即可，不必拉完整 19MB：
        # 实测同一文件耗时在 8s~44s 间波动，固定超时会误判；
        # 且偶发 SSL_ERROR_SYSCALL，需要重试才稳。
        ZIP_URL="https://github.com/${SWIFT_REPO}/releases/download/${VERSION}/GemstoneFFI.xcframework.zip"
        ANON_OK=0
        for attempt in 1 2 3; do
            HTTP=$(curl -sSL --max-time 30 --retry 0 \
                     -H "Range: bytes=0-1023" \
                     -o /dev/null -w '%{http_code}' "$ZIP_URL" 2>/dev/null)
            # 206 = Range 生效；200 = 服务端忽略 Range 但可达
            if [ "$HTTP" = "206" ] || [ "$HTTP" = "200" ]; then
                ANON_OK=1; break
            fi
            [ "$attempt" -lt 3 ] && sleep 2
        done
        if [ "$ANON_OK" -eq 1 ]; then
            ok "zip 匿名可达（SPM binaryTarget 能拉到）"
        else
            bad "zip 匿名下载失败（3 次重试后 HTTP ${HTTP:-000}）"
            skip "  HTTP 404 → 仓库是 private，binaryTarget 拉不到，见 脚本发布教程.md §2.4"
            skip "  HTTP 000 → 网络问题，手动重试: curl -I '$ZIP_URL'"
        fi
    fi
fi

section "下游消费验证"
if [ "$SKIP_SAMPLES" -eq 1 ]; then
    skip "--skip-samples，跳过下游真实拉取"
else
    # ── 🔴 SPM 真实解析 ──────────────────────────────────────────
    # 前面所有检查（curl 下载、API 查 Release/tag、读 Package.swift）
    # 都在「文件是否存在、内容是否正确」层面，碰不到 SPM 自己的解析器。
    # 实测教训：仓库里有非 ASCII 文件名时，git 会对其做八进制转义并加引号，
    # SPM 的 git tree 解析器直接报 malformedResponse —— 整个包无法被依赖，
    # 但上述检查全部绿灯。这一步是唯一能发现该类问题的关卡。
    if [ "$CHECK_IOS" -eq 1 ] && [ -n "${SWIFT_REPO:-}" ] && command -v swift >/dev/null 2>&1; then
        printf '  [iOS] SPM 真实解析中（会下载 zip 并校验 checksum）...\n'
        SPM_TMP=$(mktemp -d)
        mkdir -p "$SPM_TMP/Sources/Probe"
        cat > "$SPM_TMP/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Probe",
    platforms: [.iOS(.v17)],
    products: [.library(name: "Probe", targets: ["Probe"])],
    dependencies: [
        .package(url: "https://github.com/${SWIFT_REPO}.git", exact: "${VERSION}")
    ],
    targets: [
        .target(name: "Probe", dependencies: [
            .product(name: "Gemstone", package: "$(basename "$SWIFT_REPO")")
        ])
    ]
)
EOF
        echo 'import Gemstone
public enum Probe { public static func v() -> String { libVersion() } }' \
            > "$SPM_TMP/Sources/Probe/Probe.swift"

        if (cd "$SPM_TMP" && timeout 300 swift package resolve) >/tmp/gem-verify-spm.log 2>&1; then
            ok "SPM 解析通过（清单可读、zip 可下、checksum 匹配）"

            # 解析只验证「拿得到」，编译才验证「用得了」：
            # module.modulemap 是否被识别、切片是否选对、符号是否能链接。
            if xcodebuild -showsdks 2>/dev/null | grep -q iphonesimulator; then
                printf '  [iOS] 编译链接中...\n'
                if (cd "$SPM_TMP" && timeout 600 xcodebuild -scheme Probe \
                        -destination 'generic/platform=iOS Simulator' \
                        -derivedDataPath "$SPM_TMP/dd" build) >/tmp/gem-verify-ios.log 2>&1; then
                    ok "iOS 编译链接通过（modulemap 可识别、符号可解析）"
                else
                    bad "iOS 编译失败（详见 /tmp/gem-verify-ios.log）"
                    grep -E "error:|\*\* BUILD" /tmp/gem-verify-ios.log | head -5 | sed 's/^/      /'
                fi
            else
                skip "无 iOS Simulator SDK，跳过编译验证"
                skip "  安装: xcodebuild -downloadPlatform iOS"
            fi
        else
            bad "SPM 解析失败（详见 /tmp/gem-verify-spm.log）"
            grep -E "error:|malformedResponse|checksum" /tmp/gem-verify-spm.log | head -3 | sed 's/^/      /'
            # 非 ASCII 文件名是最常见的原因，直接点出来
            if grep -q "malformedResponse" /tmp/gem-verify-spm.log; then
                bad "  疑似仓库含非 ASCII 文件名 —— SPM 的 git tree 解析器不支持"
                bad "  检查: git ls-tree HEAD | grep '\"'"
            fi
        fi
        rm -rf "$SPM_TMP"
    fi

    if [ "$CHECK_ANDROID" -eq 1 ]; then
    printf '  [Android] 示例工程拉远端 AAR 编译中...\n'
    # -PgemstoneVersion 让示例工程拉本次发布的版本，而不是它自己算出来的默认值
    # 🔴 GITHUB_ACTOR / GITHUB_TOKEN 必须传：
    #    GitHub Packages 的 Maven registry 即使对 public 仓库也要求鉴权，
    #    不传会拿到 401 Unauthorized（不是 404，容易误判成包不存在）。
    #    示例工程的 settings.gradle 读的是 GITHUB_TOKEN，而本脚本用 GH_TOKEN，需转换。
    if (cd core/gemstone/tests/android/GemTest && \
        GITHUB_PACKAGES_REPO="${CORE_REPO:-}" \
        GITHUB_ACTOR="${GITHUB_ACTOR:-}" \
        GITHUB_TOKEN="${GH_TOKEN:-}" \
        ./gradlew --quiet -PgemstoneVersion="$VERSION" assembleDebug) \
         >/tmp/gem-verify-android.log 2>&1; then
        ok "Android 示例工程编译通过"
    else
        bad "Android 示例工程编译失败（详见 /tmp/gem-verify-android.log）"
        tail -10 /tmp/gem-verify-android.log | sed 's/^/      /'
    fi
    fi

    # 注：core/gemstone/tests/ios/GemTest 用的是本地路径依赖
    # （Packages/Gemstone，靠 prepare-ios-package 本地生成），
    # 不拉远端包，因此不能用它验收发布产物。上面的 Probe 包才是真实下游路径。
fi

echo
if [ "$FAIL" -eq 0 ]; then
    printf '\033[32m✅ 验收通过，可以通知下游升级到 %s\033[0m\n' "$VERSION"
    exit 0
fi
printf '\033[31m❌ 验收失败 —— 不要通知下游升级\033[0m\n'
printf '   排查后可用 ./scripts/rollback.sh %s 撤回\n' "$VERSION"
exit 1
