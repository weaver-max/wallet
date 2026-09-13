#!/bin/bash
#
# gemstone 双端发布（Android AAR + iOS XCFramework）—— GitHub
#
# 用法:
#   ./scripts/release.sh 2.114.10
#   ./scripts/release.sh 2.114.10 --dry-run
#   ./scripts/release.sh 2.114.10 --android-only
#   ./scripts/release.sh 2.114.10 --ios-only
#
# 前置: ./scripts/preflight.sh 通过
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

# ───────── 参数 ─────────
VERSION=""
DRY_RUN=0
DO_ANDROID=1
DO_IOS=1

usage() {
    cat >&2 <<'EOF'
用法: ./scripts/release.sh <version> [选项]

选项:
  --dry-run         只打印命令，不实际执行
  --android-only    只发 Android
  --ios-only        只发 iOS（需要 macOS）
  -h, --help        显示本帮助

示例:
  ./scripts/release.sh 2.114.10 --dry-run
  ./scripts/release.sh 2.114.10 --android-only
EOF
    exit 1
}

for arg in "$@"; do
    case "$arg" in
        --dry-run)      DRY_RUN=1 ;;
        --android-only) DO_IOS=0 ;;
        --ios-only)     DO_ANDROID=0 ;;
        -h|--help)      usage ;;
        -*)             echo "未知参数: $arg" >&2; usage ;;
        *)              VERSION="$arg" ;;
    esac
done
[ -n "$VERSION" ] || usage

# ───────── 配置 ─────────
[ -f scripts/release.env ] \
    || { echo "error: 缺少 scripts/release.env（cp scripts/release.env.example scripts/release.env）" >&2; exit 1; }
# shellcheck disable=SC1091
source scripts/release.env

: "${GH_TOKEN:?请先 export GH_TOKEN=ghp_xxx（需要 write:packages + repo）}"
: "${CORE_REPO:?release.env 缺少 CORE_REPO}"
: "${SWIFT_REPO:?release.env 缺少 SWIFT_REPO}"
: "${SWIFT_REPO_GIT:?release.env 缺少 SWIFT_REPO_GIT}"
MAVEN_GROUP="${MAVEN_GROUP:-com.gemwallet.gemstone}"
MAVEN_ARTIFACT="${MAVEN_ARTIFACT:-gemstone}"

command -v gh >/dev/null || { echo "error: 需要 gh CLI（brew install gh）" >&2; exit 1; }

CORE_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

STEP=0
TOTAL=$(( DO_ANDROID * 2 + DO_IOS * 4 ))
step() { STEP=$((STEP+1)); printf '\n\033[36m==> [%d/%d] %s\033[0m\n' "$STEP" "$TOTAL" "$1"; }
info() { printf '    %s\n' "$1"; }
run()  {
    if [ "$DRY_RUN" -eq 1 ]; then
        # 打印前把 token 打码，避免 dry-run 日志泄漏凭据
        printf '    \033[33m[dry-run]\033[0m %s\n' "${*//$GH_TOKEN/***REDACTED***}"
    else
        eval "$@"
    fi
}

printf '\033[1m版本:\033[0m   %s\n' "$VERSION"
printf '\033[1mcommit:\033[0m %s\n' "$CORE_SHA"
printf '\033[1m范围:\033[0m   %s\n' \
    "$( [ "$DO_ANDROID" -eq 1 ] && printf 'Android '; [ "$DO_IOS" -eq 1 ] && printf 'iOS' )"
[ "$DRY_RUN" -eq 1 ] && printf '\033[33m*** DRY RUN —— 不会实际发布 ***\033[0m\n'

