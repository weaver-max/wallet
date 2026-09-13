# GitLab 发布方案

> 面向：用 GitLab（自建或 gitlab.com）分发 gemstone 编译产物的 core 团队
> 目标：Android AAR + iOS XCFramework 发到 GitLab，下游一行依赖即可消费
> 相关：[gem开发core团队应该给ios和安卓提供什么.md](gem开发core团队应该给ios和安卓提供什么.md)（GitHub 版本 + 通用背景）

---

## ⚠️ 关于本文的可信度

- **仓库现状**（`build.gradle.kts` 现有配置、justfile、uniffi.toml 等）已对照 commit `820c415579` 源码核实
- **GitLab 平台细节**（API URL 格式、token 类型、Package Registry 行为）来自既有知识，**不是查阅官方文档得来**

落地前请对照你们 GitLab 版本的文档核一遍 URL 格式和 token scope 名称，尤其是自建实例版本较老的情况。

---

## 目录

1. [结论：GitLab 完全可以，两处更好](#1-结论gitlab-完全可以两处更好)
2. [项目规划](#2-项目规划)
3. [Token 体系](#3-token-体系)
4. [Android AAR](#4-android-aar)
5. [iOS XCFramework](#5-ios-xcframework)
6. [⚠️ SPM 私有仓库的硬限制](#6--spm-私有仓库的硬限制)
7. [手动发布方案（推荐先做这个）](#7-手动发布方案推荐先做这个)
8. [GitLab CI 方案](#8-gitlab-ci-方案)
9. [下游消费方配置](#9-下游消费方配置)
10. [验收](#10-验收)
11. [检查清单](#11-检查清单)

---

## 1. 结论：GitLab 完全可以，两处更好

| 需求 | GitHub | GitLab |
|---|---|---|
| Maven registry（放 AAR） | GitHub Packages | ✅ 内置 Package Registry |
| 放任意二进制（xcframework.zip） | Release 附件 | ✅ Generic Package Registry |
| Git 仓库（放 SPM 包） | ✅ | ✅ |
| CI | Actions | ✅ GitLab CI |
| **跨项目写入凭据** | 要单独建 fine-grained PAT | ⭐ **组级 Deploy Token，天然跨项目** |
| **私有化部署** | ❌ 只能用云 | ⭐ **可自建，全内网** |

### GitLab 的两个实质优势

**① 组级 Token 和组级 registry**

下游配一次组级 URL 就能拉整个 group 下所有项目的包，不用每加一个包改一次配置。GitHub Packages 是仓库级的，加包就要改配置。

**② 自建实例可以全内网**

对钱包这类项目，编译产物不出内网是实打实的价值。GitHub 只能用云。

### 唯一不变的限制

> 🔴 **SPM `binaryTarget` 的鉴权问题换平台不解决**，见 [§6](#6--spm-私有仓库的硬限制)。

---

## 2. 项目规划

| 项目 | 新建？ | 作用 | 可见性建议 |
|---|:---:|---|---|
| `your-group/core` | 用现有的 | Rust 源码 + **AAR 发到它的 Package Registry** | private |
| `your-group/gemstone-ios-artifacts` | 🆕 可选 | 专门放 xcframework.zip 的 Generic Package Registry | private |
| **`your-group/gemstone-swift`** | 🆕 **必须** | iOS SPM 包（`Package.swift` + `Gemstone.swift`） | ⚠️ **建议 internal**，见 §6 |
| `your-group/wallet-android` | 你的 App | 消费方 | private |
| `your-group/wallet-ios` | 你的 App | 消费方 | private |

### 为什么 iOS 必须单独建 `gemstone-swift`

Swift Package Manager 两条硬规矩：

1. **`Package.swift` 必须在仓库根目录** —— 不支持子目录里的包
2. **版本号 = git tag** —— 没有独立 registry，靠 tag 取版本

`core` 是 monorepo，根目录放 `Package.swift` 别扭，tag 还会和 core 自己的版本 tag 打架。

Android 没这问题——Package Registry 是真正的 Maven registry，和仓库源码无关。

### `gemstone-ios-artifacts` 要不要单独建

不是必须。xcframework.zip 可以直接放 `core` 项目的 Generic Package Registry。**单独建的好处是权限隔离**——下游只需要这一个项目的读权限，看不到 core 源码。

---

## 3. Token 体系

GitLab 有三种 token，**用错 header 名会 401**，这是最容易踩的坑。

| 场景 | Token 类型 | HTTP Header 名 | 从哪来 |
|---|---|---|---|
| GitLab CI 内 | Job Token | `Job-Token` | `$CI_JOB_TOKEN` 自动注入 |
| 本机手动发布 | Personal Access Token | `Private-Token` | 用户 → Settings → Access Tokens |
| 部署机 / 机器人 | Deploy Token | `Deploy-Token` | 项目/组 → Settings → Repository → Deploy tokens |

### 需要的 scope

| 用途 | scope |
|---|---|
| 发 AAR / 上传 generic 包 | `api` 或 `write_package_registry` |
| 下游拉包 | `read_package_registry` |
| CI 推文件到 `gemstone-swift` | `write_repository`（Deploy Token）或 `api`（PAT） |

### 推荐配置

```
组级 Deploy Token「gemstone-publisher」  → write_package_registry + write_repository
组级 Deploy Token「gemstone-consumer」   → read_package_registry
```

组级的好处：一个 token 覆盖 `core` / `gemstone-ios-artifacts` / `gemstone-swift` 三个项目，不用配三份。

---

## 4. Android AAR

### 4.1 关键差异：GitLab 用 HTTP Header 认证

GitHub 用 `credentials { username / password }`，**GitLab 必须用 `HttpHeaderCredentials`**。这是移植时最容易错的地方。

### 4.2 改 `core/gemstone/android/gemstone/build.gradle.kts`

现有的 `publishing` 块只有 `publications`，没有 `repositories`，所以只能推 mavenLocal。补两处：

```kotlin
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.gradle.api.credentials.HttpHeaderCredentials              // ← 新增 import
import org.gradle.authentication.http.HttpHeaderAuthentication       // ← 新增 import

plugins {
    id("com.android.library")
    id("maven-publish")
}

val gemstoneRoot = project.projectDir.resolve("../..")
// ... 其余不变 ...

// ↓↓↓ 新增：版本号从 Cargo.toml 读，和 core 对齐 ↓↓↓
val coreVersion: String by lazy {
    System.getenv("VER_NAME")
        ?: gemstoneRoot.resolve("../Cargo.toml").readLines()
            .first { it.trimStart().startsWith("version") }
            .substringAfter('"').substringBefore('"')
}

afterEvaluate {
    publishing {
        publications {
            create<MavenPublication>("release") {
                from(components["release"])
                groupId = "com.gemwallet.gemstone"
                artifactId = "gemstone"
                version = coreVersion                      // ← 改：原为 getenv ?: "1.0.0"
            }
            create<MavenPublication>("debug") {
                from(components["debug"])
                groupId = "com.gemwallet.gemstone"
                artifactId = "gemstone-debug"
                version = "$coreVersion-debug"             // ← 改
            }
        }

        // ↓↓↓ 新增整块 ↓↓↓
        repositories {
            maven {
                name = "GitLab"
                url = uri("https://gitlab.your-company.com/api/v4/projects/<PROJECT_ID>/packages/maven")

                credentials(HttpHeaderCredentials::class) {
                    // CI 里用 Job-Token，本机用 Private-Token
                    name = if (System.getenv("CI_JOB_TOKEN") != null) "Job-Token" else "Private-Token"
                    value = System.getenv("CI_JOB_TOKEN")
                        ?: providers.gradleProperty("gitlab.token").orNull
                }
                authentication {
                    create<HttpHeaderAuthentication>("header")       // ← 不能漏，漏了会走 basic auth 然后 401
                }
            }
        }
    }
}
```

> `<PROJECT_ID>` 在项目 **Settings → General** 页面顶部能看到，是个数字。也可以用 URL 编码的路径，但数字 ID 更稳（改名不影响）。

### 4.3 加 justfile recipe

```just
# 本地开发用，保持不变
build-android: bindgen-kotlin
    #!/usr/bin/env bash
    rm -rf ~/.m2/repository/com/gemwallet/gemstone/gemstone
    cd android && touch local.properties && ./gradlew publishDebugPublicationToMavenLocal

# 新增：发到 GitLab
publish-android: bindgen-kotlin
    #!/usr/bin/env bash
    set -euo pipefail
    cd android && touch local.properties
    BUILD_MODE=release ./gradlew publishReleasePublicationToGitLabRepository
```

> 🔴 **`BUILD_MODE=release` 不能漏** —— 漏了发出去的是 debug 优化等级的 `.so`，体积大、性能差。

### 4.4 本机凭据

`~/.gradle/gradle.properties`（**用户级，不要提交**）：

```properties
gitlab.token=glpat-xxxxxxxxxxxx
```

### 4.5 现状确认（好消息）

`core/gemstone/android/gemstone/build.gradle.kts` 里**这些已经配好了，不用动**：

| 项 | 现状 |
|---|---|
| `maven-publish` 插件 | ✅ |
| 两个 publication（`gemstone` / `gemstone-debug`） | ✅ |
| sources jar + javadoc jar | ✅ `withSourcesJar()` / `withJavadocJar()` |
| **ABI 三个全**（含 x86_64） | ✅ 硬编码在 `buildCargoNdk` 里 |
| JNA 传递依赖 | ✅ `api("net.java.dev.jna:jna:5.18.1@aar")` |
| Rust 自动编译挂钩 | ✅ |

> ⭐ `withSourcesJar()` 意味着生成的 `gemstone.kt` 会自动进 sources jar，下游在 Android Studio 能直接跳转看源码。

> ⚠️ **别改错工程**：
> - `core/gemstone/android/` —— **独立发布工程**，ABI 硬编码三个 ← **改这个**
> - `android/gemstone/` —— 主 App 壳模块，ABI 走环境变量

---

## 5. iOS XCFramework

### 5.1 第 1 步：开启 modulemap

```toml
# core/gemstone/uniffi.toml
[bindings.swift]
ffi_module_name = "GemstoneFFI"
generate_module_map = true          # ← 现在是 false，必须改
experimental_sendable_value_types = true
omit_localized_error_conformance = true
```

monorepo 里靠 SPM 的 `publicHeadersPath` 绕过去了；`binaryTarget` 要求 xcframework 自带 headers + modulemap。

### 5.2 第 2 步：打包脚本

新建 `core/gemstone/scripts/package-xcframework.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
STONE="$REPO_ROOT/core/gemstone"
OUT="$REPO_ROOT/build/GemstoneFFI.xcframework"
HEADERS="$REPO_ROOT/build/include"

rm -rf "$OUT" "$OUT.zip" "$HEADERS"
mkdir -p "$HEADERS"

cp "$STONE/generated/swift/GemstoneFFI.h" "$HEADERS/"
# ⚠️ UniFFI 产出的可能叫 GemstoneFFI.modulemap，xcframework 要求叫 module.modulemap
cp "$STONE/generated/swift/GemstoneFFI.modulemap" "$HEADERS/module.modulemap"

xcodebuild -create-xcframework \
  -library "$REPO_ROOT/core/target/aarch64-apple-ios/release/libgemstone.a"     -headers "$HEADERS" \
  -library "$REPO_ROOT/core/target/aarch64-apple-ios-sim/release/libgemstone.a" -headers "$HEADERS" \
  -output "$OUT"

(cd "$(dirname "$OUT")" && zip -qr GemstoneFFI.xcframework.zip GemstoneFFI.xcframework)
swift package compute-checksum "$OUT.zip"      # 最后一行输出 checksum
```

> 🔴 **第一次跑要确认 modulemap 的实际文件名**。`generate_module_map = true` 打开后先 `ls core/gemstone/generated/swift/` 看一眼，名字对不上就改脚本里那行 `cp`。

> 真机 + 模拟器**必须都打**，否则下游只能在其中一种上跑。需要 Mac Catalyst 就加 `aarch64-apple-ios-macabi`。

### 5.3 第 3 步：上传到 Generic Package Registry

**GitLab 的 Release 不直接托管文件**（和 GitHub 不同），它只是「链接到资产」。所以 zip 要传到 Generic Package Registry：

```bash
curl --fail \
  --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  --upload-file build/GemstoneFFI.xcframework.zip \
  "https://gitlab.your-company.com/api/v4/projects/<ID>/packages/generic/gemstone-ios/2.114.10/GemstoneFFI.xcframework.zip"
```

下载地址（SPM 里要填这个）：

```
https://gitlab.your-company.com/api/v4/projects/<ID>/packages/generic/gemstone-ios/2.114.10/GemstoneFFI.xcframework.zip
```

### 5.4 第 4 步：`gemstone-swift` 项目

#### 结构

```
gemstone-swift/
├── Package.swift
├── Sources/
│   └── Gemstone/
│       └── Gemstone.swift        ← 每次发版由脚本/CI 覆盖提交
└── README.md
```

**不需要 `Sources/GemstoneFFI/`** —— C 层由 xcframework 提供。

#### `Package.swift`

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Gemstone",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [
        .library(name: "Gemstone", targets: ["Gemstone"])
    ],
    targets: [
        .target(
            name: "Gemstone",
            dependencies: ["GemstoneFFI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .binaryTarget(
            name: "GemstoneFFI",
            url: "https://gitlab.your-company.com/api/v4/projects/<ID>/packages/generic/gemstone-ios/2.114.10/GemstoneFFI.xcframework.zip",
            checksum: "PLACEHOLDER"        // ← 每次发版脚本自动替换
        )
    ]
)
```

---

## 6. ⚠️ SPM 私有仓库的硬限制

> **`.binaryTarget(url:checksum:)` 下载时不带任何鉴权头。**

私有 GitLab 项目的 Generic Package Registry 需要 token → **SPM 拉不到，报 404 或 401**。这个限制换平台不解决。

### 四条路

| 方案 | 做法 | 代价 | 推荐度 |
|---|---|---|---|
| **A. 项目设为 internal** | 自建 GitLab 上，internal = 登录用户可见、外网不可达 | 无 | ⭐⭐⭐ **自建实例首选** |
| **B. 单独开一个 public 项目放产物** | 只放 xcframework.zip，源码仍私有 | 产物公开可下载 | ⭐⭐ 如果二进制不敏感 |
| **C. xcframework 提交进 `gemstone-swift`** | 用 `.binaryTarget(path:)`，git clone 走 SSH 认证是通的 | 仓库膨胀（每版几十 MB），要配 Git LFS | ⭐ 版本少时可行 |
| **D. 改用 CocoaPods** | podspec + `vendored_frameworks` + 私有 spec repo（GitLab 项目当 spec repo） | 放弃 SPM | ⭐⭐ 严格私有场景 |

### 方案 A 的说明（推荐）

自建 GitLab 的可见性有三档：

| 级别 | 含义 |
|---|---|
| private | 仅成员可见 |
| **internal** | **任何登录用户可见** ← 内网人人可读，外网访问不到 |
| public | 匿名可见 |

**如果你们是自建 GitLab（内网），把 `gemstone-ios-artifacts` 设成 internal 就同时满足了 SPM 和安全要求。**

> ⚠️ 用 gitlab.com（云）的话 internal 意味着「任何 gitlab.com 用户」，那就不行了，得走 C 或 D。

### 方案 C 的 `Package.swift` 写法

```swift
.binaryTarget(
    name: "GemstoneFFI",
    path: "Frameworks/GemstoneFFI.xcframework"     // ← 仓库内路径，不走 HTTP
)
```

配 Git LFS：

```bash
cd gemstone-swift
git lfs install
git lfs track "*.xcframework/**"
git add .gitattributes
```

**这个决定要在建项目时就定**，后面改成本不低。

---

## 7. 手动发布方案（推荐先做这个）

**发版频率低的话，手动完全够用。关键是写成脚本，别靠记忆。**

### `scripts/release.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?用法: ./release.sh 2.114.10}"
GITLAB="https://gitlab.your-company.com"
CORE_PROJECT_ID="123"
IOS_PROJECT_ID="124"                     # 放 xcframework 的项目，可以和 CORE 相同
SWIFT_REPO="git@gitlab.your-company.com:your-group/gemstone-swift.git"
: "${GITLAB_TOKEN:?请先 export GITLAB_TOKEN=glpat-xxx}"

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

echo "==> [1/6] 生成 Kotlin 绑定"
(cd core/gemstone && just bindgen-kotlin)

echo "==> [2/6] 发布 AAR 到 GitLab Maven Registry"
(cd core/gemstone/android && touch local.properties && \
  BUILD_MODE=release VER_NAME="$VERSION" \
  ./gradlew publishReleasePublicationToGitLabRepository)

echo "==> [3/6] 生成 Swift 绑定 + 编译静态库（真机 + 模拟器）"
(cd ios && BUILD_MODE=release just generate-stone)

echo "==> [4/6] 打包 xcframework"
CHECKSUM=$(bash core/gemstone/scripts/package-xcframework.sh | tail -1)
echo "    checksum = $CHECKSUM"

echo "==> [5/6] 上传 zip 到 Generic Package Registry"
curl --fail --silent --show-error \
  --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  --upload-file build/GemstoneFFI.xcframework.zip \
  "$GITLAB/api/v4/projects/$IOS_PROJECT_ID/packages/generic/gemstone-ios/$VERSION/GemstoneFFI.xcframework.zip"
echo

echo "==> [6/6] 更新 gemstone-swift 并打 tag"
TMP=$(mktemp -d)
git clone --depth 1 "$SWIFT_REPO" "$TMP"
mkdir -p "$TMP/Sources/Gemstone"
cp core/gemstone/generated/swift/gemstone.swift "$TMP/Sources/Gemstone/Gemstone.swift"

# macOS 的 sed 要 -i ''，Linux 上去掉那个空串
sed -i '' -E \
  -e "s|packages/generic/gemstone-ios/[^/]+/|packages/generic/gemstone-ios/$VERSION/|" \
  -e "s|checksum: \".*\"|checksum: \"$CHECKSUM\"|" \
  "$TMP/Package.swift"

(cd "$TMP" \
  && git add -A \
  && git commit -m "Release $VERSION (core@$(git -C "$REPO_ROOT" rev-parse --short HEAD))" \
  && git tag "$VERSION" \
  && git push origin HEAD --tags)

rm -rf "$TMP"
echo "✅ $VERSION 发布完成"
```

发版一条命令：

```bash
export GITLAB_TOKEN=glpat-xxx
./scripts/release.sh 2.114.10
```

> ⭐ 注意第 6 步的 commit message 里带了 `core@<short-sha>` —— **手动发布最容易丢失的就是「这个包是从哪个 commit 出来的」**，这行解决可追溯性。

### CI 到底替你做了什么

拆开看就是这 6 步，加上一次性的环境准备：

| 一次性（装完就有） | 每次发版 |
|---|---|
| `rustup target add` ×5 | 上面脚本的 6 步 |
| `cargo install cargo-ndk@4.1.2` | |
| `sdkmanager --install "ndk;28.1.13356709"` | |

**Android 日常发版实际只有 2 条命令，iOS 6 步。** 所以不上 CI 并不复杂。

---

## 8. GitLab CI 方案

有了 §7 的脚本，CI 就是把它塞进 `.gitlab-ci.yml`：

```yaml
stages: [publish, verify]

variables:
  VERSION: $CI_COMMIT_TAG

publish-android:
  stage: publish
  image: your-registry/rust-android:latest      # 预装 Rust + NDK + cargo-ndk 的镜像
  rules:
    - if: $CI_COMMIT_TAG
  script:
    - cd core/gemstone && just bindgen-kotlin
    - cd android && touch local.properties
    - BUILD_MODE=release VER_NAME=$VERSION
      ./gradlew publishReleasePublicationToGitLabRepository
  # CI_JOB_TOKEN 自动注入，build.gradle.kts 里已判断用 Job-Token header，不用配 secret

publish-ios:
  stage: publish
  tags: [macos]                                 # 🔴 必须有 macOS runner
  rules:
    - if: $CI_COMMIT_TAG
  variables:
    GITLAB_TOKEN: $CI_JOB_TOKEN
  script:
    - ./scripts/release.sh $VERSION             # 直接复用手动脚本
  # ⚠️ CI_JOB_TOKEN 默认不能 push 到别的项目，
  #    要么在 gemstone-swift 项目里配 CI job token allowlist，
  #    要么改用组级 Deploy Token（推荐）

verify-android:
  stage: verify
  needs: [publish-android]
  rules:
    - if: $CI_COMMIT_TAG
  script:
    - cd core/gemstone/tests/android/GemTest && ./gradlew assembleDebug
```

### 两个必须提前确认的事

| # | 事项 | 说明 |
|:---:|---|---|
| **1** | 🔴 **有没有 macOS runner** | `xcodebuild` 只能在 mac 上跑。没有的话 iOS 只能手动发 |
| **2** | 🔴 **CI_JOB_TOKEN 的跨项目权限** | 默认不允许推到别的项目。要么在 `gemstone-swift` 的 **Settings → CI/CD → Job token permissions** 里把 `core` 加进 allowlist，要么用组级 Deploy Token |

> ⭐ **「Android 上 CI、iOS 手动」是很常见的现实选择**，没有 mac runner 就别硬凑。

---

## 9. 下游消费方配置

### Android App

`settings.gradle.kts`：

```kotlin
import org.gradle.api.credentials.HttpHeaderCredentials
import org.gradle.authentication.http.HttpHeaderAuthentication

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        maven {
            name = "GitLab"
            // ⭐ 组级 URL：一次配好，整个 group 下的包都能拉
            url = uri("https://gitlab.your-company.com/api/v4/groups/<GROUP_ID>/-/packages/maven")
            credentials(HttpHeaderCredentials::class) {
                name = "Deploy-Token"
                value = providers.gradleProperty("gitlab.readToken").get()
            }
            authentication { create<HttpHeaderAuthentication>("header") }
        }
    }
}
```

开发者本机 `~/.gradle/gradle.properties`（**不提交**）：

```properties
gitlab.readToken=gldt-xxxxxxxxxxxx
```

`app/build.gradle.kts`：

```kotlin
dependencies {
    implementation("com.gemwallet.gemstone:gemstone:2.114.10")
}
```

### iOS App

```swift
dependencies: [
    .package(url: "https://gitlab.your-company.com/your-group/gemstone-swift.git", from: "2.114.10")
]
```

Xcode 会用系统的 git 凭据（SSH key 或 credential helper）clone 私有仓库，**这一步没问题**。有问题的只有 `binaryTarget` 下载 zip 那步，见 §6。

---

## 10. 验收

> ⭐ **「发布成功」的定义不是「脚本跑完没报错」，是「下游能拉下来跑起来」。**

### `scripts/verify-release.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
VERSION="${1:?}"

echo "==> Android：示例工程拉远端 AAR 编译"
(cd core/gemstone/tests/android/GemTest && ./gradlew assembleDebug)

echo "==> iOS：示例工程拉远端 SPM 包编译"
(cd core/gemstone/tests/ios/GemTest && \
  xcodebuild -scheme GemTest -destination 'platform=iOS Simulator,name=iPhone 17' build)

echo "✅ 双端验收通过"
```

前提是把两个示例工程的依赖改成远端坐标：

```gradle
// core/gemstone/tests/android/GemTest/app/build.gradle:43
- api "com.gemwallet.gemstone:gemstone:1.0.3@aar"
+ api "com.gemwallet.gemstone:gemstone:2.114.10@aar"
```

> ⚠️ **现有示例工程的依赖是坏的**：它引用 `gemstone:1.0.3`，但 `just gemstone build-android` 实际发布的是 `gemstone-debug:1.0.0-debug`（artifactId 和版本都对不上），而且它不在任何 CI 里，所以这个不一致一直没暴露。

### 发布后自检

```bash
# AAR 三个 ABI 都在？
unzip -l ~/.m2/repository/com/gemwallet/gemstone/gemstone/<ver>/*.aar | grep jni
# 期望三行：arm64-v8a / armeabi-v7a / x86_64

# 绑定源码在 sources jar 里？
unzip -l ~/.m2/repository/.../*-sources.jar | grep gemstone.kt

# xcframework 两个切片都在？
ls build/GemstoneFFI.xcframework/

# checksum 和 Package.swift 里写的一致？
swift package compute-checksum build/GemstoneFFI.xcframework.zip
```

---

## 11. 检查清单

### 首次搭建

**决策（先定，影响后面所有步骤）**

- [ ] GitLab 是自建还是 gitlab.com？
- [ ] `gemstone-ios-artifacts` 能不能设成 **internal**？（决定 §6 走 A 还是 C/D）
- [ ] 有没有 **macOS runner**？（决定 iOS 上不上 CI）
- [ ] AAR 发到 `core` 项目还是单独建项目？

**Android（约半天）**

- [ ] 建组级 Deploy Token（publisher + consumer 各一个）
- [ ] `build.gradle.kts` 加 `HttpHeaderCredentials` 的 `repositories` 块
- [ ] 版本号改成从 `Cargo.toml` 读
- [ ] justfile 加 `publish-android`（含 `BUILD_MODE=release`）
- [ ] 本机 `publishToMavenLocal` 验三个 ABI + sources jar
- [ ] 推一次远端，在 GitLab 项目的 **Packages and registries** 页面能看到

**iOS（约 1–2 天）**

- [ ] `uniffi.toml` 改 `generate_module_map = true`
- [ ] 跑一次 `just generate-stone`，**确认 modulemap 的实际文件名**
- [ ] 写 `package-xcframework.sh`，本机跑通并拿到 checksum
- [ ] 建 `gemstone-swift` 项目，手动放 `Package.swift`
- [ ] 手动上传一次 zip 到 Generic Package Registry
- [ ] **新建一个空 iOS 工程，加 SPM 依赖验证能 `import Gemstone`** ← 这步是 §6 决策的验证关

**脚本化（约半天）**

- [ ] `scripts/release.sh`
- [ ] `scripts/verify-release.sh`
- [ ] 修掉示例工程的依赖坐标
- [ ] README 写死工具链版本（Rust / NDK / cargo-ndk）

**CI（可选，约半天）**

- [ ] `.gitlab-ci.yml`
- [ ] 配 CI job token 跨项目 allowlist，或改用 Deploy Token
- [ ] 用 `workflow_dispatch` 等价的手动触发验证一次

### 每次发版

- [ ] `just bump` 更新版本号
- [ ] `./scripts/release.sh <version>`
- [ ] `./scripts/verify-release.sh <version>` ← **不过不算发布成功**
- [ ] CHANGELOG 写清新增 / 变更 / 移除 / 破坏性变更

---

## 附：手动 vs CI 的取舍

| 发版频率 | 建议 |
|---|---|
| 每周 1 次以下 | ✅ **手动脚本足够**，别为了 CI 而 CI |
| 每周多次 / 多人发布 | 上 CI |
| 有合规审计要求 | 必须上 CI（要可追溯） |

### 不用 CI 的四个风险

| 风险 | 后果 | 缓解 |
|---|---|---|
| **忘步骤** | 漏 `BUILD_MODE=release` → 发出 debug 版；漏更新 checksum → 下游 SPM 解析失败 | ⭐ 用脚本，`set -euo pipefail` 任一步失败立即中断 |
| **本机环境差异** | 不同人发出的产物不一致 | 固定发布机；README 写死工具链版本 |
| **没有验收关** | 问题到下游才暴露 | ⭐ 每次发完跑 `verify-release.sh` |
| **无法追溯** | 不知道谁发的、从哪个 commit | 脚本里把 `core@<sha>` 写进 commit message |

> **优先级：脚本化 > CI。** 有了脚本，以后想上 CI 只是把它塞进 `.gitlab-ci.yml`，几乎零成本；反过来先搞 CI 但没脚本，本地调试会很痛苦。

---

*本文档由 AI 辅助整理。仓库现状基于 commit `820c415579` 实测；GitLab 平台细节来自既有知识，落地前请对照你们 GitLab 版本的官方文档核实 API URL 与 token scope。*
