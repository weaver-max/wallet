#!/bin/bash
#
# gemstone 发布环境自检（GitHub）—— 只读，不修改任何东西
#
# 用法: ./scripts/preflight.sh
#
# 退出码: 0 = 全部通过, 1 = 有问题需要修复
#
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

FAIL=0
ok()      { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()     { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=1; }
warn()    { printf '  \033[33m!\033[0m %s\n' "$1"; }
section() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

section "配置"
if [ -f scripts/release.env ]; then
    # shellcheck disable=SC1091
    source scripts/release.env
    ok "scripts/release.env 已加载"
    for var in CORE_REPO SWIFT_REPO SWIFT_REPO_GIT; do
        if [ -n "${!var:-}" ]; then
            ok "${var} = ${!var}"
        else
            bad "${var} 未设置"
        fi
    done
else
    bad "缺少 scripts/release.env（cp scripts/release.env.example scripts/release.env）"
fi

if [ -n "${GH_TOKEN:-}" ]; then
    ok "GH_TOKEN 已设置（长度 ${#GH_TOKEN}）"
else
    bad "GH_TOKEN 未设置（export GH_TOKEN=ghp_xxx，需要 write:packages + repo）"
fi

if [ -n "${GITHUB_ACTOR:-}" ]; then
    ok "GITHUB_ACTOR = ${GITHUB_ACTOR}"
else
    warn "GITHUB_ACTOR 未设置 —— Gradle 发 Maven 要用它当用户名"
    warn "  export GITHUB_ACTOR=你的GitHub用户名"
fi

section "工具链"
for tool in cargo rustup just zip curl git jq gh; do
    if command -v "$tool" >/dev/null 2>&1; then
        ok "$tool"
    else
        bad "${tool} 未安装"
    fi
done

if command -v cargo-ndk >/dev/null 2>&1; then
    ok "cargo-ndk $(cargo ndk --version 2>/dev/null | head -1)"
else
    bad "cargo-ndk 未安装（cargo install cargo-ndk@4.1.2 --locked）"
fi

if [ "$(uname)" = "Darwin" ]; then
    for tool in xcodebuild swift; do
        if command -v "$tool" >/dev/null 2>&1; then
            ok "$tool"
        else
            bad "${tool} 未安装（iOS 发布必需）"
        fi
    done

    # 🔴 只查 command -v 不够：Command Line Tools 里也有 xcodebuild 壳，
    #    但不含 iOS SDK。必须实际解析 SDK 路径才能确认能编 iOS。
    DEV_DIR=$(xcode-select -p 2>/dev/null)
    if [ -z "$DEV_DIR" ]; then
        bad "xcode-select 未配置"
    elif [[ "$DEV_DIR" == *"CommandLineTools"* ]]; then
        bad "当前是 Command Line Tools（${DEV_DIR}），不含 iOS SDK"
        bad "  需安装完整 Xcode，然后："
        bad "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    else
        ok "Xcode 开发目录: ${DEV_DIR}"
    fi

    if SDK_PATH=$(xcrun --show-sdk-path --sdk iphoneos 2>/dev/null) && [ -n "$SDK_PATH" ]; then
        ok "iOS SDK: $(xcrun --show-sdk-version --sdk iphoneos 2>/dev/null)"
    else
        bad "iOS SDK 不可用 —— cc-rs 编译 C 依赖时会失败"
        bad "  验证命令: xcrun --show-sdk-path --sdk iphoneos"
    fi

    if xcrun --show-sdk-path --sdk iphonesimulator >/dev/null 2>&1; then
        ok "iOS Simulator SDK: $(xcrun --show-sdk-version --sdk iphonesimulator 2>/dev/null)"
    else
        bad "iOS Simulator SDK 不可用"
    fi
else
    warn "非 macOS，无法发布 iOS 制品（xcodebuild 只能在 mac 上跑）"
fi

section "Rust targets"
INSTALLED=$(rustup target list --installed 2>/dev/null)
for t in aarch64-linux-android armv7-linux-androideabi x86_64-linux-android; do
    if grep -qx "$t" <<<"$INSTALLED"; then ok "$t"; else bad "${t} 缺失（rustup target add ${t}）"; fi
done
if [ "$(uname)" = "Darwin" ]; then
    for t in aarch64-apple-ios aarch64-apple-ios-sim; do
        if grep -qx "$t" <<<"$INSTALLED"; then ok "$t"; else bad "${t} 缺失（rustup target add ${t}）"; fi
    done
fi

section "Android SDK / NDK"
if [ -n "${ANDROID_HOME:-}" ] && [ -d "${ANDROID_HOME:-}" ]; then
    ok "ANDROID_HOME = $ANDROID_HOME"
    if [ -d "$ANDROID_HOME/ndk" ] && [ -n "$(ls -A "$ANDROID_HOME/ndk" 2>/dev/null)" ]; then
        ok "NDK: $(ls "$ANDROID_HOME/ndk" | tr '\n' ' ')"
    else
        bad "未安装 NDK（sdkmanager --install \"ndk;28.1.13356709\"）"
    fi
else
    bad "ANDROID_HOME 未设置或目录不存在"
fi

section "仓库前置改动"
if grep -q "generate_module_map = true" core/gemstone/uniffi.toml 2>/dev/null; then
    ok "uniffi.toml: generate_module_map = true"
else
    bad "uniffi.toml 仍是 generate_module_map = false（见 脚本发布教程.md 附录 A.1）"
fi

GRADLE_FILE="core/gemstone/android/gemstone/build.gradle.kts"
if grep -q "maven.pkg.github.com" "$GRADLE_FILE" 2>/dev/null; then
    ok "build.gradle.kts 已配 GitHub Packages"
elif grep -q "repositories" "$GRADLE_FILE" 2>/dev/null; then
    warn "build.gradle.kts 有 repositories 但不是 GitHub Packages —— 确认 URL"
else
    bad "build.gradle.kts 缺少 repositories 块（见 脚本发布教程.md 附录 A.2）"
fi

if [ -x scripts/package-xcframework.sh ]; then
    ok "package-xcframework.sh 可执行"
else
    bad "package-xcframework.sh 不存在或无执行权限（chmod +x）"
fi

section "工作区状态"
if [ -z "$(git status --porcelain 2>/dev/null)" ]; then
    ok "工作区干净"
else
    warn "工作区有未提交改动 —— 产物将无法追溯到确切 commit"
    git status --short | head -5 | sed 's/^/      /'
fi
ok "当前 commit: $(git rev-parse --short HEAD 2>/dev/null || echo '(非 git 仓库)')"
ok "core 版本: $(grep -m1 '^version' core/Cargo.toml | cut -d'"' -f2)"

section "GitHub 连通与权限"
if ! command -v gh >/dev/null 2>&1; then
    warn "gh 未安装，跳过 GitHub 检查（brew install gh）"
elif [ -z "${GH_TOKEN:-}" ]; then
    warn "GH_TOKEN 未设置，跳过 GitHub 检查"
else
    LOGIN=$(gh api user --jq .login 2>/dev/null)
    if [ -n "$LOGIN" ]; then
        ok "GitHub API 可达，登录为 ${LOGIN}"
    else
        bad "GitHub API 不可达或 GH_TOKEN 无效"
    fi

    if [ -n "${CORE_REPO:-}" ]; then
        if gh api "repos/${CORE_REPO}" --jq .full_name >/dev/null 2>&1; then
            ok "可访问 ${CORE_REPO}"
        else
            bad "无法访问 ${CORE_REPO}（仓库不存在或 token 权限不足）"
        fi
    fi

    if [ -n "${SWIFT_REPO:-}" ]; then
        REPO_JSON=$(gh api "repos/${SWIFT_REPO}" 2>/dev/null)
        if [ -n "$REPO_JSON" ]; then
            VIS=$(jq -r '.visibility // "unknown"' <<<"$REPO_JSON")
            PUSH=$(jq -r '.permissions.push // false' <<<"$REPO_JSON")
            ok "可访问 ${SWIFT_REPO}（visibility=${VIS}）"

            if [ "$PUSH" = "true" ]; then
                ok "对 ${SWIFT_REPO} 有推送权限"
            else
                bad "对 ${SWIFT_REPO} 无推送权限（token 需要 repo scope）"
            fi

            # 🔴 SPM binaryTarget 下载不带鉴权头，私有仓库的 Release 资产下游拉不到
            if [ "$VIS" != "public" ]; then
                warn "${SWIFT_REPO} 不是 public"
                warn "  SPM 的 binaryTarget 下载 zip 时不带鉴权头，下游会 404。"
                warn "  见 脚本发布教程.md §2.4 的三条出路"
            else
                ok "visibility=public，SPM binaryTarget 可直接下载"
            fi
        else
            bad "无法访问 ${SWIFT_REPO}（仓库不存在或 token 权限不足）"
        fi
    fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
    printf '\033[32m✅ 环境检查通过\033[0m\n'
    exit 0
fi
printf '\033[31m❌ 有问题需要先修复\033[0m\n'
exit 1