# ───────── 工作区检查 ─────────
if [ "$DRY_RUN" -eq 0 ] && [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    printf '\033[33m警告: 工作区有未提交改动，产物将无法追溯到确切 commit\033[0m\n'
    git status --short | head -5 | sed 's/^/      /'
    read -rp "继续？[y/N] " answer
    [ "$answer" = "y" ] || { echo "已取消"; exit 1; }
fi

# ═══════════════ Android ═══════════════
if [ "$DO_ANDROID" -eq 1 ]; then
    step "生成 Kotlin 绑定"
    run "(cd core/gemstone && just bindgen-kotlin)"

    step "发布 AAR 到 GitHub Packages"
    run "(cd core/gemstone/android && touch local.properties && \
          BUILD_MODE=release VER_NAME='$VERSION' \
          GITHUB_ACTOR='${GITHUB_ACTOR:-}' GITHUB_TOKEN='$GH_TOKEN' \
          ./gradlew publishReleasePublicationToGitHubPackagesRepository)"
    info "${MAVEN_GROUP}:${MAVEN_ARTIFACT}:${VERSION}"
    info "https://github.com/${CORE_REPO}/packages"
fi

# ═══════════════ iOS ═══════════════
if [ "$DO_IOS" -eq 1 ]; then
    if [ "$(uname)" != "Darwin" ] && [ "$DRY_RUN" -eq 0 ]; then
        echo "error: iOS 发布需要 macOS" >&2
        exit 1
    fi

    step "生成 Swift 绑定 + 编译静态库（真机 + 模拟器）"
    run "(cd ios && BUILD_MODE=release \
          GEMSTONE_IOS_TARGETS='aarch64-apple-ios aarch64-apple-ios-sim' \
          just generate-stone)"

    step "打包 XCFramework"
    if [ "$DRY_RUN" -eq 1 ]; then
        CHECKSUM="dry-run-checksum-placeholder"
        printf '    \033[33m[dry-run]\033[0m bash scripts/package-xcframework.sh\n'
    else
        CHECKSUM=$(bash scripts/package-xcframework.sh | tail -1)
        [ -n "$CHECKSUM" ] || { echo "error: 未取到 checksum" >&2; exit 1; }
    fi
    info "checksum = $CHECKSUM"

    # ⚠️ 顺序很重要：先更新 Package.swift 并打 tag，再建 Release。
    #    反过来的话 gh release create 会在旧 commit 上建 tag，之后还得强推覆盖。
    #    zip 的 URL 是确定性的，即使 Release 还没建也能先写进 Package.swift。
    ZIP_URL="https://github.com/${SWIFT_REPO}/releases/download/${VERSION}/GemstoneFFI.xcframework.zip"

    step "更新 Package.swift 并打 tag"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '    \033[33m[dry-run]\033[0m clone %s，更新 Package.swift，打 tag %s\n' "$SWIFT_REPO_GIT" "$VERSION"
    else
        # tag 已存在就停，避免覆盖已发布版本
        if gh api "repos/${SWIFT_REPO}/git/ref/tags/${VERSION}" >/dev/null 2>&1; then
            echo "error: ${SWIFT_REPO} 已有 tag ${VERSION}" >&2
            echo "       先跑 ./scripts/rollback.sh ${VERSION}，或换一个版本号" >&2
            exit 1
        fi

        TMP=$(mktemp -d)
        # shellcheck disable=SC2064
        trap "rm -rf '$TMP'" EXIT

        git clone --quiet --depth 1 "$SWIFT_REPO_GIT" "$TMP"
        [ -f "$TMP/Package.swift" ] || { echo "error: ${SWIFT_REPO} 里没有 Package.swift" >&2; exit 1; }

        mkdir -p "$TMP/Sources/Gemstone"
        cp core/gemstone/generated/swift/gemstone.swift "$TMP/Sources/Gemstone/Gemstone.swift"

        # macOS 的 sed 需要 -i ''，GNU sed 用 -i
        if [ "$(uname)" = "Darwin" ]; then
            sed -i '' -E \
                -e "s|releases/download/[^/]+/GemstoneFFI|releases/download/${VERSION}/GemstoneFFI|" \
                -e "s|^([[:space:]]*)checksum: \".*\"|\1checksum: \"${CHECKSUM}\"|" \
                "$TMP/Package.swift"
        else
            sed -i -E \
                -e "s|releases/download/[^/]+/GemstoneFFI|releases/download/${VERSION}/GemstoneFFI|" \
                -e "s|^([[:space:]]*)checksum: \".*\"|\1checksum: \"${CHECKSUM}\"|" \
                "$TMP/Package.swift"
        fi

        # 确认替换真的生效，避免推一个坏包上去
        grep -q "$CHECKSUM" "$TMP/Package.swift" \
            || { echo "error: Package.swift 的 checksum 替换失败，检查文件格式" >&2; exit 1; }
        grep -q "releases/download/${VERSION}/GemstoneFFI" "$TMP/Package.swift" \
            || { echo "error: Package.swift 的 URL 替换失败，检查文件格式" >&2; exit 1; }

        (
            cd "$TMP"
            git add -A
            git commit --quiet -m "Release $VERSION (core@$CORE_SHA)"
            git tag "$VERSION"
            git push --quiet origin HEAD --tags
        )
        info "已推送 tag $VERSION"
    fi

    step "建 Release 并上传 zip 到 ${SWIFT_REPO}"
    # tag 上一步已推好，这里 gh 会复用它而不是新建
    run "gh release create '$VERSION' build/GemstoneFFI.xcframework.zip \
          --repo '$SWIFT_REPO' \
          --title '$VERSION' \
          --notes 'Gemstone $VERSION (core@$CORE_SHA)'"
    info "$ZIP_URL"
fi

echo
if [ "$DRY_RUN" -eq 1 ]; then
    printf '\033[33m✓ dry-run 完成，没有实际发布\033[0m\n'
else
    printf '\033[32m✅ %s 发布完成 (core@%s)\033[0m\n' "$VERSION" "$CORE_SHA"
    printf '下一步: ./scripts/verify-release.sh %s\n' "$VERSION"
fi
