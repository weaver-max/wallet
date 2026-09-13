# gem Core 团队应该给 iOS 和 Android 提供什么

> 面向：维护 `core/` 的 Rust 团队
> 场景：iOS / Android 在独立仓库，不共用 monorepo
> 相关：[基于gem-core的ios和安卓开发教程.md](基于gem-core的ios和安卓开发教程.md) 第 9 章 · [安卓如何使用gem从0开发钱包.md](安卓如何使用gem从0开发钱包.md)
> 基线：commit `820c415579`，现状均已对照源码核实

---

## 目录

1. [交付物总览](#1-交付物总览)
2. [核心原则：绑定和原生库必须同批发布](#2-核心原则绑定和原生库必须同批发布)
3. [Android AAR](#3-android-aar)
4. [iOS XCFramework](#4-ios-xcframework)
5. [TypeShare 模型（可选）](#5-typeshare-模型可选)
6. [非代码交付物](#6-非代码交付物)
7. [建议补齐的接口缺口](#7-建议补齐的接口缺口)
8. [发布流水线](#8-发布流水线)
9. [验收标准](#9-验收标准)
10. [职责边界](#10-职责边界)
11. [检查清单](#11-检查清单)

---

## 1. 交付物总览

| # | 交付物 | Android | iOS | 现状 |
|:---:|---|:---:|:---:|---|
| 1 | **二进制制品**（含绑定 + 原生库） | AAR | XCFramework + SPM 包 | Android 差一步，iOS 差三步 |
| 2 | **源码 jar / 绑定文件** | 已含在 AAR sources jar | 需随 SPM 包入库 | Android ✅ |
| 3 | **Chain 字符串取值表** | 共用 | 共用 | ❌ 运行时查不到，必须给文档 |
| 4 | **稳定接口清单 + CHANGELOG** | 共用 | 共用 | ❌ 没有 |
| 5 | **错误类型清单** | 共用 | 共用 | ❌ 没有 |
| 6 | **消费方示例工程** | `tests/android/GemTest` | `tests/ios/GemTest` | ✅ 已有，需改成拉远端包 |
| 7 | **版本策略** | 共用 | 共用 | ❌ 未约定 |

### 不需要提供的

| 项 | 为什么 |
|---|---|
| Rust 源码 / 工具链 | 消费方**不应该**装 Rust、NDK、cargo-ndk。装了就是发布流程没做对 |
| TypeShare 模型（按需） | 单链钱包等轻量消费方用不上，见 §5 |
| Gem 后端 API 地址 | 只有 `getTransactionScan()` 用到，消费方不调就不需要 |

---

## 2. 核心原则：绑定和原生库必须同批发布

> 🔴 **绝对不要单独把生成的 `.swift` / `.kt` 文件发给下游让他们提交进仓库。**

UniFFI 生成的绑定里带 `uniffiCheckContractApiVersion()` 和 `uniffiCheckApiChecksums()`。绑定和原生库版本对不上，**App 启动时直接 crash，不是编译期报错**。

手工拷贝文件迟早会踩这个，而且下游排查成本极高——他们看到的是一个启动崩溃，栈里全是生成代码。

**正确做法：一次构建同时产出绑定和原生库，打成同一个版本化制品。**

```
一次 CI 构建
   ├─ uniffi-bindgen generate  → .swift / .kt
   ├─ cargo ndk / cargo rustc  → .so / .a
   └─ 打包成 AAR / XCFramework  ← 两者绑定在一起，版本不可能错位
```

---

## 3. Android AAR

### 3.1 现状：改动很小

`core/gemstone/android/gemstone/build.gradle.kts` 里**已经配好的**：

| 项 | 现状 |
|---|---|
| `maven-publish` 插件 | ✅ 已启用 |
| 两个 publication | ✅ `release`（artifactId `gemstone`）+ `debug`（artifactId `gemstone-debug`） |
| sources jar + javadoc jar | ✅ `withSourcesJar()` / `withJavadocJar()` |
| **ABI 三个全** | ✅ 硬编码 `arm64-v8a` + `armeabi-v7a` + **`x86_64`** |
| JNA 传递依赖 | ✅ `api("net.java.dev.jna:jna:5.18.1@aar")` |
| 版本号入口 | ✅ 走 `VER_NAME` 环境变量 |
| Rust 自动编译 | ✅ `bindgenKotlin` / `buildCargoNdk` 已挂钩 |

> ⭐ **`withSourcesJar()` 意味着生成的 `gemstone.kt` 会自动打进 sources jar** —— 下游在 Android Studio 里能直接跳转看源码，不需要单独索要。

> ⚠️ **注意区分两个 Gradle 工程**：
> - `core/gemstone/android/` —— **独立发布工程**（`rootProject.name = "gemstone-android"`），ABI 硬编码三个
> - `android/gemstone/` —— 主 App 的壳模块，ABI 走环境变量，默认只编两个 arm
>
> **发布走前者。** 改错地方不生效。

### 3.2 唯一的硬缺口：没有 `repositories { }` 块

`publishing` 块里只声明了 `publications`，没声明推到哪里，所以只能 `publishToMavenLocal`。

**补这一段：**

```kotlin
// core/gemstone/android/gemstone/build.gradle.kts
afterEvaluate {
    publishing {
        publications { /* 现有内容不变 */ }

        // ↓↓↓ 新增 ↓↓↓
        repositories {
            maven {
                name = "GitHubPackages"
                url = uri("https://maven.pkg.github.com/<org>/<repo>")
                credentials {
                    username = System.getenv("GITHUB_ACTOR")
                        ?: providers.gradleProperty("gpr.user").orNull
                    password = System.getenv("GITHUB_TOKEN")
                        ?: providers.gradleProperty("gpr.token").orNull
                }
            }
        }
    }
}
```

自动生成这些 task：

```
publishReleasePublicationToGitHubPackagesRepository
publishDebugPublicationToGitHubPackagesRepository
```

**内网 Nexus / Artifactory 版本：**

```kotlin
repositories {
    maven {
        name = "internal"
        url = if ((System.getenv("VER_NAME") ?: "").endsWith("-SNAPSHOT"))
            uri("https://nexus.your-company.com/repository/maven-snapshots/")
        else
            uri("https://nexus.your-company.com/repository/maven-releases/")
        credentials {
            username = System.getenv("NEXUS_USER")
            password = System.getenv("NEXUS_PASSWORD")
        }
    }
}
```

> ⚠️ **GitHub Packages 的私有仓库要求消费方也认证**（`read:packages` token）。如果下游在公司内网不便用 GitHub token，**Nexus / Artifactory 更顺手**。这件事要提前和消费方确认，别等发完才发现他们拉不动。

### 3.3 版本号和 Cargo.toml 联动

现在 `VER_NAME` 默认硬编码 `"1.0.0"`，应该跟 `core/Cargo.toml` 的 `version` 对齐：

```kotlin
val coreVersion: String by lazy {
    System.getenv("VER_NAME")
        ?: gemstoneRoot.resolve("../Cargo.toml").readLines()
            .first { it.trimStart().startsWith("version") }
            .substringAfter('"').substringBefore('"')
}

create<MavenPublication>("release") {
    from(components["release"])
    groupId = "com.gemwallet.gemstone"
    artifactId = "gemstone"
    version = coreVersion              // ← 改这里
}
```

这样 `just bump` 之后 AAR 版本自动跟上，不会漏。

### 3.4 更新 justfile

```just
# 本地开发，保持不变
build-android: bindgen-kotlin
    #!/usr/bin/env bash
    rm -rf ~/.m2/repository/com/gemwallet/gemstone/gemstone
    cd android && touch local.properties && ./gradlew publishDebugPublicationToMavenLocal

# 新增：正式发布
publish-android: bindgen-kotlin
    #!/usr/bin/env bash
    set -euo pipefail
    cd android && touch local.properties
    BUILD_MODE=release ./gradlew publishReleasePublicationToGitHubPackagesRepository
```

> 🔴 **`BUILD_MODE=release` 不能漏** —— 不加就发出去 debug 优化等级的 `.so`，体积大、性能差。

### 3.5 本地验证

```bash
cd core/gemstone && just bindgen-kotlin
cd android && touch local.properties
BUILD_MODE=release VER_NAME=2.114.10-test ./gradlew publishReleasePublicationToMavenLocal

# 三个 ABI 都在？
unzip -l ~/.m2/repository/com/gemwallet/gemstone/gemstone/2.114.10-test/gemstone-2.114.10-test.aar | grep jni
# 期望：
#   jni/arm64-v8a/libgemstone.so
#   jni/armeabi-v7a/libgemstone.so
#   jni/x86_64/libgemstone.so     ← 缺了下游模拟器跑不起来

# 绑定源码在 sources jar 里？
unzip -l ~/.m2/repository/.../gemstone-2.114.10-test-sources.jar | grep gemstone.kt
```

### 3.6 改动汇总

| 文件 | 改什么 | 行数 |
|---|---|---|
| `core/gemstone/android/gemstone/build.gradle.kts` | `repositories { }` + 版本联动 | **~20** |
| `core/gemstone/justfile` | `publish-android` recipe | ~6 |

---

## 4. iOS XCFramework

**iOS 的缺口比 Android 大得多。** 当前是 monorepo 专属方案，跨仓库完全不可用。

### 4.1 先搞清楚：`gemstone-swift` 是干嘛的

后面会反复提到要新建一个 `gemstone-swift` 仓库。**它就是 iOS 版的「AAR 仓库」—— 一个只用来分发编译产物的空壳仓库，不放 Rust 源码。**

| | Android | iOS |
|---|---|---|
| 下游怎么拿到 gemstone | `implementation("com.gemwallet.gemstone:gemstone:2.114.10")` | `.package(url: ".../gemstone-swift", from: "2.114.10")` |
| 制品放哪 | GitHub Packages（挂在 core 仓库下的 registry） | **必须是一个独立 Git 仓库** |
| 要新建仓库吗 | ❌ 不用 | ✅ **要** |

#### 为什么 iOS 非要单开一个仓库

Swift Package Manager 有两条硬规矩：

1. **`Package.swift` 必须在仓库根目录** —— 不支持子目录里的包
2. **版本号 = git tag** —— SPM 没有独立 registry，靠 tag 取版本

而 `core` 是个 monorepo，根目录放 `Package.swift` 很别扭，而且 tag 会和 core 自己的版本 tag 打架。所以只能单开。

Android 没这个问题——GitHub Packages 是真正的 Maven registry，和仓库源码无关，AAR 直接发到 `core` 仓库的 registry 即可。

#### 里面装什么

```
gemstone-swift/
├── Package.swift                        ← 依赖声明 + xcframework 的 URL 和 checksum
├── Sources/Gemstone/Gemstone.swift      ← UniFFI 生成的 Swift 绑定（CI 每次发版覆盖）
└── Releases/
    └── 2.114.10/
        └── GemstoneFFI.xcframework.zip  ← 编译好的静态库（挂在 GitHub Release 上）
```

**没有一行手写代码**，全部由 CI 从 core 仓库生成后推过来。

#### 发版时它怎么被更新

```
core 打 tag v2.114.10
      │  CI 自动：
      ├─ 生成 Gemstone.swift ─────────────► 提交到 gemstone-swift
      ├─ 编译 libgemstone.a（真机 + 模拟器）
      ├─ 打成 GemstoneFFI.xcframework.zip ─► 挂到 gemstone-swift 的 Release
      └─ 更新 Package.swift 的 url + checksum，打同名 tag
      │
      ▼
iOS App 仓库：.package(url: ".../gemstone-swift", from: "2.114.10")
```

> ⭐ **类比**：它相当于 Android 的「AAR + Maven 坐标」、npm 的「发到 registry 的那个包」、Rust 的「crates.io 上的 crate」。只不过 Swift 没有中心化 registry，所以「包」本身就是一个 Git 仓库。

### 4.2 现状：为什么现在的方式跨不了仓库

```
LIBRARY_SEARCH_PATHS[sdk=iphoneos*] = $(SRCROOT)/../core/target/aarch64-apple-ios/release
OTHER_LDFLAGS                       = -lgemstone
```

裸 `.a` + 相对路径搜索。下游仓库里**这个路径不存在**。

而且 `grep xcframework` 全仓库**零命中** —— 没有任何打包工具链。

### 4.3 第 1 步：开启 modulemap

```toml
# core/gemstone/uniffi.toml
[bindings.swift]
ffi_module_name = "GemstoneFFI"
generate_module_map = true          # ← 现在是 false，必须改
experimental_sendable_value_types = true
omit_localized_error_conformance = true
```

monorepo 里靠 SPM 的 `publicHeadersPath` 绕过去了，`binaryTarget` 不行——它要求 xcframework 里自带 headers + modulemap。

### 4.4 第 2 步：打 XCFramework

在 `ios/scripts/generate-stone.sh` 的 `build_ios_static_libraries()` 之后追加，或新建 `core/gemstone/scripts/package-xcframework.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail

PROFILE=release
OUT=build/GemstoneFFI.xcframework
rm -rf "$OUT" "$OUT.zip"

xcodebuild -create-xcframework \
  -library core/target/aarch64-apple-ios/$PROFILE/libgemstone.a     -headers core/gemstone/generated/swift/include \
  -library core/target/aarch64-apple-ios-sim/$PROFILE/libgemstone.a -headers core/gemstone/generated/swift/include \
  -output "$OUT"

zip -r "$OUT.zip" "$OUT"
swift package compute-checksum "$OUT.zip"     # ← 记下这个 checksum
```

> 🔴 **真机 + 模拟器必须都打**，否则下游只能在其中一种上跑。
> 需要 Mac Catalyst 就加 `aarch64-apple-ios-macabi`（`install-ios-targets` 已经装了这个 target）。

### 4.5 第 3 步：建独立分发仓库 `gemstone-swift`

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Gemstone",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [.library(name: "Gemstone", targets: ["Gemstone"])],
    targets: [
        // Gemstone.swift 作为源码入库（每次发版更新）
        .target(name: "Gemstone", dependencies: ["GemstoneFFI"]),
        // .a 从 Release 下载
        .binaryTarget(
            name: "GemstoneFFI",
            url: "https://github.com/<org>/gemstone-swift/releases/download/2.114.10/GemstoneFFI.xcframework.zip",
            checksum: "<上一步算出来的>"
        )
    ]
)
```

发版流程：

```
core 打 tag
  → CI 生成 Gemstone.swift + GemstoneFFI.xcframework.zip
  → zip 上传到 gemstone-swift 的 Release
  → Gemstone.swift 提交进 gemstone-swift 仓库
  → 更新 Package.swift 的 url + checksum
  → 给 gemstone-swift 打同名 tag
```

下游：

```swift
.package(url: "https://github.com/<org>/gemstone-swift", from: "2.114.10")
```

### 4.6 私有分发的坑

> ⚠️ **`binaryTarget` 的 URL 不支持带鉴权头。**

| 场景 | 方案 |
|---|---|
| 公开仓库 | GitHub Release 直链，最简单 |
| 内网 | S3 预签名 URL（注意有效期）或内网 HTTP |
| 私有且需鉴权 | **改用 CocoaPods**（podspec + `vendored_frameworks` + 私有 spec repo），对私有分发更友好 |

### 4.7 改动汇总

| 文件 | 改什么 | 工作量 |
|---|---|---|
| `core/gemstone/uniffi.toml` | `generate_module_map = true` | 1 行 |
| 新建打包脚本 | `create-xcframework` + zip + checksum | ~30 行 |
| 新建 `gemstone-swift` 仓库 | Package.swift + Sources | 新仓库 |
| CI | 生成 + 上传 + 更新 checksum + 打 tag | ~60 行 |

> **iOS 这条链路建议一次做对**，尤其 checksum 更新这步容易忘——checksum 不匹配 SPM 会拒绝解析，下游会看到一个很不友好的报错。

---

## 5. TypeShare 模型（可选）

`core/crates/primitives` 生成的 Swift / Kotlin 是**纯源码，零原生依赖**，和 gemstone 是两套独立类型：

```
Kotlin:  com.wallet.core.primitives.*    ← TypeShare
         uniffi.gemstone.*               ← UniFFI
```

### 什么时候需要给

| 消费方类型 | 要不要 |
|---|---|
| 完整钱包 App（多链、行情、交易历史） | ✅ 要 |
| 单链轻量钱包 | ❌ 不要，`uniffi.gemstone.*` 够了 |

### 怎么给

- iOS → 一个 source-only SPM package
- Android → 纯 Kotlin/JVM jar，或干脆塞进同一个 AAR

**版本号统一用 `core/Cargo.toml` 的版本**，别让下游做版本矩阵。

---

## 6. 非代码交付物

这部分现在**完全缺失**，但对下游的价值不亚于制品本身。

### 6.1 🔴 Chain 字符串取值表（最急）

`Chain` 在 FFI 里是 **String**，不是枚举：

```rust
uniffi::custom_type!(Chain, String, { ... });    // core/gemstone/src/models/custom_types.rs:6
```

而且**运行时查不到全量列表** —— `grep all_chains` 零命中，没有导出枚举函数。**下游只能猜，猜错了运行期才报错。**

转换规则是 `#[strum(serialize_all = "lowercase")]`，注意是 **lowercase 不是 snake_case**：

| Rust 变体 | FFI 字符串 | 容易猜错成 |
|---|---|---|
| `Ethereum` | `"ethereum"` | — |
| `SmartChain` | `"smartchain"` | ~~`smart_chain`~~ |
| `AvalancheC` | `"avalanchec"` | ~~`avalanche_c`~~ |
| `OpBNB` | `"opbnb"` | ~~`op_bnb`~~ |
| `SeiEvm` | `"seievm"` | ~~`sei_evm`~~ |
| `BitcoinCash` | `"bitcoincash"` | ~~`bitcoin_cash`~~ |

**两个解决方案，建议都做：**

**① 短期：随每个版本发一份取值表**

```bash
# 生成脚本示例
cargo run -p <bin> -- list-chains > CHAINS.md
```

**② 长期：导出一个查询函数**

```rust
#[uniffi::export]
pub fn all_chains() -> Vec<Chain> {
    Chain::iter().collect()        // Chain 已经 derive 了 EnumIter
}
```

几行代码，但能让下游在运行时拿到权威列表，还能做单测断言。

### 6.2 稳定接口清单

不是所有 `#[uniffi::export]` 都该对外承诺稳定。建议分级：

| 级别 | 含义 | 变更规则 |
|---|---|---|
| **Stable** | 承诺兼容 | 破坏性变更走 major，且提前一个版本 `#[deprecated]` |
| **Preview** | 可能变 | minor 版本内可变，但要写进 CHANGELOG |
| **Internal** | 不对外 | 随时可改（理想情况应该收回 `pub(crate)`） |

至少要明确：`GemKeystore`、`GemGateway`、`AlienProvider`、`GemPreferences`、`GemMnemonic` 这几个是 Stable。

### 6.3 CHANGELOG

每次发版明确列出：

```markdown
## 2.115.0

### 新增
- `GemKeystore.verify(keystoreId, password) -> Bool`

### 变更
- `GemGateway.getFeeRates` 返回值增加 `estimatedSeconds` 字段（Record 加字段，向后兼容）

### 移除
- 无

### 破坏性变更
- 无
```

> 🔴 **`#[uniffi::export]` 的任何签名变更都会让下游直接编译不过。** 下游没法从制品里看出改了什么，只能靠 CHANGELOG。

### 6.4 错误类型清单

下游需要知道能 catch 到什么。**注意两端后缀不同**：

| Rust | Swift | Kotlin |
|---|---|---|
| `GemstoneError` | `GemstoneError: Error` | `GemstoneException` |
| `AlienError` | `AlienError` | `AlienException` |
| `GatewayError` | `GatewayError` | `GatewayException` |

以及各自的变体和触发条件。

### 6.5 消费方示例工程

**已经有了**，不用新建：

```
core/gemstone/tests/ios/GemTest
core/gemstone/tests/android/GemTest
```

**需要做的是把它们从本地路径引用改成拉远端制品**，然后接进 CI 当发布验收关（见 §9）。

---

## 7. 建议补齐的接口缺口

### 7.1 🔴 `verify` 没导出

`FileKeystore` 上有这些方法，但**都不在 UniFFI 表面**：

```rust
pub fn verify(&self, keystore_id: &str, password: &[u8]) -> Result<StoredSecretMeta, KeystoreError>
pub fn get_meta(&self, keystore_id: &str) -> ...
pub fn list(&self) -> ...
pub fn change_password(&self, ...) -> ...
```

**后果**：下游没法回答"这个 keystore 文件能用当前密码解开吗"。iOS 现在只能查文件存不存在：

```swift
// ios/Packages/Keystore/Sources/LocalKeystore.swift:233
private func v4KeystoreExists(_ keystoreId: String) -> Bool {
    FileManager.default.fileExists(atPath: keystoreURL.appendingPathComponent("\(keystoreId).json").path)
}
```

而 `KEYSTORE_V4.md` 自己就写着：

> Metadata from `list`, `get_meta`, or `inspect` is **not proof** of migration success. Passworded `verify` or a real decrypt is required.

**文件存在 ≠ 能解密。** 做存量迁移的下游尤其需要这个。

**补法（几行）：**

```rust
#[uniffi::export]
impl GemKeystore {
    pub fn verify(&self, keystore_id: String, password: Vec<u8>) -> Result<bool, GemstoneError> {
        let password = Zeroizing::new(password);
        Ok(self.inner.verify(&keystore_id, &password).is_ok())
    }
}
```

### 7.2 `change_password` 没导出

下游做"两步法迁移"（先设备密钥静默收口，后用户密码体系）时会需要。同样只需包一层。

### 7.3 `all_chains` 没导出

见 §6.1。

### 7.4 交易加速 / 取消

不是缺口而是未实现的功能，但值得告知下游：**Rust 管线已经支持**（`GemTransactionLoadInput.metadata` 里的 nonce 由调用方传入并原样透传到签名），下游可以自己在上层实现。

---

## 8. 发布流水线

### 目标形态

```
core 打 tag v2.114.10
   │
   ├─ CI (macOS) ──► iOS
   │     ├─ uniffi.toml: generate_module_map = true
   │     ├─ bindgen-swift → Gemstone.swift
   │     ├─ cargo rustc ×2 架构 → libgemstone.a
   │     ├─ create-xcframework + zip + checksum
   │     ├─ 上传 zip 到 gemstone-swift Release
   │     ├─ 提交 Gemstone.swift + 更新 Package.swift checksum
   │     └─ 给 gemstone-swift 打 tag
   │
   └─ CI (linux/macOS) ──► Android
         ├─ bindgen-kotlin → uniffi/*.kt
         ├─ cargo ndk ×3 ABI → libgemstone.so
         └─ gradlew publishReleasePublication... → Maven registry
```

现有的 `.github/workflows/release_on_tag.yml` **只有 24 行，就建了个空 Release**，两条发布链路都要补。

### Android CI 骨架

```yaml
jobs:
  publish-aar:
    runs-on: ubuntu-latest
    permissions: { contents: read, packages: write }
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with: { distribution: temurin, java-version: '17' }
      - name: Rust + Android targets
        run: |
          rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
          cargo install cargo-ndk@4.1.2 --locked
      - uses: android-actions/setup-android@v3
      - run: sdkmanager --install "ndk;28.1.13356709"
      - name: Publish
        working-directory: core/gemstone/android
        env:
          BUILD_MODE: release
          VER_NAME: ${{ github.ref_name }}
          GITHUB_ACTOR: ${{ github.actor }}
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          touch local.properties
          ./gradlew publishReleasePublicationToGitHubPackagesRepository
```

> ⚠️ **发布机需要 Rust + NDK + cargo-ndk**（消费方不需要）。首次跑较慢，建议加 cargo 缓存。

---

## 9. 验收标准

> ⭐ **"发布成功" 的定义不是"CI 绿了"，是"消费方能拉下来跑起来"。**

把两个示例工程改成拉远端制品，接进 CI 当发布后置验收：

```yaml
      - name: Verify Android artifact
        working-directory: core/gemstone/tests/android/GemTest
        run: ./gradlew assembleDebug          # 依赖已改为 com.gemwallet.gemstone:gemstone:<ver>

      - name: Verify iOS artifact
        working-directory: core/gemstone/tests/ios/GemTest
        run: xcodebuild -scheme GemTest -destination 'platform=iOS Simulator,name=iPhone 17' build
```

这一步能挡掉：

- 版本错位（checksum / contract version 崩溃）
- ABI 缺失（下游模拟器跑不起来）
- 依赖传递失效（JNA 被误改成 `implementation`）
- SPM checksum 忘更新
- registry 权限配错

### 发布前自检清单

```bash
# Android：三个 ABI 都在？
unzip -l gemstone-<ver>.aar | grep jni
# 期望 arm64-v8a / armeabi-v7a / x86_64 各一行

# Android：绑定源码在？
unzip -l gemstone-<ver>-sources.jar | grep gemstone.kt

# iOS：真机 + 模拟器切片都在？
xcodebuild -list-xcframework GemstoneFFI.xcframework 2>/dev/null || \
  ls GemstoneFFI.xcframework/

# iOS：checksum 和 Package.swift 里写的一致？
swift package compute-checksum GemstoneFFI.xcframework.zip
```

---

## 10. 职责边界

### Core 团队负责

- Rust 实现、UniFFI 接口设计
- 制品构建与发布
- 接口稳定性与 CHANGELOG
- 示例工程能跑通
- 密码学、密钥存储、签名的正确性

### 消费方负责

- `AlienProvider` / `GemPreferences` 的原生实现
- 业务数据库（GRDB / Room）
- UI、导航、状态管理
- 两端行为一致性（缓存 key 算法、header 过滤、错误映射）

### 容易扯皮的三处，建议提前书面约定

| 事项 | 建议归属 | 理由 |
|---|---|---|
| **超时 vs 重试** | 超时归平台（OkHttp `callTimeout` / URLSession），重试归 Rust（`gem_client::retry`） | 不划清会双重重试 |
| **节点 URL 管理** | 平台（`AlienProvider.getEndpoint`） | 用户可在设置里换节点 |
| **`x-gem-cache-ttl` 的两端实现** | 平台实现，**Core 提供参考实现和测试用例** | 两端各写一遍，容易漂移；漏了 filter 会把私有 header 发给服务端 |

---

## 11. 检查清单

### 首次搭建

**Android（约 1 天）**

- [ ] 加 `publishing { repositories { } }` 块
- [ ] 版本号从 `core/Cargo.toml` 读取
- [ ] justfile 加 `publish-android`（含 `BUILD_MODE=release`）
- [ ] 本地 `publishToMavenLocal` 验证三个 ABI + sources jar
- [ ] 配 CI secrets，跑通一次远端发布
- [ ] `tests/android/GemTest` 改成拉远端坐标

**iOS（约 2–3 天）**

- [ ] `uniffi.toml` 改 `generate_module_map = true`
- [ ] 写 xcframework 打包脚本（含 checksum 输出）
- [ ] 建 `gemstone-swift` 分发仓库
- [ ] 确定分发方式（GitHub Release / S3 / CocoaPods）
- [ ] CI 跑通一次完整发布（含 checksum 自动更新）
- [ ] `tests/ios/GemTest` 改成拉远端 SPM 包

**文档（约半天）**

- [ ] 导出 `all_chains()` 或产出 Chain 取值表
- [ ] 标注 Stable / Preview 接口分级
- [ ] 建立 CHANGELOG 模板与流程
- [ ] 整理错误类型清单（含两端命名差异）

**接口补齐（约半天）**

- [ ] 导出 `verify`
- [ ] 导出 `change_password`（如下游有迁移需求）

### 每次发版

- [ ] `just bump` 更新版本
- [ ] CHANGELOG 写清新增 / 变更 / 移除 / 破坏性变更
- [ ] 破坏性变更已提前一个版本标 `#[deprecated]`
- [ ] CI 双端制品都发布成功
- [ ] **两个示例工程拉远端包验证通过** ← 不过不算发布成功
- [ ] Chain 取值表已同步（如有新增链）

---

*本文档由 AI 辅助整理，现状结论基于 commit `820c415579` 实测。发布配置变更后请以仓库内的 `build.gradle.kts` / `uniffi.toml` / workflow 文件为准。*
