#!/bin/bash
#
# 撤回一个已发布的 gemstone 版本（GitHub）
#
# 用法: ./scripts/rollback.sh 2.114.10
#
# ⚠️ 只能撤回「还没被下游拉过」的版本。已经有人拉过的话，
#    撤回不能清除他们本地的 Gradle / SPM 缓存，只能发新版本覆盖。
#
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "用法: $0 <version>" >&2; exit 1; }

[ -f scripts/release.env ] || { echo "error: 缺少 scripts/release.env" >&2; exit 1; }
# shellcheck disable=SC1091
source scripts/release.env

: "${GH_TOKEN:?请先 export GH_TOKEN}"
: "${CORE_REPO:?release.env 缺少 CORE_REPO}"
: "${SWIFT_REPO:?release.env 缺少 SWIFT_REPO}"
MAVEN_GROUP="${MAVEN_GROUP:-com.gemwallet.gemstone}"
MAVEN_ARTIFACT="${MAVEN_ARTIFACT:-gemstone}"

command -v gh >/dev/null || { echo "error: 需要 gh CLI（brew install gh）" >&2; exit 1; }
command -v jq >/dev/null || { echo "error: 需要 jq（brew install jq）" >&2; exit 1; }

printf '\033[33m⚠️  将撤回 %s 的所有产物：\033[0m\n' "$VERSION"
printf '    - GitHub Packages 里的 %s.%s\n' "$MAVEN_GROUP" "$MAVEN_ARTIFACT"
printf '    - %s 的 Release %s（含资产）\n' "$SWIFT_REPO" "$VERSION"
printf '    - %s 的 tag %s\n' "$SWIFT_REPO" "$VERSION"
printf '    - 本机 ~/.m2 与 build/ 缓存\n'
echo
read -rp "确认请输入完整版本号: " confirm
[ "$confirm" = "$VERSION" ] || { echo "已取消"; exit 1; }

step() { printf '\n\033[36m==> %s\033[0m\n' "$1"; }
info() { printf '    %s\n' "$1"; }

step "删除 GitHub Packages 的 Maven 版本"
OWNER="${CORE_REPO%%/*}"
PKG="${MAVEN_GROUP}.${MAVEN_ARTIFACT}"
DELETED=0
for scope in "orgs/${OWNER}" "users/${OWNER}"; do
    VER_ID=$(gh api "${scope}/packages/maven/${PKG}/versions" --paginate 2>/dev/null \
               | jq -r --arg v "$VERSION" '.[] | select(.name == $v) | .id' | head -1)
    if [ -n "$VER_ID" ]; then
        if gh api --method DELETE "${scope}/packages/maven/${PKG}/versions/${VER_ID}" >/dev/null 2>&1; then
            info "已删除 ${PKG}:${VERSION}（version id=${VER_ID}）"
            DELETED=1
        else
            info "删除失败 —— token 需要 delete:packages scope"
        fi
        break
    fi
done
[ "$DELETED" -eq 1 ] || info "未找到 ${PKG}:${VERSION}（可能已删除，或包名不同）"

step "删除 Release 与 tag"
if gh release view "$VERSION" --repo "$SWIFT_REPO" >/dev/null 2>&1; then
    # --cleanup-tag 会把关联的 tag 一并删掉
    if gh release delete "$VERSION" --repo "$SWIFT_REPO" --yes --cleanup-tag >/dev/null 2>&1; then
        info "已删除 Release ${VERSION} 及其 tag"
    else
        info "删除 Release 失败（权限不足？）"
    fi
else
    info "Release ${VERSION} 不存在"
fi

# Release 删完后 tag 可能还在（比如 Release 建失败但 tag 已推）
if gh api "repos/${SWIFT_REPO}/git/ref/tags/${VERSION}" >/dev/null 2>&1; then
    if gh api --method DELETE "repos/${SWIFT_REPO}/git/refs/tags/${VERSION}" >/dev/null 2>&1; then
        info "已删除残留 tag ${VERSION}"
    else
        info "删除 tag 失败（权限不足？）"
    fi
fi

step "清理本机缓存"
M2_VER="$HOME/.m2/repository/$(echo "$MAVEN_GROUP" | tr '.' '/')/${MAVEN_ARTIFACT}/${VERSION}"
if [ -d "$M2_VER" ]; then
    rm -rf "$M2_VER"
    info "已删除 ${M2_VER}"
else
    info "本机 ~/.m2 无此版本"
fi
rm -rf "$ROOT_DIR/build/GemstoneFFI.xcframework" "$ROOT_DIR/build/GemstoneFFI.xcframework.zip"
info "已清理 build/ 下的 xcframework 产物"

echo
printf '\033[32m✅ %s 已撤回\033[0m\n' "$VERSION"
printf '\033[33m⚠️  如果下游已经拉过这个版本，撤回不能清除他们本地的缓存。\033[0m\n'
printf '   下游需要执行：\n'
printf '     Android: ./gradlew --refresh-dependencies\n'
printf '     iOS:     File → Packages → Reset Package Caches\n'
