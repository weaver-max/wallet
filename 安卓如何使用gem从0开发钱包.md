# 安卓如何使用 gem 从 0 开发钱包

> 面向：不使用 gem 官方 Android 代码，从空工程开始接入 `gemstone` 的安卓开发者
> 目标：跑通「创建以太坊钱包 → 查余额 → 发交易」
> 相关：[rust回调原生端写好的接口(功能).md](rust回调原生端写好的接口\(功能\).md) · [gem私钥管理.md](gem私钥管理.md)
> 基线：类型签名均从 commit `820c415579` 的 Rust 源码实测摘录

---

## ⚠️ 先读这一段

本文 Kotlin 代码里的符号名，是按 UniFFI 命名规则从 Rust 源码推导的（`snake_case` → `lowerCamelCase`）。**生成的绑定文件在 gem 仓库里是 gitignore 的，本文写作时没有读到实物。**

字段名、类型、方法名都核对过 Rust 定义，但**落地前请务必以生成的 `gemstone.kt` 为准**：

```bash
cd core/gemstone && just bindgen-kotlin
# 产物：core/gemstone/generated/kotlin/uniffi/gemstone/gemstone.kt
```

没有源码的话，见 [§1](#1-向-core-团队要什么) 第 3 项——把这个文件要过来。

---

## 目录

1. [向 core 团队要什么](#1-向-core-团队要什么)
2. [一个必须先做对的决定](#2-一个必须先做对的决定)
3. [工程搭建](#3-工程搭建)
4. [四个核心文件](#4-四个核心文件)
5. [完整调用流程](#5-完整调用流程)
6. [API 参考（实测）](#6-api-参考实测)
7. [六个注意点](#7-六个注意点)
8. [已知缺口](#8-已知缺口)
9. [落地检查清单](#9-落地检查清单)

---

## 1. 向 core 团队要什么

### 必须要的 6 项

| # | 要什么 | 说明 |
|:---:|---|---|
| **1** | **AAR 制品 + Maven 坐标** | `com.gemwallet.gemstone:gemstone:<version>`。gem 的 `core/gemstone/android/` 已配好 `maven-publish`，他们只需把 `publishToMavenLocal` 改成推远端 registry |
| **2** | 🔴 **ABI 打全** | `arm64-v8a,armeabi-v7a,x86_64`。**漏了 x86_64 你在模拟器上会 `UnsatisfiedLinkError`**。让他们发布时设 `GEMSTONE_ANDROID_ABIS=arm64-v8a,armeabi-v7a,x86_64` |
| **3** | 🔴 **生成的 `gemstone.kt`** | 唯一权威的 API 参考，比任何文档都准。要么放进 sources jar，要么单独给你 |
| **4** | **接口稳定性承诺 + CHANGELOG** | `#[uniffi::export]` 签名变更 = 你直接编译不过。要求语义化版本，破坏性变更走 major，并提前一个版本标 deprecated |
| **5** | **`Chain` 字符串的确切取值** | `Chain` 在 FFI 里是 **String**，不是枚举。以太坊应为 `"ethereum"`——让他们书面确认，写错了只有运行期才报错 |
| **6** | **一个能跑的最小示例工程** | gem 仓库里现成的：`core/gemstone/tests/android/GemTest`。要过来比什么都省事 |

### 可以不要的

| 项 | 为什么 |
|---|---|
| **TypeShare 模型**（`com.wallet.core.primitives.*`） | 那是另一条独立管线的产物（纯数据类，不过 FFI）。**只做以太坊钱包用不上**，`uniffi.gemstone.*` 里的类型够了 |
| **Gem 后端 API 地址** | `GemGateway(...)` 构造要传 `apiUrl`，但它**只被 `getTransactionScan()`（交易风险扫描）使用**。不调那个方法的话传占位符即可 |

### 需要书面确认的 3 个问题

1. **AAR 里 JNA 是 `api` 还是 `implementation`？** —— gem 源码里是 `api("net.java.dev.jna:jna:5.18.1@aar")`，会传递给你。确认发布版没改。
2. **`minSdk` 是多少？** —— gem 的模块是 `minSdk = 28`，你的 App 不能低于它。
3. **能否导出 `verify` 接口？** —— 目前没导出，见 [§8](#8-已知缺口)。如果你需要"校验钱包文件可用"，把这条加进清单。

---

## 2. 一个必须先做对的决定

`GemImportType` 有三个变体。做以太坊钱包看起来 `SinglePhrase` 更"对"，**但别用**。

```rust
pub enum GemImportType {
    MulticoinPhrase { words: Vec<String>, chains: Vec<Chain> },
    SinglePhrase    { words: Vec<String>, chain: Chain },
    PrivateKey      { value: String, chain: Chain },
}
```

| 选择 | 产生的 walletId | 以后想加链 |
|---|---|---|
| `SinglePhrase(words, "ethereum")` | `single_ethereum_0x9858...` | 🔴 **walletId 会变** → keystoreId 变 → 密钥文件找不到 → **用户钱包"消失"** |
| `MulticoinPhrase(words, ["ethereum"])` | `multicoin_0x9858...` | ✅ 不变，调 `addAccounts` 加链即可 |

原因在 Rust 侧——`multicoin` 类型的 walletId **永远从以太坊地址算**，跟你启用几条链无关：

```rust
// core/gemstone/src/keystore/keystore.rs:40
MulticoinPhrase { words, chains } =>
    derive_mnemonic_wallet(words, chains, Multicoin, Chain::Ethereum)?
//                                                   ↑ 固定用 ETH 地址算 walletId
```

而且内部会**强制补上 Ethereum** 用于算 id，算完再从返回的 accounts 里过滤掉：

```rust
// keystore.rs:216
let mut chains = requested_chains.clone();
if !chains.contains(&wallet_id_chain) { chains.push(wallet_id_chain); }
```

> ⭐ **今天传 `chains = ["ethereum"]`，明天传 `["ethereum", "polygon", "bsc"]`，walletId 完全一样。**
>
> 这一步选错，未来扩链要做一次痛苦的存量数据迁移。**只做以太坊也用 `MulticoinPhrase`。**

---

## 3. 工程搭建

**你不需要安装 Rust、NDK、cargo-ndk。** AAR 里已经包含编译好的 `.so` 和生成的 Kotlin 绑定。

### `settings.gradle.kts`

```kotlin
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        maven {                                          // core 团队的 registry
            url = uri("https://maven.pkg.github.com/<org>/<repo>")
            credentials {
                username = providers.gradleProperty("gpr.user").get()
                password = providers.gradleProperty("gpr.token").get()
            }
        }
    }
}
```

### `app/build.gradle.kts`

```kotlin
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.example.ethwallet"
    compileSdk = 36

    defaultConfig {
        minSdk = 28                                      // 🔴 不能低于 gemstone 的 minSdk
        targetSdk = 36
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
}

dependencies {
    implementation("com.gemwallet.gemstone:gemstone:2.114.10")   // JNA 会传递进来
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("androidx.security:security-crypto:1.1.0")    // 存 keystore 密码
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
}
```

> 主 App 中 UniFFI 生成的 Kotlin 会通过 JNA 自动加载 `.so`，**不需要手写 `System.loadLibrary`**。（gem 的独立 demo 工程里有这行，那是因为它没走 AAR。）

---

## 4. 四个核心文件

### 4.1 `EthProvider.kt` —— 实现 Rust 要的网络接口

**这是必须实现的第一个东西。** Rust 不发 HTTP，它回调你。

```kotlin
package com.example.ethwallet

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import uniffi.gemstone.*
import java.io.IOException

private const val CACHE_TTL_HEADER = "x-gem-cache-ttl"

class EthProvider(
    private val rpcUrl: String = "https://ethereum.publicnode.com",
    private val client: OkHttpClient = OkHttpClient(),
) : AlienProvider {

    // Chain 在 FFI 里就是 String
    override fun getEndpoint(chain: Chain): String {
        if (chain != "ethereum") {
            throw AlienException.RequestException("unsupported chain: $chain")
        }
        return rpcUrl
    }

    override suspend fun request(target: AlienTarget): AlienResponse = withContext(Dispatchers.IO) {
        val builder = Request.Builder()
            .url(target.url)
            .method(alienMethodToString(target.method), target.body?.toRequestBody())

        target.headers?.forEach { (k, v) ->
            if (k != CACHE_TTL_HEADER) builder.addHeader(k, v)   // 🔴 私有 header 不能发给服务端
        }

        try {
            client.newCall(builder.build()).execute().use { resp ->
                AlienResponse(resp.code.toUShort(), resp.body.bytes())   // 注意 UShort
            }
        } catch (e: IOException) {
            throw AlienException.RequestException(e.message ?: "network error")
        }
    }
}
```

> **关于 `x-gem-cache-ttl`**：Rust 用这个 header 告诉你"该请求可缓存"。它是**跨 FFI 的控制通道，不是给服务端看的**，发包前必须摘掉。这个 demo 不做缓存，直接过滤即可；要做缓存的话，用 `(method, url, body)` 的哈希当 key。

### 4.2 `SimplePreferences.kt` —— 实现 Rust 要的存储接口

```kotlin
package com.example.ethwallet

import android.content.SharedPreferences
import androidx.core.content.edit
import uniffi.gemstone.GemPreferences

class SimplePreferences(
    private val prefs: SharedPreferences,
) : GemPreferences {
    override fun get(key: String): String? = prefs.getString(key, null)
    override fun set(key: String, value: String) { prefs.edit(commit = true) { putString(key, value) } }
    override fun remove(key: String) { prefs.edit(commit = true) { remove(key) } }
}
```

Rust 用它存自己的一点内部状态（节点配置、鉴权 token 等），数据量很小。

### 4.3 `WalletManager.kt` —— 创建钱包

```kotlin
package com.example.ethwallet

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import uniffi.gemstone.*
import java.security.SecureRandom

const val CHAIN_ETH = "ethereum"

class WalletManager(context: Context) {

    val baseDir: String = context.filesDir.resolve("keystore")
        .apply { mkdirs() }.absolutePath

    // keystore 密码：256-bit 随机设备密钥，存在 Android Keystore 加密的 prefs 里
    private val securePrefs = EncryptedSharedPreferences.create(
        context, "wallet_secrets",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )

    /** 生成 12 词助记词 */
    fun generateMnemonic(): List<String> = GemMnemonic().generate(12u)

    /** 校验助记词（输入页实时校验用） */
    fun isValidMnemonic(words: List<String>): Boolean = GemMnemonic().isValid(words)
    fun suggestWords(prefix: String): List<String> = GemMnemonic().suggestWords(prefix, 5u)
    fun findInvalidWords(words: List<String>): List<String> = GemMnemonic().findInvalidWords(words)

    /** 导入前预览地址 —— 不落盘、不需要密码 */
    fun preview(words: List<String>): List<String> =
        GemKeystore(baseDir).use { keystore ->
            keystore.previewImport(GemImportType.MulticoinPhrase(words, listOf(CHAIN_ETH)))
                .accounts.map { it.address }
        }

    /** 创建 / 导入助记词钱包 */
    fun createWallet(words: List<String>): WalletInfo = withPassword { password ->
        GemKeystore(baseDir).use { keystore ->
            val stored = keystore.createStore(
                // 🔴 用 MulticoinPhrase 而非 SinglePhrase —— 见 §2
                GemImportType.MulticoinPhrase(words, listOf(CHAIN_ETH)),
                password,
            )
            WalletInfo(
                walletId   = stored.walletId,       // "multicoin_0x9858Ef..."
                keystoreId = stored.keystoreId,     // "f32a9e95-4904-533b-..."
                address    = stored.accounts.first { it.chain == CHAIN_ETH }.address,
            )
        }
    }

    /** 导入私钥 */
    fun importPrivateKey(hex: String): WalletInfo = withPassword { password ->
        GemKeystore(baseDir).use { keystore ->
            val stored = keystore.createStore(GemImportType.PrivateKey(hex, CHAIN_ETH), password)
            WalletInfo(stored.walletId, stored.keystoreId, stored.accounts.first().address)
        }
    }

    /** 删除钱包 */
    fun deleteWallet(keystoreId: String): Boolean =
        GemKeystore(baseDir).use { it.delete(keystoreId) }

    /** 🔴 统一的密码取用 + 擦除包装，参考 gem 自己的 withGemKeystore */
    fun <R> withPassword(block: (ByteArray) -> R): R {
        val password = getOrCreatePassword()
        return try {
            block(password)
        } finally {
            password.fill(0)
        }
    }

    private fun getOrCreatePassword(): ByteArray {
        securePrefs.getString("keystore_password", null)?.let { return it.hexToByteArray() }
        val bytes = ByteArray(32).also { SecureRandom().nextBytes(it) }
        securePrefs.edit().putString("keystore_password", bytes.toHexString()).apply()
        return bytes
    }
}

data class WalletInfo(
    val walletId: String,
    val keystoreId: String,
    val address: String,
)
```

### 4.4 `EthService.kt` —— 查余额 / 发交易

```kotlin
package com.example.ethwallet

import uniffi.gemstone.*

class EthService(
    provider: AlienProvider,
    prefs: GemPreferences,
    securePrefs: GemPreferences,
    private val walletManager: WalletManager,
) {
    private val gateway = GemGateway(
        provider,
        preferences = prefs,
        securePreferences = securePrefs,
        apiUrl = "https://api.gemwallet.com",   // 不调 getTransactionScan 的话占位符即可
    )

    private val ethAsset = GemAsset(
        id = CHAIN_ETH,
        chain = CHAIN_ETH,
        tokenId = null,
        name = "Ethereum",
        symbol = "ETH",
        decimals = 18,
        assetType = GemAssetType.NATIVE,
    )

    /** 查 ETH 余额（返回 wei 字符串） */
    suspend fun getBalance(address: String): String =
        gateway.getBalanceCoin(CHAIN_ETH, address).balance.available

    /** 查 ERC-20 余额 */
    suspend fun getTokenBalances(address: String, tokenIds: List<String>): List<GemAssetBalance> =
        gateway.getBalanceTokens(CHAIN_ETH, address, tokenIds)

    /** 查代币元数据（name / symbol / decimals） */
    suspend fun getTokenData(contractAddress: String): GemAsset =
        gateway.getTokenData(CHAIN_ETH, contractAddress)

    /** 取费率档位，给用户选（慢 / 普通 / 快） */
    suspend fun getFeeRates(): List<GemFeeRate> =
        gateway.getFeeRates(CHAIN_ETH, GemTransactionInputType.Transfer(ethAsset))

    /** 发一笔 ETH 转账，返回交易 hash */
    suspend fun sendEth(
        wallet: WalletInfo,
        to: String,
        amountWei: String,
        feeRate: GemFeeRate,
    ): String {
        val inputType = GemTransactionInputType.Transfer(ethAsset)

        // ① preload —— 从链上取 nonce + chainId
        val metadata = gateway.getTransactionPreload(
            CHAIN_ETH,
            GemTransactionPreloadInput(
                inputType = inputType,
                senderAddress = wallet.address,
                destinationAddress = to,
            ),
        )

        // ② load —— 估 gasLimit、算总费用
        val loadInput = GemTransactionLoadInput(
            inputType = inputType,
            senderAddress = wallet.address,
            destinationAddress = to,
            value = amountWei,
            gasPrice = feeRate.gasPriceType,
            memo = null,
            isMaxValue = false,
            metadata = metadata,               // ← nonce 在这里，原样透传给签名
        )
        val loadData = gateway.getTransactionLoad(CHAIN_ETH, loadInput)

        // ③ 签名 —— 私钥不出 Rust，只传 keystoreId + 密码
        val signed = walletManager.withPassword { password ->
            GemKeystore(walletManager.baseDir).use { keystore ->
                keystore.sign(
                    wallet.keystoreId,
                    CHAIN_ETH,
                    GemSignerInput(loadInput, loadData.fee),
                    password,
                )
            }
        }

        // ④ 广播
        return gateway.transactionBroadcast(
            CHAIN_ETH,
            signed.first().data,
            GemBroadcastOptions(skipPreflight = false),
        )
    }

    /** 查交易状态（轮询用） */
    suspend fun getTransactionStatus(request: GemTransactionStateRequest): GemTransactionUpdate =
        gateway.getTransactionStatus(CHAIN_ETH, request)
}
```

### 装配

```kotlin
val walletManager = WalletManager(context)
val provider = EthProvider(rpcUrl = "https://ethereum.publicnode.com")
val prefs = SimplePreferences(context.getSharedPreferences("gateway", Context.MODE_PRIVATE))
val securePrefs = SimplePreferences(context.getSharedPreferences("gateway_secure", Context.MODE_PRIVATE))

val ethService = EthService(provider, prefs, securePrefs, walletManager)
```

---

## 5. 完整调用流程

```
你写的两个实现 ──注入──┐
  EthProvider          │
  SimplePreferences    ▼
              ┌──────────────────────────────┐
              │  GemGateway / GemKeystore    │  ← Rust (AAR 里的 .so)
              └──────────────────────────────┘
                       │
  ┌────────────────────┼────────────────────┐
  ▼                    ▼                    ▼
创建钱包              查余额                发交易
  │                    │                    │
GemMnemonic()        getBalanceCoin       getTransactionPreload  ← 拿 nonce/chainId
 .generate(12)         ↓                    ↓
  ↓                  balance.available    getFeeRates            ← 费率档位给用户选
createStore(                                ↓
  MulticoinPhrase)                        getTransactionLoad     ← 估 gas、算费用
  ↓                                         ↓
{ walletId,                               keystore.sign          ← 🔴 私钥不出 Rust
  keystoreId,                               ↓
  accounts[0].address }                   transactionBroadcast   ← 返回 hash

               Rust 需要发 HTTP 时 ──回调──► 你的 EthProvider
```

**私钥全程不出 Rust。** 你的代码只接触 `keystoreId`（一个 UUID 字符串）和 `password`（字节数组）。

---

## 6. API 参考（实测）

以下类型定义均从 Rust 源码摘录，Kotlin 侧字段名按 UniFFI 规则转 `lowerCamelCase`。

### `GemKeystore`（UniFFI Object，用 `.use { }`）

```
GemKeystore(baseDir: String)

previewImport(import: GemImportType) -> GemWalletImport        // 不落盘、不要密码
createStore(import: GemImportType, password: ByteArray) -> GemStoredWallet
addAccounts(keystoreId, password, chains: List<Chain>) -> List<GemKeystoreAccount>
exportRecoveryPhrase(keystoreId, password) -> List<String>     // 仅"查看助记词"场景
exportPrivateKey(keystoreId, chain, password) -> String        // 仅"导出私钥"场景
delete(keystoreId) -> Boolean
sign(keystoreId, chain, input: GemSignerInput, password) -> List<GemSignedTransaction>
signAuth(keystoreId, chain, hash: ByteArray, password) -> String
migrateV3(v3Path, v3Password, newPassword, walletId)           // WalletCore v3 迁移，你用不上

// 顶层函数
keystoreIdForWallet(walletId: String) -> String
```

### `GemGateway`（构造要 4 个参数）

```
GemGateway(
    provider: AlienProvider,
    preferences: GemPreferences,
    securePreferences: GemPreferences,
    apiUrl: String,
)

// 余额
getBalanceCoin(chain, address) -> GemAssetBalance
getBalanceTokens(chain, address, tokenIds: List<String>) -> List<GemAssetBalance>

// 代币
getTokenData(chain, tokenId) -> GemAsset
getIsTokenAddress(chain, tokenId) -> Boolean

// 交易
getTransactionPreload(chain, input: GemTransactionPreloadInput) -> GemTransactionLoadMetadata
getFeeRates(chain, input: GemTransactionInputType) -> List<GemFeeRate>        // ⚠️ 是 getFeeRates
getTransactionLoad(chain, input: GemTransactionLoadInput) -> GemTransactionData
transactionBroadcast(chain, data: String, options: GemBroadcastOptions) -> String
getTransactionStatus(chain, request) -> GemTransactionUpdate

// 链信息
getChainId(chain) -> String
getBlockNumber(chain) -> ULong
getNodeStatus(chain, url) -> GemNodeStatus
```

### 数据类型

```kotlin
// 导入类型
sealed class GemImportType {
    MulticoinPhrase(words: List<String>, chains: List<Chain>)
    SinglePhrase(words: List<String>, chain: Chain)
    PrivateKey(value: String, chain: Chain)
}

// 创建结果
GemStoredWallet(walletId: String, walletType: GemWalletType, keystoreId: String,
                accounts: List<GemKeystoreAccount>)

// 预览结果（无 keystoreId，因为还没落盘）
GemWalletImport(walletId: String, walletType: GemWalletType, accounts: List<GemKeystoreAccount>)

GemKeystoreAccount(chain: Chain, address: String, derivationPath: String, publicKey: String?)

// 资产
GemAsset(id: AssetId, chain: Chain, tokenId: String?, name: String,
         symbol: String, decimals: Int, assetType: GemAssetType)

enum GemAssetType { NATIVE, ERC20, BEP20, SPL, SPL2022, TRC20, TIP20, TOKEN,
                    IBC, JETTON, SYNTH, ASA, PERPETUAL, SPOT }

// 余额
GemAssetBalance(assetId: AssetId, balance: GemBalance, isActive: Boolean)
GemBalance(available, frozen, locked, staked, pending, ...)   // 都是 String（BigUint）

// 交易
GemTransactionPreloadInput(inputType, senderAddress: String, destinationAddress: String)

GemTransactionLoadInput(inputType, senderAddress, destinationAddress, value: String,
                        gasPrice: GemGasPriceType, memo: String?, isMaxValue: Boolean,
                        metadata: GemTransactionLoadMetadata)

GemTransactionData(fee: GemTransactionLoadFee, metadata: GemTransactionLoadMetadata)
GemTransactionLoadFee(fee: String, gasPriceType: GemGasPriceType, gasLimit: String,
                      options: GemFeeOptions, feeAsset: AssetId)

GemSignerInput(input: GemTransactionLoadInput, fee: GemTransactionLoadFee)
GemSignedTransaction(data: String, transactionType: TransactionType)

GemFeeRate(priority: String, gasPriceType: GemGasPriceType)

sealed class GemGasPriceType {
    Regular(gasPrice: String)
    Eip1559(gasPrice: String, priorityFee: String)             // ← EVM 用这个
    Solana(gasPrice: String, priorityFee: String, unitPrice: String)
}

GemBroadcastOptions(skipPreflight: Boolean)

// 交易类型（以太坊转账用 Transfer）
sealed class GemTransactionInputType {
    Transfer(asset: GemAsset)
    Deposit(asset: GemAsset)
    Swap(fromAsset, toAsset, swapData)
    Stake(asset, stakeType)
    TokenApprove(asset, approvalData)
    ...
}

// nonce 在这里
sealed class GemTransactionLoadMetadata {
    Evm(nonce: ULong, chainId: ULong, contractCall: ...)
    ...
}
```

### 助记词工具

```kotlin
GemMnemonic()
  .generate(wordCount: UByte) -> List<String>      // 12u / 15u / 18u / 21u / 24u
  .isValid(words: List<String>) -> Boolean
  .isValidWord(word: String) -> Boolean
  .suggestWords(prefix: String, limit: UInt?) -> List<String>   // 输入联想
  .findInvalidWords(words: List<String>) -> List<String>        // 高亮错词
```

熵源是 OS CSPRNG（`getrandom(2)`），不是用户态 PRNG。

### 反向回调接口（你要实现的）

```kotlin
interface AlienProvider {
    fun getEndpoint(chain: Chain): String
    suspend fun request(target: AlienTarget): AlienResponse
}

interface GemPreferences {
    fun get(key: String): String?
    fun set(key: String, value: String)
    fun remove(key: String)
}

AlienTarget(url: String, method: AlienHttpMethod,
            headers: Map<String, String>?, body: ByteArray?)
AlienResponse(status: UShort?, data: ByteArray)     // ← 构造函数

// 工具函数
alienMethodToString(method: AlienHttpMethod) -> String
```

---

## 7. 六个注意点

| # | 点 | 说明 |
|:---:|---|---|
| **1** | 🔴 **用 `MulticoinPhrase` 不用 `SinglePhrase`** | 见 §2。选错未来扩链要做存量迁移 |
| **2** | 🔴 **password 用完立刻 `fill(0)`** | 用 `withPassword { }` 这类包装强制执行，别散落在业务代码里 |
| **3** | **`Chain` 是 String 不是枚举** | `uniffi::custom_type!(Chain, String)`，传 `"ethereum"`。写错只有运行期报错 |
| **4** | **HTTP status 是 `UShort`** | `resp.code.toUShort()`，因为 Rust 侧是 `u16` |
| **5** | **错误类是 `Exception` 后缀** | Kotlin 是 `AlienException` / `GemstoneException`（Swift 才是 `Error`）。**只能抛接口声明的异常类型**，抛别的可能 panic 穿边界 |
| **6** | **`GemKeystore` 是 UniFFI Object** | 用 `.use { }` 确保释放。每次新建实例是安全的——Rust 侧文件锁是**进程级 static**，不是 per-instance |

### 关于第 6 点

gem 的 Android 生产代码就是每次调用新建实例：

```kotlin
GemKeystore(baseDir).use { keystore -> ... }
```

而 iOS 是共享单例。两种都对，因为 Rust 侧的锁是：

```rust
// core/crates/gem_keystore/src/storage/queue.rs
static QUEUE: OnceLock<Mutex<()>> = OnceLock::new();
```

Android instrumented 测试 `GemKeystoreConcurrencyTest` 用 8 线程、独立实例并发 create/read/delete 验证过。

---

## 8. 已知缺口

### 没有 `verify` 接口

Rust 的 `FileKeystore` 有这些方法，但**都没导出到 UniFFI**：

```rust
verify(keystore_id, password)    get_meta(keystore_id)
list()                           change_password(...)
```

所以你没法直接问"这个 keystore 文件能用当前密码解开吗"。

**变通办法：**

```kotlin
// 助记词钱包：addAccounts 内部会真解密，还顺带返回地址供核对
keystore.addAccounts(keystoreId, password, listOf(CHAIN_ETH))

// 私钥钱包：addAccounts 会显式报错 "does not support private-key wallets"
//          改用 signAuth 签一个 dummy hash
keystore.signAuth(keystoreId, CHAIN_ETH, ByteArray(32), password)
```

> ⚠️ **不要用 `exportRecoveryPhrase` 做验证** —— 它会把助记词明文拉回 App 内存，为一次校验付这个代价不值。

如果你需要"校验钱包可用"这个功能，**把导出 `verify` 加进 §1 的清单**，对 core 团队是几行代码的事。

### 交易加速 / 取消没有

gem 目前不支持。要做的话需要：本地记录原交易的 nonce 和 gasPrice → 用同 nonce + 提价（EIP-1559 要求 `maxFeePerGas` 和 `maxPriorityFeePerGas` **都** ≥ 原值 ×1.1）重发。

好消息是 Rust 管线已经支持——`GemTransactionLoadInput.metadata` 里的 nonce 是**调用方传入并原样透传**到签名的，所以你把旧 nonce 填回去就能重发。

### nonce 是无状态的

gem 每次发交易都现查 `eth_getTransactionCount(addr, **latest**)`，**本地不存 nonce**。

- 好处：换设备、重装、多端同助记词都不会出问题
- 代价：**连续快速发两笔独立交易会撞 nonce**（第二笔可能被拒 `already known` / `replacement underpriced`）

如果你的产品允许连发，需要自己在 UI 层加守卫（有 pending 交易时禁用发送按钮）。

---

## 9. 落地检查清单

### 接入前

- [ ] 拿到 AAR 的 Maven 坐标，能从 registry 拉下来
- [ ] 确认 AAR 包含 `x86_64`（否则模拟器跑不了）—— 解压 AAR 看 `jni/` 目录
- [ ] 拿到生成的 `gemstone.kt`，**逐个核对本文用到的类型和方法名**
- [ ] 书面确认 `Chain` 的以太坊取值
- [ ] 确认 `minSdk` 要求

### 第一个里程碑（半天）

- [ ] 空工程能编过，`libVersion()` 能返回版本号 —— 证明 `.so` 加载成功
- [ ] `GemMnemonic().generate(12u)` 能出 12 个词
- [ ] `previewImport` 能派生出地址 —— 证明 keystore 派生链路通
- [ ] `EthProvider` 实现后，`getBalanceCoin` 能查到真实余额 —— 证明反向回调通

> ⭐ **前四项跑通，剩下的就是体力活。** 建议先做一个只有几个按钮的调试页面验证这四步，再开始搭正式 UI。

### 上线前

- [ ] 所有 password 路径都有 `fill(0)`
- [ ] 密钥相关代码路径没有任何 log / 崩溃上报快照
- [ ] 助记词页面禁用截图（`FLAG_SECURE`）
- [ ] `AndroidManifest.xml` 的 `allowBackup` 设为 `false`，或明确排除 keystore 目录
- [ ] 真机 + 模拟器（x86_64）都验证过
- [ ] 签名/交易构造路径经过人工 Review

---

*本文档由 AI 辅助整理，类型签名基于 commit `820c415579` 的 Rust 源码实测摘录；Kotlin 符号名按 UniFFI 规则推导，以生成的 `gemstone.kt` 为准。*
