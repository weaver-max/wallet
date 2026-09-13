# Rust 回调原生端写好的接口（功能）

> 面向：需要让 Rust 使用 iOS / Android 平台能力的工程师
> 关键词：UniFFI `with_foreign`、反向回调、依赖注入
> 相关：[基于gem-core的ios和安卓开发教程.md](基于gem-core的ios和安卓开发教程.md) 第 7 章④、第 8 章
> 基线：仓库 commit `820c415579`，所有代码片段均从源码摘录

---

## 目录

1. [这是什么](#1-这是什么)
2. [仓库现状：2 个接口，6 份实现](#2-仓库现状2-个接口6-份实现)
3. [入门例子：GemPreferences（同步，25 行）](#3-入门例子gempreferences同步25-行)
4. [完整例子：AlienProvider（异步）](#4-完整例子alienprovider异步)
5. [机制：Rust 是怎么调到 Swift/Kotlin 的](#5-机制rust-是怎么调到-swiftkotlin-的)
6. [自己新增一个：完整步骤](#6-自己新增一个完整步骤)
7. [类型映射](#7-类型映射)
8. [六个约束](#8-六个约束)
9. [什么该委托，什么不该](#9-什么该委托什么不该)
10. [调试](#10-调试)
11. [文件索引](#11-文件索引)

---

## 1. 这是什么

普通的 UniFFI 导出是**平台调 Rust**：

```rust
#[uniffi::export]
pub fn deeplink_build_url(deeplink: Deeplink) -> String { ... }
```

加上 `with_foreign` 就反过来了——**Rust 定义接口，平台用原生语言实现，Rust 调用它**：

```rust
#[uniffi::export(with_foreign)]        // ★ 关键就这一个参数
pub trait GemPreferences: Send + Sync {
    fn get(&self, key: String) -> Result<Option<String>, GatewayError>;
    fn set(&self, key: String, value: String) -> Result<(), GatewayError>;
    fn remove(&self, key: String) -> Result<(), GatewayError>;
}
```

> **一句话：`with_foreign` 的意思是"这个 trait 的实现由外部语言提供"。**
>
> 你用 Swift / Kotlin 正常写一个类，实现 UniFFI 生成的 protocol / interface，把实例交给 Rust，Rust 就能像调用普通 Rust trait 一样调用它。

### 为什么需要它

Rust 跑在移动端，很多能力它做不了或做不好：

| 能力 | Rust 自己做的问题 |
|---|---|
| HTTP 请求 | 要交叉编译 `ring`/`openssl` 到 NDK；抓不到包；丢失系统代理/VPN/连接池 |
| 安全存储 | Keychain / Android Keystore 是平台 API，Rust 够不着 |
| 生物识别 | 同上，必须走平台 |
| UI 交互 | 显然 |

**委托出去，Rust 只保留纯计算和业务逻辑。**

---

## 2. 仓库现状：2 个接口，6 份实现

全仓库只有两个 `with_foreign` trait：

```bash
$ grep -rn "with_foreign" core/gemstone/src
alien/provider.rs:8       # AlienProvider   —— 网络请求
gateway/preferences.rs:4  # GemPreferences  —— 键值存储
```

对应 6 份原生实现：

| 接口 | 端 | 实现 | 底层 | 位置 |
|---|---|---|---|---|
| `AlienProvider` | iOS 生产 | `NativeProvider` | URLSession | `ios/Packages/NativeProviderService/Sources/NativeProvider.swift` |
| `AlienProvider` | Android 生产 | `NativeProvider` | OkHttp | `android/data/services/remote-gem/.../gemapi/NativeProvider.kt` |
| `AlienProvider` | **iOS 示例** | `NativeProvider` | URLSession | `core/gemstone/tests/ios/GemTest/GemTest/Networking/Provider.swift` |
| `AlienProvider` | **Android 示例** | `NativeProvider` | **Ktor** | `core/gemstone/tests/android/GemTest/app/.../NativeProvider.kt` |
| `GemPreferences` | iOS | `GemstonePreferences` / `GemstoneSecurePreferences` | UserDefaults / Keychain | `ios/Packages/Blockchain/Sources/Gateway/` |
| `GemPreferences` | Android | `SharedGemPreferences` / `TinkGemPreferences` | SharedPreferences / Tink | `android/data/repositories/.../config/` · `android/app/.../data/password/` |

> ⭐ **注意 Android 的生产实现用 OkHttp，示例实现用 Ktor。** 这恰好证明了 Rust 完全不关心你用什么库——接口就是接口。

`tests/{ios,android}/GemTest` 这两个是 gem 自带的独立 demo 工程，加起来不到 100 行，**是最好的入门参考**。

---

## 3. 入门例子：GemPreferences（同步，25 行）

从这个开始最容易——同步、三个方法、无异步无缓存。

### Rust 侧定义

```rust
// core/gemstone/src/gateway/preferences.rs:4
#[uniffi::export(with_foreign)]
pub trait GemPreferences: Send + Sync {
    fn get(&self, key: String) -> Result<Option<String>, GatewayError>;
    fn set(&self, key: String, value: String) -> Result<(), GatewayError>;
    fn remove(&self, key: String) -> Result<(), GatewayError>;
}
```

### iOS 实现（全文）

```swift
// ios/Packages/Blockchain/Sources/Gateway/GemstonePreferences.swift
import Foundation
import Gemstone

final class GemstonePreferences: GemPreferences, @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let namespace: String

    init(namespace: String, userDefaults: UserDefaults = .standard) {
        self.namespace = namespace
        self.userDefaults = userDefaults
    }

    func get(key: String) throws -> String? {
        userDefaults.string(forKey: namespace + key)
    }

    func set(key: String, value: String) throws {
        userDefaults.set(value, forKey: namespace + key)
    }

    func remove(key: String) throws {
        userDefaults.removeObject(forKey: namespace + key)
    }
}
```

### Android 实现（全文）

```kotlin
// android/data/repositories/.../config/SharedGemPreferences.kt
import uniffi.gemstone.GemPreferences

class SharedGemPreferences(
    private val sharedPreferences: SharedPreferences
) : GemPreferences {

    override fun get(key: String): String? =
        sharedPreferences.getString(key, null)

    override fun set(key: String, value: String) {
        sharedPreferences.edit(commit = true) { putString(key, value) }
    }

    override fun remove(key: String) {
        sharedPreferences.edit(commit = true) { remove(key) }
    }
}
```

### 注入

```swift
gateway = GemGateway(
    provider: provider,
    preferences: GemstonePreferences(namespace: "gateway"),
    securePreferences: GemstoneSecurePreferences(namespace: "gateway"),
    apiUrl: Constants.apiURL.absoluteString,
)
```
```kotlin
GemGateway(
    alienProvider,
    preferences = SharedGemPreferences(context.getSharedPreferences("gateway_preferences", MODE_PRIVATE)),
    securePreferences = securePreferences,
    apiUrl = Constants.API_URL,
)
```

### 三处值得注意

| 点 | 说明 |
|---|---|
| **Swift 的 `Result<T, E>` 变成 `throws`** | Rust 声明 `Result<Option<String>, GatewayError>` → Swift 是 `throws -> String?` |
| **Kotlin 直接省略错误** | Kotlin 侧不需要写 `@Throws`，抛异常即可 |
| **`@unchecked Sendable`** | Rust bound 是 `Send + Sync`，Swift 侧要么用 `actor`，要么像这样显式声明（并自己保证线程安全） |
| **Rust 侧包了一层再用** | `PreferencesWrapper` 把它转成内部的 `primitives::Preferences`，这样 `core/crates/**` 完全不知道 UniFFI 的存在 |

---

## 4. 完整例子：AlienProvider（异步）

比 `GemPreferences` 多了：`async`、返回 UniFFI 对象、缓存、拦截器。

### Rust 侧定义

```rust
// core/gemstone/src/alien/provider.rs:8
#[uniffi::export(with_foreign)]
#[async_trait]
pub trait AlienProvider: Send + Sync + Debug {
    async fn request(&self, target: AlienTarget) -> Result<Arc<AlienResponse>, AlienError>;
    fn get_endpoint(&self, chain: Chain) -> Result<String, AlienError>;
}
```

### iOS 最小实现（示例工程）

```swift
// core/gemstone/tests/ios/GemTest/GemTest/Networking/Provider.swift
import Gemstone

public actor NativeProvider {                    // actor：天然线程安全
    let nodeConfig: [String: URL]
    let session: URLSession
    let cache: Cache<AlienTarget, Data>
}

extension NativeProvider: AlienProvider {
    public nonisolated func getEndpoint(chain: String) throws -> String {
        guard let url = nodeConfig[chain] else {
            throw AlienError.RequestError(msg: "\(chain) is not supported.")
        }
        return url.absoluteString
    }

    public func request(target: Gemstone.AlienTarget) async throws -> Gemstone.AlienResponse {
        if let data = await self.cache.get(key: target) {
            return Gemstone.AlienResponse(status: nil, data: data)
        }
        let (data, response) = try await self.session.data(for: target.asRequest())
        let status = (response as? HTTPURLResponse)?.statusCode

        if let ttl = target.headers?["x-gem-cache-ttl"] {
            await self.cache.set(value: data, forKey: target, ttl: TimeInterval(ttl))
        }
        return Gemstone.AlienResponse(status: status.map(UInt16.init), data: data)
    }
}
```

### Android 最小实现（示例工程，用 Ktor）

```kotlin
// core/gemstone/tests/android/GemTest/app/.../NativeProvider.kt
import uniffi.gemstone.*

class NativeProvider : AlienProvider {
    val client = HttpClient(CIO) { expectSuccess = true }

    override fun getEndpoint(chain: Chain): String = "http://localhost:8080"

    override suspend fun request(target: AlienTarget): AlienResponse {
        val parsedUrl = try {
            Url(target.url)
        } catch (e: Throwable) {
            throw AlienException.RequestException("invalid url: ${target.url}")
        }
        val response = client.request {
            method = HttpMethod(alienMethodToString(target.method))
            url.takeFrom(parsedUrl)
            headers { target.headers?.forEach { (k, v) -> append(k, v) } }
            target.body?.let { setBody(it) }
        }
        return AlienResponse(response.status.value.toUShort(), response.body())
    }
}
```

### 生产实现多做的事

| | iOS | Android |
|---|---|---|
| 并发安全 | `actor` | `withContext(Dispatchers.IO)` |
| 拦截器 | `requestInterceptor.intercept(&request)` | OkHttp `addInterceptor(nodeAuthInterceptor)` |
| 节点 URL | 走 `NodeURLFetchable` | 走 `GetNodeUrlCase` |
| 缓存 key | `NativeProviderCache.swift` 的 SHA256 | `NativeProviderCache.kt` |
| header 过滤 | `asRequest()` 里 filter 掉 `x-gem-cache-ttl` | builder 里 `if (k != NATIVE_PROVIDER_CACHE_HEADER)` |
| 错误映射 | `NSURLErrorDomain` → `AlienError.ResponseError` | `IOException` → `AlienException.RequestException` + 本地化离线文案 |

---

## 5. 机制：Rust 是怎么调到 Swift/Kotlin 的

```
Rust 侧                          UniFFI 生成                      你写的代码
──────────────────────────────────────────────────────────────────────────────
#[uniffi::export(with_foreign)]
trait GemPreferences        ──►  Swift:  protocol GemPreferences  ──► final class GemstonePreferences: GemPreferences
                                 Kotlin: interface GemPreferences ──► class SharedGemPreferences : GemPreferences
                                        │
                                        │ ① 你 new 一个实例，传给 Rust 构造函数
                                        ▼
Arc<dyn GemPreferences>  ◄──── 包装层 ◄──┘
     │                    （对象句柄 + 函数指针 vtable）
     │
     │ ② Rust 正常调用
     ▼
self.preferences.get(key)
     │
     └──► ③ 通过 vtable 跳回你的 Swift/Kotlin 方法
```

分四步：

1. **`with_foreign` 让 UniFFI 生成 protocol（Swift）/ interface（Kotlin）**
2. **你实现它，创建实例**
3. **传给 Rust** —— 通常是某个 `#[uniffi::constructor]` 的参数
4. **UniFFI 把原生对象包装成 `Arc<dyn Trait>`**，内部持有句柄和函数指针表；Rust 调用时通过 vtable 跳回原生代码

### `async` 也能跨

```
Rust  async fn  ◄──► Swift  async throws  ◄──► Kotlin  suspend fun
```

UniFFI 有 future / continuation 桥接。不需要你做任何额外的事，正常写 `async` / `suspend` 即可。

### 装饰器可以套在 Rust 侧

因为边界是一个 trait，Rust 可以在你的实现外面再包一层，**平台完全无感**：

```rust
// core/gemstone/src/alien/mod.rs
pub(crate) fn coalescing_provider(provider: Arc<dyn AlienProvider>) -> Arc<dyn AlienProvider> {
    Arc::new(coalescing_provider::CoalescingAlienProvider::new(provider))
}
```

这个装饰器做请求合并——同一个 `(method, url, body)` 并发多次只真正发一次。**你的 Swift/Kotlin 代码一行都不用改。**

> ⭐ 这是把 FFI 边界定义成 **trait** 而不是一堆自由函数的最大好处。

---

## 6. 自己新增一个：完整步骤

以"让 Rust 用平台的生物识别"为例。

### ① Rust 侧定义 trait

```rust
// core/gemstone/src/xxx/biometrics.rs
use std::sync::Arc;
use async_trait::async_trait;

#[uniffi::export(with_foreign)]
#[async_trait]
pub trait GemBiometrics: Send + Sync + Debug {
    async fn authenticate(&self, reason: String) -> Result<bool, GemstoneError>;
}
```

记得在 `lib.rs` 里 `pub mod`。

### ② 找一个注入点

通常是给现有的 `#[uniffi::constructor]` 加参数：

```rust
#[uniffi::export]
impl GemGateway {
    #[uniffi::constructor]
    pub fn new(
        provider: Arc<dyn AlienProvider>,
        preferences: Arc<dyn GemPreferences>,
        biometrics: Arc<dyn GemBiometrics>,     // ← 新增
        api_url: String,
    ) -> Self { ... }
}
```

> 🔴 **给已有构造函数加参数是 breaking change**，两端都要改调用点。如果不想破坏兼容，可以加一个独立的 setter 或新构造函数。

### ③ 重新生成绑定

```bash
cd ios && just generate-stone                  # 🔴 iOS 必须手动跑
cd android && ./gradlew assembleGoogleDebug    # Android 自动带起来
```

### ④ 两端实现

```swift
final class LocalBiometrics: GemBiometrics, @unchecked Sendable {
    func authenticate(reason: String) async throws -> Bool {
        try await LAContext().evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: reason
        )
    }
}
```

```kotlin
class AndroidBiometrics(
    private val activityProvider: () -> FragmentActivity?,
) : GemBiometrics {
    override suspend fun authenticate(reason: String): Boolean =
        suspendCancellableCoroutine { cont ->
            // BiometricPrompt ...
        }
}
```

### ⑤ 装配

iOS 在构造 `GatewayService` 的地方传进去；Android 在 Hilt module 里 `@Provides`。

### ⑥ 验证

**别忘了 `tests/{ios,android}/GemTest` 这两个 demo 工程也要实现新接口**，否则它们编不过——这其实是好事，它们就是你的接口变更冒烟测试。

---

## 7. 类型映射

跨语言类型对照（写实现时最容易踩的）：

| Rust | Swift | Kotlin |
|---|---|---|
| `String` | `String` | `String` |
| `u16` | `UInt16` | `UShort` ← **要写 `200.toUShort()`** |
| `u64` | `UInt64` | `ULong` |
| `Vec<u8>` | `Data` | `ByteArray` |
| `Option<T>` | `T?` | `T?` |
| `HashMap<String, String>` | `[String: String]` | `Map<String, String>` |
| `Result<T, E>` | `throws -> T` | 直接抛异常 |
| `async fn` | `async throws` | `suspend fun` |
| `enum MyError` | `enum MyError: Error` | `class MyException` ← **后缀不同！** |
| `#[derive(uniffi::Record)]` | `struct` | `data class` |
| `#[derive(uniffi::Object)]` | `class`（引用类型） | `class` + `AutoCloseable` |

### 命名转换

Rust 的 `snake_case` → Swift/Kotlin 的 `lowerCamelCase`：

```
get_endpoint    → getEndpoint
deeplink_build_url → deeplinkBuildUrl
```

### 错误类型后缀

这是最容易忘的：

```swift
throw AlienError.RequestError(msg: "invalid url")        // iOS: Error
```
```kotlin
throw AlienException.RequestException("invalid url")     // Android: Exception
```

---

## 8. 六个约束

| # | 约束 | 说明 |
|:---:|---|---|
| **1** | **必须线程安全** | Rust bound 是 `Send + Sync`。Swift 用 `actor`（推荐）或 `@unchecked Sendable`（自己保证）；Kotlin 要保证类本身线程安全 |
| **2** | **`Debug` bound 不用你管** | `AlienProvider: Send + Sync + Debug` 里的 `Debug` **不需要你的 Swift/Kotlin 类做任何事** —— UniFFI 生成的包装层自己满足 |
| **3** | **只能抛声明的错误类型** | 抛别的类型会变成未定义行为或 panic 穿边界。Swift 里 `try` 一个非声明错误尤其危险 |
| **4** | **Rust 持有会 keep alive** | `Arc<dyn Trait>` 让你的原生对象一直活着。若你的实现又强引用了持有 Rust 对象的东西，就是**跨语言循环引用**，两边都不释放 |
| **5** | **接口要粗粒度** | 每次调用跨一次 FFI。`AlienProvider` 只有 2 个方法不是偶然——不要设计成几十个细粒度方法 |
| **6** | **两端行为必须一致** | 同一个接口写两遍，容易漂移（缓存 key 算法、header 过滤、错误映射）。**要有测试兜底** |

### 关于第 6 条

这是这套模式最真实的代价。举个仓库里的实例——`x-gem-cache-ttl` 这个 header：

- Rust 侧塞进 header 表示"这个请求可缓存"
- **两端都必须**：① 认得这个 header 才生成缓存 key；② 真正发包前把它 filter 掉

任何一端漏了第 ②步，服务端就会收到一个奇怪的私有 header。iOS 有 `NativeProviderCacheTests` 兜底，**新增接口时要想清楚谁来兜底**。

---

## 9. 什么该委托，什么不该

### 判断标准

> **凡是「平台已经做得比 Rust 好」的能力，委托出去；Rust 只保留纯计算和业务逻辑。**

| 该委托 | 理由 |
|---|---|
| HTTP / WebSocket | 平台网络栈有连接池、代理、VPN、抓包 |
| 安全存储（Keychain / Keystore） | 硬件支持，Rust 够不着 |
| 生物识别 | 平台 API |
| 推送 token | 平台 API |
| 系统语言 / 时区 | 平台 API |

| 不该委托 | 理由 |
|---|---|
| **业务逻辑** | 委托出去就要写两遍，必然漂移 |
| **数据库** | 见下 |
| **加解密 / 签名** | 见下 |

### 两个反例值得单独说

**① 数据库为什么不委托**

理论上可以定义一个 `GemDatabase` trait 让平台实现。但仓库**没这么做**——业务数据库（GRDB / Room）由平台**完全自己管**，Rust 根本不参与。

原因：跨 FFI 传结果集会让 Room 的 Flow / GRDB 的 ValueObservation 响应式查询全部失效，而那正是驱动 Compose / SwiftUI 自动刷新的机制。**委托的收益抵不过损失。**

**② 密钥存储为什么反过来——Rust 自己做文件 I/O**

`gem_keystore` **不委托**，直接写磁盘（`<base_dir>/<keystore_id>.json`）。平台只给一个目录路径。

原因：签名必须在 Rust 内完成（私钥不跨 FFI）。如果文件交给平台读，密文和明文就得跨边界，红线立刻破了。

> ⭐ **所以判断标准不是"平台能不能做"，而是"委托之后整体是不是更好"。** 网络委托出去更好，数据库和密钥留在原地更好。详见 [gem私钥管理.md](gem私钥管理.md)。

---

## 10. 调试

### Rust 调不到你的实现

| 症状 | 检查 |
|---|---|
| 编译期报找不到 protocol/interface | 绑定没重新生成。iOS 跑 `just generate-stone`（**最常见**） |
| 运行时崩溃在 checksum | 绑定和 `.a`/`.so` 版本错位，全量重新生成 |
| Android `UnsatisfiedLinkError` | `.so` 没打对应 ABI，或没 `System.loadLibrary("gemstone")` |

独立 demo 工程需要手动加载：

```kotlin
// core/gemstone/tests/android/GemTest/.../MainActivity.kt
class MainActivity : ComponentActivity() {
    init { System.loadLibrary("gemstone") }
}
```

主 App 里 UniFFI 生成的 Kotlin 会自己通过 JNA 加载，不用手写。

### 看 Rust 到底调了什么

在你的实现里直接打日志——**这是委托模式的一个额外好处**，Rust 的所有出站行为都会经过你的原生代码：

```swift
public func request(target: Gemstone.AlienTarget) async throws -> Gemstone.AlienResponse {
    print("==> handle request: \(target)")      // 示例工程里就是这么干的
    ...
    print("<== response size: \(data.count)")
}
```

网络请求还能直接用 Charles / Proxyman 抓——因为走的是 URLSession / OkHttp。

### Rust 侧单测怎么办

用 mock 实现替代平台：

```rust
// core/gemstone/src/testkit.rs
pub struct TestAlienProvider { ... }
impl AlienProvider for TestAlienProvider { ... }   // 返回固定响应，不起网络
```

集成测试则用真 reqwest 顶替：

```rust
// core/gemstone/src/alien/reqwest_provider.rs
#[cfg(feature = "reqwest_provider")]
impl AlienProvider for NativeProvider { ... }
```

> ⭐ **同一个 trait，三种实现（平台 / mock / reqwest）** —— 这也是把边界定义成 trait 的收益。

---

## 11. 文件索引

### Rust 侧

| 用途 | 路径 |
|---|---|
| `AlienProvider` 定义 | `core/gemstone/src/alien/provider.rs` |
| `GemPreferences` 定义 | `core/gemstone/src/gateway/preferences.rs` |
| 请求/响应结构 | `core/gemstone/src/alien/target.rs` |
| 装饰器示例（请求合并） | `core/gemstone/src/alien/coalescing_provider.rs` |
| 测试 mock | `core/gemstone/src/testkit.rs` |
| 测试用 reqwest 实现 | `core/gemstone/src/alien/reqwest_provider.rs` |
| 注入点 | `core/gemstone/src/gateway/mod.rs` |

### iOS

| 用途 | 路径 |
|---|---|
| 生产网络实现 | `ios/Packages/NativeProviderService/Sources/NativeProvider.swift` |
| 缓存 key 计算 | `ios/Packages/NativeProviderService/Sources/NativeProviderCache.swift` |
| Target → URLRequest | `ios/Packages/NativeProviderService/Sources/URLRequestSequence.swift` |
| 存储实现 | `ios/Packages/Blockchain/Sources/Gateway/GemstonePreferences.swift` · `GemstoneSecurePreferences.swift` |
| 装配 | `ios/Packages/Blockchain/Sources/Gateway/GatewayService.swift` |
| **最小示例** | `core/gemstone/tests/ios/GemTest/GemTest/Networking/Provider.swift` |

### Android

| 用途 | 路径 |
|---|---|
| 生产网络实现 | `android/data/services/remote-gem/.../gemapi/NativeProvider.kt` |
| 缓存 key 计算 | `android/data/services/remote-gem/.../gemapi/NativeProviderCache.kt` |
| 存储实现 | `android/data/repositories/.../config/SharedGemPreferences.kt` · `android/app/.../data/password/TinkGemPreferences.kt` |
| Hilt 装配 | `android/app/src/main/kotlin/com/gemwallet/android/di/GatewayModule.kt` |
| **最小示例** | `core/gemstone/tests/android/GemTest/app/.../NativeProvider.kt` |

---

*本文档由 AI 辅助整理，代码片段基于 commit `820c415579` 从源码摘录。接口变更后请以源码为准。*
