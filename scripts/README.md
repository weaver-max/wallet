# scripts/

## 发布脚本（GitHub）

gemstone 制品（Android AAR + iOS XCFramework）的手动发布工具链。

**完整教程见仓库根目录的 [脚本发布教程.md](../脚本发布教程.md)。第一次使用务必按教程 §3 分步执行，不要直接跑 `release.sh`。**

| 脚本 | 作用 | 何时用 |
|---|---|---|
| `preflight.sh` | 环境自检（只读） | ⭐ 每次发版前 |
| `package-xcframework.sh` | 打包 iOS XCFramework，输出 checksum | 被 `release.sh` 调用 |
| `release.sh` | 主发布脚本 | 发版 |
| `verify-release.sh` | 验收：下游能否真正拉到 | ⭐ 每次发版后 |
| `rollback.sh` | 撤回一个版本 | 发错时 |
| `release.env.example` | 配置模板 | 首次配置 |

### 快速开始

```bash
# 一次性配置
cp scripts/release.env.example scripts/release.env
vim scripts/release.env                      # 填 CORE_REPO / SWIFT_REPO

# 写进 ~/.zshrc
export GH_TOKEN="ghp_xxxxxxxxxxxx"           # 需要 write:packages + repo
export GITHUB_ACTOR="你的GitHub用户名"        # Gradle 发 Maven 要用它当用户名

# 每次发版
./scripts/preflight.sh                       # 自检，全绿再往下
./scripts/release.sh 2.114.10 --dry-run      # 空跑看命令对不对
./scripts/release.sh 2.114.10                # 真发
./scripts/verify-release.sh 2.114.10         # 验收 —— 不过不算发布成功
```

### 常用选项

```bash
./scripts/release.sh 2.114.10 --android-only          # 只发 Android
./scripts/release.sh 2.114.10 --ios-only              # 只发 iOS（需要 macOS）
./scripts/verify-release.sh 2.114.10 --skip-samples   # 快检，跳过示例工程编译
./scripts/rollback.sh 2.114.10                        # 撤回
```

### 发布到哪

| 制品 | 落点 |
|---|---|
| Android AAR | `CORE_REPO` 的 GitHub Packages（Maven） |
| iOS xcframework.zip | `SWIFT_REPO` 的 GitHub Release 资产 |
| `Gemstone.swift` + `Package.swift` | `SWIFT_REPO` 仓库源码，按 tag 取版本 |

### 前置条件

1. **工具链**：Rust + 5 个 target、cargo-ndk@4.1.2、NDK 28.1.13356709、just、jq、gh、Xcode（iOS）
2. **仓库改动**：`uniffi.toml` 要开 `generate_module_map`，`build.gradle.kts` 要加 GitHub Packages repositories —— 见教程附录 A
3. **GitHub token**：classic PAT，`write:packages` + `repo`（撤回还需要 `delete:packages`）

`preflight.sh` 会逐项检查上述条件，缺什么会明确告诉你。

### 🔴 一个硬限制

**`SWIFT_REPO` 建议设为 public。** SPM 的 `binaryTarget` 下载 zip 时**不带鉴权头**，私有仓库的 Release 资产下游会 404。`preflight.sh` 会检查这一项并给出警告，三条出路见教程 §2.4。

---

## 其他脚本

| 脚本 | 作用 |
|---|---|
| `bump.sh` | 版本号递增（iOS pbxproj + Android gradle + core Cargo.toml），通过 `just bump` 调用 |
