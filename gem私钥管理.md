# gem 私钥管理

> 面向：需要理解或改动 gem 密钥存储、签名、迁移路径的工程师
> 内容：私钥存在哪、怎么寻址、怎么加密、怎么签名、边界在哪
> 基线：仓库 commit `820c415579`；`core/docs/KEYSTORE_V4.md` 标注的实现核对日期为 2026-07-04，本文所有结论均已对照当前代码复核

---

## 目录

1. [一句话模型](#1-一句话模型)
2. [三层分工：谁存什么](#2-三层分工谁存什么)
3. [寻址链路：从地址找到私钥文件](#3-寻址链路从地址找到私钥文件)
4. [walletId 是怎么来的](#4-walletid-是怎么来的)
5. [v4 文件格式](#5-v4-文件格式)
6. [磁盘安全](#6-磁盘安全)
7. [FFI 表面与红线](#7-ffi-表面与红线)
8. [平台侧实现](#8-平台侧实现)
9. [密码边界](#9-密码边界)
10. [v3 迁移](#10-v3-迁移)
11. [风险清单](#11-风险清单)
12. [关键文件索引](#12-关键文件索引)

---

## 1. 一句话模型

**一个钱包一个加密文件，文件名从钱包 id 确定性派生；解密和签名全在 Rust 内部完成，私钥不跨 FFI 边界。**

```
<base_dir>/<keystore_id>.json      ← 密文，Rust 直接写磁盘
```

这是整个 gem 架构里**唯一一处 Rust 自己做文件 I/O 的地方**。网络请求、业务数据库都委托给平台（见 `AlienProvider` / `GemPreferences`），密钥反过来——Rust 全程管到磁盘。

---

## 2. 三层分工：谁存什么

| 存什么 | 谁存 | 在哪 |
|---|---|---|
| **加密后的密钥文件** | 🔴 **Rust 直接写磁盘** | `<base_dir>/<keystore_id>.json` |
| **解密用的密码** | 平台安全存储 | iOS Keychain / Android Tink + Android Keystore |
| 钱包元数据（名字、排序、当前钱包、账户行、地址、公钥） | 平台数据库 | GRDB / Room |

`core/docs/KEYSTORE_V4.md` 的原文表述：

> `gem_keystore` must stay secret-storage-only. It must not depend on app primitives, chain crates, signer, or account derivation.
> Mobile apps own wallet name, order, current wallet, account rows, duplicate checks, subscriptions, UI, and secure password storage.

### crate 职责

| crate | 负责 |
|---|---|
| `gem_keystore` | BIP-39 助记词、v4 文件格式、v3 WalletCore 读取器、原始密钥存储 |
| `gem_derivation` | 钱包 id 派生、账户派生、私钥导入校验、地址生成、账户公钥 |
| `gem_auth` | 设备鉴权头格式（Ed25519 签名与验证），客户端与后端共用 |
| `gemstone` | UniFFI 边界层 + **签名路由**（`GemChainSigner`），转发到各链 `gem_*` signer crate |

> ⭐ **签名调度在 `gemstone`，不在 `gem_keystore`。** 这条分层不是洁癖——它保证了 `gem_keystore` 不依赖任何链实现，可以被独立审计。

### 为什么密钥要破例，自己做文件 I/O

1. **签名必须在 Rust 内完成** —— 如果文件交给平台读，密文和明文就得跨 FFI 传，红线立刻破了
2. **原子写 + 权限 + 并发串行化的语义太容易写错** —— 让 iOS 和 Android 各实现一遍必然漂移，而漂移在密钥文件上意味着丢钱
3. **加解密逻辑本来就在 Rust** —— 让平台只当"字节搬运工"，反而凭空多一次明文/密文过界的机会

原则的精确表述：

> **凡是"读出来就等于泄漏"的东西，Rust 全程自己管到磁盘；平台只提供不含机密的设施（目录路径），外加一样它确实更擅长保管的东西（密码，交给硬件支持的安全存储）。**

---

## 3. 寻址链路：从地址找到私钥文件

v4 文件里**没有地址、没有公钥、没有派生路径、没有钱包名**，所以反查不可能从文件里做。

```
地址 ──①平台 DB 查──► walletId ──②调 Rust 算──► keystoreId ──③拼路径──► 文件
```

### ① 地址 → walletId：只能查平台数据库

两端各有一张 accounts 表：

```kotlin
// android/data/services/store/.../entities/DbAccount.kt
@Entity(tableName = "accounts")
data class DbAccount(
    @ColumnInfo(name = "wallet_id") val walletId: String,
    @ColumnInfo(name = "derivation_path") val derivationPath: String,
    val address: String,
    val chain: Chain,
    val extendedPublicKey: String?,
)
```

```swift
// ios/Packages/Store/.../AccountRecord.swift
static let databaseTableName: String = "wallets_accounts"
// 列：walletId · chain · address · index · extendedPublicKey · derivationPath
```

**这一跳算不出来，只能查表。** 原因见第 4 节：多币种钱包的 walletId 只编码了以太坊那一个地址，从 Solana / BTC 地址推不出来。

### ② walletId → keystoreId：确定性 UUID v5

两端都不自己实现，走同一个 FFI：

```swift
// ios/Packages/GemstonePrimitives/Sources/Extensions/Wallet+GemstonePrimitives.swift:8
var keystoreId: String { keystoreIdForWallet(walletId: id.id) }
```
```kotlin
// android/gemcore/src/main/kotlin/com/gemwallet/android/ext/Wallet.kt:30
val Wallet.keystoreId: String get() = uniffi.gemstone.keystoreIdForWallet(id.id)
```

Rust 实现：

```rust
// core/crates/gem_keystore/src/id.rs
const KEYSTORE_NAMESPACE: Uuid = Uuid::from_bytes(*b"GemKeystoreV4\0\0\0");

pub fn from_wallet_id(wallet_id: &str) -> Self {
    Self(Uuid::new_v5(&KEYSTORE_NAMESPACE, wallet_id.as_bytes()).to_string())
}
```

单测把映射钉死：

```rust
let wallet_id = "multicoin_0x5a8f70b44aFa00Cb70615D9c9CCb9A24933ED2D3";
assert_eq!(KeystoreId::from_wallet_id(wallet_id).as_str(), "f32a9e95-4904-533b-95fe-ebbe6cfb7554");
```

### ③ keystoreId → 路径

```
<base_dir>/<keystore_id>.json
```

### keystoreId 不入库，永远现算

`KEYSTORE_V4.md` 明确规定：

> `Wallet.keystoreId` is always computed from `wallet.id.id`.

好处是消灭了一整类脏数据——不存在"DB 里记的 id 和磁盘上的文件名对不上"。iOS 的 `Wallet.externalId` 只留给 v3 遗留文件定位，v4 钱包应为 `nil`。

### 后果：平台 DB 是这套映射的唯一来源

DB 丢了，文件和密码都还在，但不知道哪个文件是哪个钱包。

理论上可以暴力恢复（遍历目录 → 逐个解密 → 重新派生地址 → 比对链上余额），但**代码里没有这条路径**。DB 和 keystore 文件在同一个 app 沙盒里，一起丢的概率远大于单独丢一个。

---

## 4. walletId 是怎么来的

**不是随机生成的，是从助记词/私钥派生出的地址算出来的——纯确定性。**

```rust
// core/crates/gem_derivation/src/wallet_id.rs
pub fn derive_wallet_id_from_account(account: &Account, wallet_type: WalletType) -> Result<WalletId, _> {
    match wallet_type {
        WalletType::Multicoin  => Ok(WalletId::Multicoin(account.address.clone())),
        WalletType::Single     => Ok(WalletId::Single(account.chain, account.address.clone())),
        WalletType::PrivateKey => Ok(WalletId::PrivateKey(account.chain, account.address.clone())),
        WalletType::View       => Err(unsupported("view wallet id is app-only")),
    }
}
```

### 字符串格式（`_` 分隔）

| 类型 | 格式 | 例子 |
|---|---|---|
| 多币种 | `multicoin_{地址}` | `multicoin_0x9858EfFD232B4033E47d90003D41EC34EcaEda94` |
| 单链 | `single_{链}_{地址}` | `single_solana_HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk` |
| 私钥导入 | `privateKey_{链}_{地址}` | `privateKey_ethereum_0x4ce31c0b2114abe61Ac123E1E6254E961C18D10B` |
| 观察钱包 | `view_{链}_{地址}` | 只在 App 层用，Rust 侧显式拒绝派生 |

### 多币种固定用以太坊地址

```rust
// core/gemstone/src/keystore/keystore.rs:208
fn derive_mnemonic_wallet(
    words: Vec<String>,
    requested_chains: Vec<Chain>,
    wallet_type: WalletType,
    wallet_id_chain: Chain,               // ← 用哪条链的地址当 id
) -> Result<(WalletId, Vec<Account>, Zeroizing<String>), GemstoneError> {
    let mut chains = requested_chains.clone();
    if !chains.contains(&wallet_id_chain) {
        chains.push(wallet_id_chain);     // ← 用户没选也强制派生出来算 id
    }
    let derived_accounts = derive_accounts_from_mnemonic(&phrase, chains)?;
    let wallet_id_account = derived_accounts.iter().find(|a| a.chain == wallet_id_chain)?;
    let wallet_id = derive_wallet_id_from_account(wallet_id_account, wallet_type)?;
    let accounts = derived_accounts.into_iter().filter(|a| requested_chains.contains(&a.chain)).collect();
    //                                          ↑ 算 id 用的账户如果用户没请求，不进最终账户列表
    Ok((wallet_id, accounts, phrase))
}
```

调用处写死：

```rust
// keystore.rs:40 / :64
MulticoinPhrase { words, chains } => derive_mnemonic_wallet(words, chains, Multicoin, Chain::Ethereum)?
SinglePhrase { words, chain }     => derive_mnemonic_wallet(words, vec![chain], Single, chain)?
```

> ⭐ 那句 `if !chains.contains(&wallet_id_chain) { chains.push(...) }` 的意思是：**哪怕用户导入多币种钱包时一条 EVM 链都没勾，Rust 也会临时派生一个 ETH 账户出来算 walletId，算完再从账户列表里过滤掉。** 这保证 walletId 口径永远一致。

### 完整链路

```
助记词 "abandon abandon ... about"
    │  BIP-39 → seed → BIP-32 派生 m/44'/60'/0'/0/0
    ▼
ETH 地址 0x9858EfFD232B4033E47d90003D41EC34EcaEda94
    │  derive_wallet_id_from_account(account, Multicoin)
    ▼
walletId "multicoin_0x9858EfFD232B4033E47d90003D41EC34EcaEda94"
    │  Uuid::new_v5(b"GemKeystoreV4\0\0\0", walletId)
    ▼
keystoreId "f32a9e95-4904-533b-95fe-ebbe6cfb7554"
    ▼
<base_dir>/f32a9e95-4904-533b-95fe-ebbe6cfb7554.json
```

两端都有单测钉死（`gem_derivation/src/mnemonic/tests/derivation.rs:107`、`gem_keystore/src/id.rs`）。**改了任何一环，老用户的文件就找不到了——这两个测试是防回归的关键。**

### 这个设计带来三件事

**① 天然去重**

同一个助记词导入两次 → 同一个 ETH 地址 → 同一个 walletId → 同一个 keystoreId → **同一个文件名**。配合确定性写入和原子 rename，重复导入是幂等的。App 层再做一次 UI 提示。

**② 迁移可自校验**

```rust
// keystore.rs:194
let derived = derive_wallet_id_from_account(&account, wallet_type)?;
// 不匹配则报错：
// "migrated secret does not derive the wallet id: expected_wallet_id={expected}, derived_wallet_id={derived}, ..."
```

**解出来的助记词必须能重新派生出同一个 walletId，否则拒绝迁移。** 这比"文件写成功了"强得多——它证明的是密钥内容对，不只是文件搬过去了。

**③ 不需要额外存 id**

walletId 和 keystoreId 都是算出来的，不入库，少一个可能不一致的字段。

---

## 5. v4 文件格式

```json
{
  "version": 4,
  "id": "<uuid v5>",
  "kind": "mnemonic | private_key",
  "crypto": {
    "kdf": {
      "algorithm": "argon2id",
      "memory_kib": 19456,
      "iterations": 2,
      "parallelism": 1,
      "salt": "<hex>",
      "output_len": 32
    },
    "cipher": { "algorithm": "aes-256-gcm", "nonce": "<hex>", "tag_len": 16 },
    "ciphertext": "<hex, tag appended>"
  }
}
```

**密文里的明文只有 raw secret**：UTF-8 助记词字符串，或原始私钥字节，由已认证的 `kind` 字段决定如何解释。

> v4 does not store wallet names, app wallet ids, account lists, addresses, public keys, derivation paths, xpubs, or WalletCore `activeAccounts`.

### 密码学参数

来自 `core/crates/gem_keystore/src/storage/constants.rs`：

| 参数 | 默认值 | 上限 |
|---|---|---|
| Argon2id memory | 19 456 KiB（19 MiB） | 262 144 KiB |
| Argon2id iterations | 2 | 10 |
| Argon2id parallelism | 1 | 4 |
| Argon2id output_len | 32 | 固定，不允许其他值 |
| Salt | 16 字节随机，每次加密重新生成 | — |
| Cipher | AES-256-GCM | — |
| Nonce | 12 字节随机 | — |
| Tag | 16 字节 | — |

> Argon2id 参数是 OWASP 推荐值。因为**密码本身是 256-bit 随机设备密钥**（不是用户记忆的口令），KDF 在这里是纵深防御，不是主要强度来源。

### 安全规则

| 规则 | 说明 |
|---|---|
| **全字段 AAD 认证** | 除 `crypto.ciphertext` 外每个字段都作为 AES-GCM AAD，经规范化重序列化参与认证。**重排 JSON 无害，改任何值都会认证失败** |
| **id 必须与文件名一致** | 托管读取时校验，防止文件被换名 |
| **拒绝未知字段** | `deny_unknown_fields`，不允许任何未认证内容搭车 |
| **读写都有容量上限** | 解析前先卡文件与密文大小；写入时拒绝将来读不回来的内容 |
| **元数据不是迁移凭据** | `list` / `get_meta` / `inspect` 拿到的元数据**不能证明迁移成功**，必须带密码 `verify` 或真实解密 |
| **典型错误都是类型化的** | 未知版本、非法 id、非法 KDF/cipher 参数、格式错误、认证失败，全部返回 typed error |

### 容量上限（`constants.rs`）

```rust
ENCRYPTED_BODY_CAP: 64 * 1024      // 密文体
WHOLE_FILE_CAP:    128 * 1024      // 整文件
PASSWORD_CAP:     1024 * 1024      // 密码
```

---

## 6. 磁盘安全

### 原子写

`core/crates/gem_keystore/src/storage/file_io.rs`：

```
temp 文件写入 → fsync → 原子 rename → 目录 sync
```

```rust
fn set_secret_file_mode(options: &mut OpenOptions) {
    options.mode(0o600);                          // 创建时就是 owner-only
}
pub(super) fn set_owner_read_write(path: &Path) -> Result<(), KeystoreError> {
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
}
pub(super) fn sync_directory(path: &Path) -> Result<(), KeystoreError> {
    File::open(path)?.sync_all()?;                // 目录项也要落盘
}
```

**目录 sync 这一步经常被漏掉**——只 fsync 文件，rename 本身可能还在页缓存里，掉电后文件"存在但目录里看不见"。

### 并发串行化

`core/crates/gem_keystore/src/storage/queue.rs`（全文 9 行）：

```rust
static QUEUE: OnceLock<Mutex<()>> = OnceLock::new();

pub(super) fn lock() -> Result<MutexGuard<'static, ()>, KeystoreError> {
    Ok(QUEUE.get_or_init(|| Mutex::new(())).lock().unwrap_or_else(std::sync::PoisonError::into_inner))
}
```

`FileKeystore` 的每个公开方法第一行都是 `let _queue = queue::lock()?;`（import / decrypt / delete / get_meta / migrate 全部）。

三个要点：

1. **锁是 `static` 不是 per-instance** —— 所以 Android 每次 `GemKeystore(baseDir)` 新建实例、iOS 共享单例，两种用法都能正确串行
2. **锁中毒不 panic** —— `PoisonError::into_inner` 恢复，返回 typed error 而不是让 panic 穿过 FFI 边界
3. **覆盖已验证** —— Android instrumented `GemKeystoreConcurrencyTest` 用 8 个线程、独立 `GemKeystore` 实例，对同一钱包并发 create/read/delete

### 助记词生成

```
gem_crypto::random::bytes → getrandom::fill
                          → getrandom(2) / getentropy / BCryptGenRandom
```

**直接读 OS CSPRNG，不经过任何用户态或带种子的 PRNG。** 抽 32 字节，按词数截断（16 字节 / 12 词 … 32 字节 / 24 词），编码为英文 BIP-39 短语。熵值用 `Zeroizing` 持有，短语构造完立即擦除。

导入的短语会先做 NFKD 规范化、转小写，再对照 BIP-39 英文词表校验。

---

## 7. FFI 表面与红线

### `GemKeystore` 完整方法列表

来自 `core/gemstone/src/keystore/keystore.rs` 的 `#[uniffi::export]` 块：

| 方法 | 返回 | 用途 |
|---|---|---|
| `new(base_dir)` | `GemKeystore` | 构造，只接目录路径 |
| `preview_import(import)` | `GemWalletImport` | 导入预览，**不落盘** |
| `create_store(import, password)` | `GemStoredWallet` | 创建/导入并加密落盘 |
| `add_accounts(keystore_id, password, chains)` | `[GemKeystoreAccount]` | 为已有钱包补链 |
| `export_recovery_phrase(keystore_id, password)` | `[String]` | 🔴 **显式备份场景专用** |
| `export_private_key(keystore_id, chain, password)` | `String` | 🔴 **显式导出场景专用** |
| `migrate_v3(v3_path, v3_password, new_password, wallet_id)` | `GemStoredSecretMigration` | WalletCore v3 迁移 |
| `delete(keystore_id)` | `bool` | 删除 |
| **`sign(keystore_id, chain, input, password)`** | `[GemSignedTransaction]` | ⭐ **日常签名** |
| **`sign_auth(keystore_id, chain, hash, password)`** | `String` | ⭐ 设备/WalletConnect 鉴权签名 |
| `keystore_id_for_wallet(wallet_id)`（自由函数） | `String` | 算 keystoreId |

另有 `MessageSigner.sign_with_keystore(keystore, keystore_id, password)`，按 `signType` 分派 EIP-191 / EIP-712 / SIWE / Sui / Ton / Tron personal / base58。

### 红线：私钥不跨 FFI

**日常签名路径上，解密后的密钥从不离开 Rust。** App 传入 keystoreId、链、准备好的输入、密码字节，只拿回签名。

不在 UniFFI 表面的东西（Rust internal only）：

| 符号 | 状态 |
|---|---|
| `GemChainSigner` | 内部签名路由器 |
| `MessageSigner.sign(private_key)` | 裸密钥签名 |
| `sign_auth_message_hash` | 内部 |
| `GemKeystore.private_key(...)` | **`#[cfg(test)]` 独立 impl 块，仅测试可见** |

最后一条已实测确认：

```rust
// core/gemstone/src/keystore/keystore.rs:139
}                                       // ← #[uniffi::export] impl 块在此结束

#[cfg(test)]                            // ← 独立的测试专用 impl
impl GemKeystore {
    pub fn private_key(&self, keystore_id: String, chain: Chain, password: Vec<u8>) -> Result<Vec<u8>, GemstoneError> { ... }
}
```

`export_private_key` / `export_recovery_phrase` **只用于用户明确点击"查看助记词 / 导出私钥"**，不参与任何日常签名流程。

---

## 8. 平台侧实现

### 平台只提供两样东西

**① 目录路径**

```swift
// ios/Packages/Keystore/Sources/LocalKeystore.swift:27
// 先从 documentDirectory 迁到 applicationSupportDirectory，再把路径交给 Rust
let keystoreURL = try fileMigrator.migrate(
    name: directory,
    fromDirectory: .documentDirectory,
    toDirectory: .applicationSupportDirectory,
    isDirectory: true,
)
gemKeystore = try GemKeystore(baseDir: keystoreURL.path)
```

Android 通过 DI 注入 `baseDir`。

**② 密码**（见第 9 节）

### 调用形态的差异

| | iOS | Android |
|---|---|---|
| 实例 | 共享单例（`LocalKeystore` 持有一个 `GemKeystore`） | **每次调用新建**，`GemKeystore(baseDir).use { }` |
| 密码包装 | `withV4Password { passwordBytes in ... }` | `withGemKeystore(baseDir, password) { keystore, bytes -> ... }` |
| 串行 | 额外有一个 `DispatchQueue(label: "com.gemwallet.keystore")` | 靠 Rust 侧 static 锁 |

两种用法都安全，因为 Rust 的锁是进程级 static。

### Android 的密码擦除包装

```kotlin
// android/blockchain/.../operators/gemstone/GemKeystoreAccess.kt
internal inline fun <R> withGemKeystore(
    baseDir: String,
    password: String,
    block: (keystore: GemKeystore, passwordBytes: ByteArray) -> R,
): R {
    require(password.isNotEmpty()) { "keystore password is missing" }
    val passwordBytes = password.v4KeystorePasswordBytes()
    return try {
        GemKeystore(baseDir).use { keystore -> block(keystore, passwordBytes) }
    } finally {
        passwordBytes.fill(0)          // ← 无论成功失败都擦
    }
}
```

### App 入口

| | 方法 |
|---|---|
| **iOS** | `keystore.sign(wallet:input:)` · `keystore.signMessage(signer:wallet:)` · `keystore.signAuthMessageHash(wallet:chain:hash:)` |
| **Android** | `GemSignTransactionOperator` · `GemSignMessageOperator` · `GemSignAuthOperator`，全部经 `withGemKeystore` |

> 旧的 `getPrivateKey` / `ChainSigner` / `SwapSigner`（iOS）和 `SignClient` / `SignService`（Android）路径**已移除**。

---

## 9. 密码边界

密码是一个 **256-bit 随机设备密钥**，不是用户输入的口令。

| | 存储 | 格式 |
|---|---|---|
| **iOS** | Keychain（`LocalKeystorePassword` → `KeychainDefault`） | 小写 hex 字符串 |
| **Android** | `TinkPasswordStore` —— Google Tink 加密的 SharedPreferences，master key 在 Android Keystore（硬件支持） | 按 wallet id 存 hex 字符串 |

### 传参格式（容易踩）

| 场景 | iOS | Android |
|---|---|---|
| v4 API | 解码后的 raw bytes | 解码后的 raw bytes |
| **v3 迁移** | **hex 字符串的 UTF-8 字节** | 解码后的 raw bytes |

> 🔴 **iOS 的 v3 迁移传的是 hex 字符串本身的 UTF-8 编码，不是解码后的字节。** 这是为兼容 WalletCore 的历史行为，两端在这一处**故意不一致**。改动迁移代码时不要"顺手统一"。

空密码：v4 直接拒绝；v3 仅为遗留兼容而接受。

### iOS Keychain 可访问性

```swift
// ios/Packages/Keystore/Sources/LocalKeystorePassword.swift:104
.accessibility(.whenUnlockedThisDeviceOnly, authenticationPolicy: authentication.policy)
```

- `.whenUnlockedThisDeviceOnly` —— 不进 iCloud Keychain，不随备份迁移到新设备
- `authenticationPolicy` —— **生物识别是这里的一个可选 policy，不是默认绑定的**。是否强制生物识别取决于传入的 `authentication.policy`

### 设备鉴权密钥（另一套）

用于 `Gem <base64>` Authorization 头，与钱包私钥无关：

- `generate_device_key_pair` / `device_public_key` / `sign_device_auth`，经 UniFFI 暴露（底层 `gem_auth`）
- 私钥是 32 字节 Ed25519 seed，同样来自 `getrandom`
- **存在 App 的安全存储里**，签名由 Rust 产生
- 密钥对在 Rust 生成，保证两端一致

详见 `core/docs/DEVICE_AUTHENTICATION.md`。

---

## 10. v3 迁移

从 WalletCore keystore（v3）迁到 v4。

### 核心保证

```rust
// keystore.rs:194
let derived = derive_wallet_id_from_account(&account, wallet_type)?;
if derived != expected {
    return Err(...(
        "migrated secret does not derive the wallet id: \
         expected_wallet_id={expected}, derived_wallet_id={derived}, \
         derived_chain={}, derived_address={}"
    ));
}
```

**解出来的密钥必须能重新派生出同一个 walletId。** 这是内容级校验，不是文件级。

### 流程约束（iOS）

| 规则 | 说明 |
|---|---|
| v3 文件定位 | 用 `legacyV3Id = externalId ?? id.id` |
| keystoreId 派生 | iOS 传 `wallet.id.id` 给 `migrate_v3`，**Rust 自己派生 keystoreId 并校验绑定** |
| DB 更新 | **iOS 迁移后不更新钱包 DB** |
| 清理时机 | **验证通过才删 v3 文件** |
| 待迁移标记 | 就是 "v3 文件还在" 这个事实本身 |
| 失败重试 | 验证前失败 → v3 文件保留 → 下次启动重试 |

> ⭐ **用"旧文件是否还在"当迁移标记，而不是另建一张状态表** —— 状态和事实是同一个东西，不可能不同步。这个模式值得在别处复用。

### 两个坑

1. **不要从"这个字符串长得像 UUID"推断迁移状态** —— WalletCore v3 的 id 也可能是 UUID
2. **v4 文件和 v3 文件在同一目录**，但文件名、后缀、JSON `id` 规则都不重合，不会误判

### 账户公钥的历史遗留

公钥存在平台 DB 的账户行（`Account.extended_public_key`），不在 keystore 文件里：

| 链 | 存什么 |
|---|---|
| Bitcoin 系 | 扩展公钥（xpub / zpub） |
| Cardano | 不存（没有单一可复用公钥） |
| 其他所有链 | hex 编码的原始公钥（secp256k1 或 ed25519） |

> ⚠️ **v4 之前由 WalletCore 导入创建的账户行只带 Bitcoin 系 xpub，其他链是空的。** v3 迁移只搬密钥文件，**不重写 DB 账户行**；补链也只为缺失的链新增账户。所以老导入的行会一直保持空公钥，**唯一支持的补救办法是让用户重新导入钱包**（例如 Sui WalletConnect 需要公钥时）。

---

## 11. 风险清单

| # | 项 | 说明 |
|:---:|---|---|
| **1** | 🔴 **`wallet_id_chain = Chain::Ethereum` 是数据格式的一部分，不是配置项** | 改了它，所有存量用户的 keystoreId 全变，文件全部找不到 |
| **2** | 🔴 **地址大小写敏感** | ETH 地址用 EIP-55 混合大小写，直接拼进 UUID v5 的输入字节。**规范化形式必须全程一致**，变一个字母就是另一个文件 |
| **3** | ⚠️ **walletId 里含明文地址** | 会出现在 DB 主键、日志、可能还有埋点里。地址本身公开，但若有隐私要求（日志不得含用户地址），这是泄漏面。keystore 文件名是 UUID，反而看不出来 |
| **4** | ⚠️ **平台 DB 是地址→文件映射的唯一来源** | DB 丢失后无法定位文件；代码里没有暴力恢复路径 |
| **5** | ⚠️ **iOS / Android 的 v3 迁移密码格式故意不同** | iOS 传 hex 字符串的 UTF-8 字节，Android 传解码后字节。不要"顺手统一" |
| **6** | ⚠️ **生物识别不是默认绑定** | Keychain 的 `.whenUnlockedThisDeviceOnly` 有了，但生物识别取决于传入的 `authenticationPolicy` |
| **7** | ⚠️ **元数据不能当迁移凭据** | `list` / `get_meta` / `inspect` 的结果不证明任何事，必须带密码 verify 或真解密 |
| **8** | ⚠️ **老导入的账户行公钥为空** | 需要公钥的功能（如 Sui WalletConnect）只能引导用户重新导入 |

### 改动这块代码时

按仓库规约（`skills/security.md`、根 `CLAUDE.md`），密钥管理属**最高风险模块**：

- 改动 `gem_keystore` / `gem_derivation` / `keystore.rs` 前先读 `core/docs/KEYSTORE_V4.md`
- 不要在任何路径上 log、print、持久化、快照密钥材料
- `id.rs` 和 `wallet_id.rs` 的单测是防回归关键，**不允许为了让新代码通过而改断言**
- 迁移相关改动必须验证"崩溃/断电中途重跑"分支
- 完成后跑真实验证命令，不能只靠 `git diff` 和推理

---

## 12. 关键文件索引

### Rust

| 用途 | 路径 |
|---|---|
| **权威文档** | `core/docs/KEYSTORE_V4.md` |
| keystoreId 派生 | `core/crates/gem_keystore/src/id.rs` |
| walletId 派生 | `core/crates/gem_derivation/src/wallet_id.rs` |
| WalletId 类型与序列化 | `core/crates/primitives/src/wallet_id.rs` |
| 文件读写 / 原子写 / 权限 | `core/crates/gem_keystore/src/storage/file_io.rs` |
| 主存储实现 | `core/crates/gem_keystore/src/storage/file_keystore.rs` |
| 并发锁 | `core/crates/gem_keystore/src/storage/queue.rs` |
| 加密参数与实现 | `core/crates/gem_keystore/src/storage/crypto.rs` · `constants.rs` |
| 文件格式 / AAD | `core/crates/gem_keystore/src/storage/format.rs` |
| 助记词 | `core/crates/gem_keystore/src/mnemonic.rs` |
| **UniFFI 边界 + 签名路由** | `core/gemstone/src/keystore/keystore.rs` |
| 派生单测（钉死映射） | `core/crates/gem_derivation/src/mnemonic/tests/derivation.rs` |

### iOS

| 用途 | 路径 |
|---|---|
| 主入口 | `ios/Packages/Keystore/Sources/LocalKeystore.swift` |
| 密码（Keychain） | `ios/Packages/Keystore/Sources/LocalKeystorePassword.swift` |
| 认证策略 | `ios/Packages/Keystore/Sources/KeystoreAuthentication.swift` |
| keystoreId 计算 | `ios/Packages/GemstonePrimitives/Sources/Extensions/Wallet+GemstonePrimitives.swift` |
| 账户表 | `ios/Packages/Store/Sources/Models/AccountRecord.swift` |

### Android

| 用途 | 路径 |
|---|---|
| keystore 访问包装（含擦除） | `android/blockchain/.../operators/gemstone/GemKeystoreAccess.kt` |
| 签名 operator | `android/blockchain/.../services/GemSignMessageOperator.kt` · `GemSignAuthOperator.kt` |
| 交易签名 | `android/blockchain/.../operators/gemstone/` 下 `GemStorePhraseOperator` / `GemAddAccountsOperator` / `GemDeleteKeyStoreOperator` 等 |
| 密码存储 | `android/app/.../data/password/TinkPasswordStore.kt` |
| keystoreId 计算 | `android/gemcore/src/main/kotlin/com/gemwallet/android/ext/Wallet.kt` |
| 账户表 | `android/data/services/store/.../entities/DbAccount.kt` |
| 并发测试 | Android instrumented `GemKeystoreConcurrencyTest` |

### 相关文档

| 主题 | 路径 |
|---|---|
| 设备鉴权 | `core/docs/DEVICE_AUTHENTICATION.md` |
| 钱包鉴权 | `core/docs/WALLET_AUTHENTICATION.md` |
| 安全规约 | `skills/security.md` |
| 整体编译与调用 | `基于gem-core的ios和安卓开发教程.md` |

---

*本文档由 AI 辅助整理，源码结论基于 commit `820c415579` 实测复核。密钥相关代码变更后请以 `core/docs/KEYSTORE_V4.md` 与源码为准。*
