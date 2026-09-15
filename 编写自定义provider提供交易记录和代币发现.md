# 编写自定义 provider：提供交易记录和代币发现

> 面向：需要给某条链接一个自己的索引数据源的工程师
> 内容：provider 在这套架构里的职责边界、两层分离的落点、Alchemy/Ankr/Blockscout 三家参考实现的差异、完整动手步骤、以及这条链路上全部的静默失败模式
> 快照：`8c5e21bde4`（2026-09-15）。行号是快照，对不上时用文中给的 grep 定位法
> 范围：**EVM 链**。非 EVM 链见 [§6](#6-非-evm-链怎么做)

对照篇：[如何添加新链（包括EVM兼容）.md](如何添加新链（包括EVM兼容）.md) · [项目结构.md](项目结构.md)

---

## 目录

1. [先说结论](#1-先说结论)
2. [架构：为什么需要 provider，它在哪一层](#2-架构为什么需要-provider它在哪一层)
3. [职责边界：只做发现，不做解析](#3-职责边界只做发现不做解析)
4. [三家参考实现的差异](#4-三家参考实现的差异)
5. [动手：路 A（照现有模式）](#5-动手路-a照现有模式)
6. [非 EVM 链怎么做](#6-非-evm-链怎么做)
7. [路 B：不碰 gem_evm](#7-路-b不碰-gem_evm)
8. [过滤策略](#8-过滤策略)
9. [测试](#9-测试)
10. [验证：这条链路的静默失败模式](#10-验证这条链路的静默失败模式)
11. [工时](#11-工时)

---

## 1. 先说结论

**核心逻辑不到 40 行。难的不是写，是确认你写对了。**

| 参考实现 | 适配层（含测试） | 协议 crate |
|---|---:|---:|
| Blockscout | 75 行 | 164 行 |
| Ankr | 68 行 | 213 行 |
| Alchemy | 71 行 | 379 行 |

| 阶段 | 工时 |
|---|---:|
| 骨架跑通 | 0.5 天 |
| 分页 / 排序 / 去重语义对齐 | 0.5~1 天 |
| 类型限定 + testdata | 0.25 天 |
| **真实地址对账** | **1~2 天** |
| 合计 | **2.25~3.75 天** |

### 三个必须先回答的问题

| 问题 | 影响 |
|---|---|
| 数据源是按页返回还是**游标分页**？ | 游标分页时 `limit: usize` 这个签名表达不了，见 [§4.2](#42-分页三家都不一样) |
| 响应里**带块号**吗？ | 不带也能用（Ankr 就不带），但下游要按哈希逐笔回查 |
| 能在**请求参数**里限定只返回 ERC-20 吗？ | 能则在协议层写死，不能则适配层过滤，见 [§8](#8-过滤策略) |

数据源是 REST/JSON-RPC、按页返回、带块号 → 照 `blockscout.rs` 抄，2 天内完事。
游标分页、无块号、无类型限定手段 → 接近 4 天，且长期要为数据质量兜底。

---

## 2. 架构：为什么需要 provider，它在哪一层

### 2.1 节点做不到的那一件事

标准 EVM JSON-RPC 里**没有"按地址查历史"这个方法**。`eth_getTransactionByHash` 要你先知道哈希，`eth_getLogs` 只能扫日志且有区块范围限制。代币余额同理——`balanceOf` 要你先知道合约地址，而"这个地址持有哪些合约"链上无法反查。

这两件事都需要把链上数据**反向索引**一遍。provider 存在的全部理由就是它跑了这个索引，而节点没有。

推论：**能用节点做的事一律不经过 provider。** 原生币余额走 `eth_getBalance`、指定代币余额走 Multicall3、代币元数据走 ERC-20 `eth_call`——全都绕开 provider。

### 2.2 两层分离

三家现有实现都是"协议 crate + 适配层"两半：

```
core/crates/gem_blockscout/          ← 协议层：只管发请求和反序列化
  ├── client.rs                        请求构造
  ├── model.rs                         响应结构
  ├── testkit.rs                       include_str! 指向 testdata/
  └── testdata/*.json                  真实响应样本
        ↑ 完全不知道 EVMIndexerClient 存在

core/crates/gem_evm/src/rpc/blockscout.rs   ← 适配层：把响应揉成统一形状
  impl<C: Transport> EVMIndexerClient for BlockscoutClient<C>
```

**这个分离是强制的，不是风格选择**——原因见下。

### 2.3 关键约束：trait 是 `pub(crate)`

```rust
// core/crates/gem_evm/src/rpc/indexer/mod.rs:30
pub(crate) trait EVMIndexerClient {
    async fn get_transactions_by_address(&self, address: &str, limit: usize)
        -> Result<Vec<TransactionReference>, Box<dyn Error + Send + Sync>>;

    async fn get_token_balances(&self, address: &str)
        -> Result<Vec<(String, BigUint)>, Box<dyn Error + Send + Sync>>;
}
```

`pub(crate)` 意味着**你的独立 crate 实现不了它**。`TransactionReference` 同样是 `pub(crate)`。

所以适配层必须写在 `gem_evm` 里面。这也是为什么协议逻辑要单独成 crate——否则 `gem_evm` 会被各家 provider 的 HTTP 细节撑爆。

想完全不改 `gem_evm`？有另一条路，见 [§7](#7-路-b不碰-gem_evm)。

### 2.4 编排层：谁决定用哪几家

#### ★ 定义"用多少家"的就是这个代码块

`core/crates/gem_evm/src/rpc/indexer/mod.rs:109`，`for_chain` 函数里的 `provider_kinds` match。**整个仓库只有这一处决定某条链用哪几家索引器、以什么顺序**：

```rust
// ★★★ 这就是"定义多少家"的代码块 ★★★
// gem_evm/src/rpc/indexer/mod.rs:109
pub fn for_chain(alchemy_client: C, ankr_client: C, blockscout_client: C,
                 blockscout_key: String, chain: EVMChain) -> Option<Self> {
    let provider_kinds = match chain {
        EVMChain::Ethereum  => vec![ProviderKind::Blockscout, ProviderKind::Ankr("eth")],
        EVMChain::SmartChain => vec![ProviderKind::Ankr("bsc")],          // 只用一家
        EVMChain::Monad     => vec![ProviderKind::Alchemy],               // 只用一家
        // ...
        EVMChain::OpBNB | EVMChain::Manta | EVMChain::Mantle | EVMChain::Sonic
        | EVMChain::SeiEvm | EVMChain::Plasma | EVMChain::Stable | EVMChain::Tempo => {
            return None;      // ← 一家都不用：地址历史为空、代币不自动发现，且不报错
        }
    };
    // 只有 provider_kinds 里声明的 kind 才会被构造成 Provider
    let provider = |kind| match kind { /* Alchemy / Ankr / Blockscout 三个分支 */ };
    Some(Self { providers: provider_kinds.into_iter().map(provider).collect(), chain })
}
```

加自定义 provider 时，你要改的就是这个 match（以及 `Provider` / `ProviderKind` 两个 enum）。详见 [§5.3](#53-注册6-处)。

#### 现状：没有一条链用满三家

| 声明了几家 | 链 |
|---|---|
| Blockscout + Ankr | Ethereum, Polygon, Arbitrum, Optimism, Base, Gnosis |
| Blockscout + Alchemy | ZkSync, Celo, World, Ink, Unichain, Robinhood |
| **只有 Ankr** | AvalancheC, SmartChain, Fantom, Linea, XLayer |
| **只有 Alchemy** | Blast, Abstract, Berachain, Hyperliquid, Monad |
| **一家都不用**（`return None`） | opBNB, Manta, Mantle, Sonic, SeiEvm, Plasma, Stable, Tempo |

**"只用一家"是既有做法（11 条链），"一家都不用"也有 8 条链。** 所以只挂你自己的 provider 完全在设计预期内，见 [§5.4](#54-只用你自己的-provider不挂官方三家)。

#### 三层语义，别混淆

| 层 | 会发生什么 |
|---|---|
| **声明** | `provider_kinds` match 列出这条链用哪几家 |
| **装配** | 只为声明的 kind 构造 `Provider` 对象。`ReqwestClient` 的 `with_base_url()` / `with_request_timeout()` 都是**纯本地对象构造，零网络请求** |
| **运行时** | `try_in_order` **短路**：第一家成功就返回，后面的 future 根本不 `await` |

#### try_in_order 是短路的

`primitives/src/async_result.rs`：

```rust
for operation in operations {
    match operation.await {
        Ok(value) => return Ok(Some(value)),   // ← 第一家成功即停，后面不发请求
        Err(error) => last_error = Some(error),
    }
}
match last_error {
    Some(error) => Err(error),      // 全失败 → 返回最后一个错误
    None => Ok(None),               // 空列表 → 不是错误
}
```

它自己的测试把语义写得很清楚：

```rust
try_in_order([Err("first"), Ok(42), Ok(43)])  →  Ok(Some(42))   // 第一个成功即停
try_in_order([Err("first"), Err("last")])     →  Err("last")    // 全失败取最后的错
try_in_order([])                              →  Ok(None)       // 空列表不算错
```

所以 **Ethereum 正常情况只请求 Blockscout**，Ankr 只在 Blockscout 返回 `Err` 时才被 `await`。`provider_kinds` 里的**顺序就是优先级**——能拿到 Blockscout PRO 的链都把它排第一，排第一的那家承担全部正常流量。

#### 一"家"不等于一个请求

| provider | 一次 `get_transactions_by_address` 内部发几个请求 |
|---|---|
| Blockscout | 2（`transactions` + `token-transfers`），顺序 `await` |
| Ankr | 2（`getTransactionsByAddress` + `getTokenTransfers`），`try_join!` 并发 |
| Alchemy | 2（`fromAddress` + `toAddress` 两个方向），`try_join!` 并发 |

Ethereum 查一次地址历史 = **2 个 Blockscout 请求**，不是 1 个也不是 4 个。

#### 错误归因

`Provider` enum（`:36`）包一层，每个错误套上 `IndexerProviderError { provider: "Alchemy", source }`，报错形如 `Alchemy: HTTP 401`。有专门的测试 `test_provider_error_includes_provider_name` 断言这个前缀和 `source()` 链——**接进来就自动获得，不用自己写**。

---

## 3. 职责边界：只做发现，不做解析

provider 只回答两个问题，且只回答这两个：

1. **这个地址碰过哪些交易？** → 一串哈希（+ 可能有块号）
2. **这个地址持有哪些代币合约？** → 一串 `(合约地址, 原始余额)`

返回类型就是边界：

```rust
TransactionReference { hash: String, block_number: Option<u64> }   // 不是 Transaction
Vec<(String, BigUint)>                                             // 不是 AssetBalance
```

没有金额、没有 from/to、没有时间、没有状态、没有 symbol、没有 decimals。

### 3.1 交易详情要回查节点

`settings_chain/src/chain_providers.rs:67` 拿到哈希列表后：

```rust
stream::iter(transaction_requests.into_iter().take(limit))
    .map(|request| provider.get_transaction_by_hash(request))
    .buffer_unordered(5)          // 并发 5 路回查
    .filter_map(...)              // 查不到就丢掉 + warn
```

完整链路是：

```
provider 给哈希 → 节点 eth_getTransactionByHash 给详情
              → EthereumMapper 转领域模型 → sort_transactions_by_date
```

provider 只占第一步。这也解释了为什么 Ankr 的 `block_number: None` 可以接受——块号只是优化提示，不是必需。

### 3.2 代币余额要补元数据

`map_assets_balances`（`gem_evm/src/provider/balances_mapper.rs`）把 `(合约, 余额)` 包成 `AssetBalance`，而 `AssetBalance` 只有三个字段：

```rust
pub struct AssetBalance { asset_id, balance, is_active }
```

symbol / decimals / name 一个都没有，后面靠 `get_token_data` 的 ERC-20 `eth_call` 单独补。

`map_assets_balances` 只做两件过滤：

```rust
if balance.is_zero() { return None; }            // 零余额丢弃
let checksum = ethereum_address_checksum(..).ok()?;  // 地址非法丢弃
```

**注意它不做类型过滤**——这一点在 [§8](#8-过滤策略) 有后果。

### 3.3 职责分工总表

| 工作 | 谁做 |
|---|---|
| 发现地址相关的交易哈希 | **provider** |
| 发现地址持有的代币合约 | **provider** |
| 代币类型限定 / 垃圾币过滤 | **provider** |
| 零余额过滤、地址 checksum | `map_assets_balances` |
| 多家 failover + 错误归因 | `EVMIndexer` / `try_in_order` |
| 交易详情 | 节点 `eth_getTransactionByHash` |
| 交易解析成领域模型 | `EthereumMapper` |
| 按时间排序 | `sort_transactions_by_date` |
| 代币元数据（name/symbol/decimals） | 节点 ERC-20 `eth_call` |
| 原生币余额 | 节点 `eth_getBalance` |
| 指定代币余额 | 节点 Multicall3 |

**如果你的数据源返回了完整交易详情，那些字段在这一层会被丢掉。** 照契约只取哈希和块号，别试图绕过回查链路去"优化"——那会让你的 provider 和另三家行为不一致。

---

## 4. 三家参考实现的差异

### 4.1 交易记录：都要发两个请求

没有一家的单个接口能同时覆盖原生转账和代币转账，所以三家都是**两路合并去重**。

| | 两路是什么 | 并发 | 去重与排序 | 带块号 |
|---|---|---|---|:---:|
| **Alchemy** | `fromAddress` / `toAddress` 两个方向 | `try_join!` | `sort_by_key(Reverse)` + `HashSet` | ✅ |
| **Ankr** | `getTransactionsByAddress` / `getTokenTransfers` | `try_join!` | `HashSet`，**依赖上游顺序** | ❌ |
| **Blockscout** | `transactions` / `token-transfers` | 顺序 `await` | `BTreeSet<(Reverse(block), hash)>` | ✅ |

**Alchemy 按方向切，另两家按类型切。** Alchemy 的 `alchemy_getAssetTransfers` 一次能拿全部 category（`external`/`erc20`/`erc721`/`erc1155`），但只能按单个方向过滤，所以拆进/出两路。另两家的接口本身就按"普通交易"和"代币转账"分开。

**排序责任归属不同。** Blockscout 用 `BTreeSet` 让排序和去重一步完成，key 是 `(Reverse(block_number), hash)`，插入即有序——**这是最省心的写法，推荐照抄**。Alchemy 先 `sort_by_key` 再用 `HashSet` 保序遍历。Ankr 两者都没做，完全托付给上游的 `descOrder: true`。

### 4.2 分页：三家都不一样

```rust
Alchemy:    maxCount: "0x{limit:x}"   + 适配层再 .take(limit)
Ankr:       pageSize: limit            // 完全信任上游
Blockscout: items_count: limit         // 完全信任上游
```

只有 Alchemy 在适配层兜了底。

⚠️ **这是最容易踩的坑。** 如果你的数据源是游标分页（`next_page_params` 那种），`items_count` / `pageSize` 这类参数很可能**返回 200 但被忽略**——数据看着对，条数悄悄不听你的。自建 Blockscout 开源版就是这个情况（PRO 网关和开源版的分页语义不同）。

游标分页的应对：在协议层多轮拉取拼到 limit，或者在适配层 `.take(limit)` 兜底并接受"可能不足 limit"。

上层还有一道保护：`MAX_PAGE_SIZE = 50`（`indexer/mod.rs:16`），`request.limit.min(MAX_PAGE_SIZE)`。

### 4.3 代币发现：类型限定的位置不同

| | 类型限定在哪 |
|---|---|
| Alchemy | **请求参数**写死：`params: ["0x123", "erc20"]` |
| Ankr | `contract_address.is_some()`（排除原生币条目），另有 `onlyWhitelisted: true` |
| Blockscout | 响应过滤 `token_type == "ERC-20"` |

**"完全不过滤"在这套架构里没有先例。** Alchemy 看着没过滤，是因为它在上游就把范围锁死了。

---

## 5. 动手：路 A（照现有模式）

### 5.1 新建协议 crate

`core/crates/gem_yourprovider/`，照 `gem_blockscout` 的四件套：

```
src/lib.rs        导出 Client + model 公开类型
src/client.rs     请求构造 + 反序列化
src/model.rs      响应结构（用 serde_serializers 处理数字字符串）
src/testkit.rs    include_str! 指向 testdata/
testdata/*.json   真实响应样本
```

`model.rs` 的写法参考 `gem_ankr/src/model.rs`：外层包装结构体用 `pub(super)`，只把真正要用的字段设为 `pub`。数字字符串用 `serde_serializers::deserialize_biguint_from_str`。

别忘了 `core/Cargo.toml` 的 workspace `members`。

### 5.2 写适配层

新建 `core/crates/gem_evm/src/rpc/yourprovider.rs`。以 `blockscout.rs` 为模板（两路合并 + `BTreeSet` 排序去重）：

```rust
use std::cmp::Reverse;
use std::collections::BTreeSet;
use std::error::Error;

use gem_client::Client as Transport;
use gem_yourprovider::Client as YourClient;
use num_bigint::BigUint;

use super::{EVMIndexerClient, TransactionReference};

impl<C: Transport> EVMIndexerClient for YourClient<C> {
    async fn get_transactions_by_address(
        &self,
        address: &str,
        limit: usize,
    ) -> Result<Vec<TransactionReference>, Box<dyn Error + Send + Sync>> {
        let transactions = self.get_transactions(address, limit).await?;
        let token_transfers = self.get_token_transfers(address, limit).await?;

        Ok(transactions
            .into_iter()
            .map(|transaction| (transaction.block_number, transaction.hash))
            .chain(
                token_transfers
                    .into_iter()
                    .map(|transfer| (transfer.block_number, transfer.transaction_hash)),
            )
            // BTreeSet 一步完成去重 + 按块号倒序
            .map(|(block_number, hash)| (Reverse(block_number), hash))
            .collect::<BTreeSet<_>>()
            .into_iter()
            .map(|(Reverse(block_number), hash)| {
                TransactionReference::new(hash, Some(block_number))
            })
            .collect())
    }

    async fn get_token_balances(
        &self,
        address: &str,
    ) -> Result<Vec<(String, BigUint)>, Box<dyn Error + Send + Sync>> {
        Ok(YourClient::get_token_balances(self, address)
            .await?
            .into_iter()
            // 类型限定必须保留，见 §8
            .filter(|balance| balance.token_type == "ERC-20")
            .map(|balance| (balance.contract_address, balance.value))
            .collect())
    }
}
```

> 两路并发可以用 `futures::try_join!`（Alchemy 和 Ankr 都这么做），Blockscout 用的是顺序 `await`。两路都要打网络时 `try_join!` 更好。

### 5.3 注册（6 处）

| # | 位置 | 改什么 |
|---|---|---|
| 1 | `gem_evm/src/rpc/mod.rs:1-3` 旁边 | 加 `mod yourprovider;` |
| 2 | `gem_evm/src/rpc/indexer/mod.rs:36` | `Provider` enum 加变体 |
| 3 | 同上 `:42` | `ProviderKind` enum 加变体 |
| 4 | 同上 `:73` | `name()` 返回 `"YourProvider"`（错误前缀用） |
| 5 | 同上 `:82` | `impl EVMIndexerClient for Provider` 的**两个** match 各加一路分发 |
| 6 | 同上 `:108` | `for_chain` 给目标链加 `ProviderKind::YourProvider`，以及闭包里的构造分支 |

配置：

| 位置 | 改什么 |
|---|---|
| `core/crates/settings/src/lib.rs:43` | `Indexer` struct 加一个 `ProviderSettings` 字段 |
| `core/Settings.yaml:372` 旁边的 `indexers:` 段 | `url` + `key.secret` |
| `core/crates/settings_chain/src/lib.rs:76` | `EVMIndexer::for_chain(...)` 多传一个 client |

⚠️ `for_chain` 目前是 5 个位置参数（`alchemy_client, ankr_client, blockscout_client, blockscout_key, chain`），再加会很难读。可以考虑收成一个 struct——但那是独立重构，**别混在这次改动里**。

**接进来自动获得**：`try_in_order` 顺序 failover、`IndexerProviderError` 的 provider 名前缀、`MAX_PAGE_SIZE` 上限保护。

### 5.4 只用你自己的 provider，不挂官方三家

**可以，而且符合既有做法**——11 条链只用一家，8 条链一家都不用（见 [§2.4](#24-编排层谁决定用哪几家)）。

在那个 match 里只声明你自己：

```rust
EVMChain::YourChain => vec![ProviderKind::YourProvider],
```

运行时就只会请求你这一家。但有一个 **panic 陷阱**必须处理。

#### 陷阱：`alchemy_url` 仍然必须登记你的链

装配处（`settings_chain/src/lib.rs:76`）：

```rust
let indexer = EVMIndexer::for_chain(
    gem_client.clone()...with_base_url(alchemy_url(   // ← 这是参数，立即求值
        chain, &config.indexers.alchemy.url, AlchemyApi::JsonRpc, &config.indexers.alchemy.key,
    )),
    ...
);
```

`alchemy_url` 是 `for_chain` 的**参数**，在 `for_chain` 有机会说"这条链不用 Alchemy"之前就被求值了。而它对不认识的链直接炸：

```rust
// gem_alchemy/src/url.rs:40
_ => panic!("Alchemy is not supported for {chain}"),
```

**证据**：Plasma / Stable / OpBNB / Manta / Mantle / Sonic / SeiEvm 在 `for_chain` 里全是 `return None`（完全不用任何索引器），但它们**每一条都在 `alchemy_url` 的 match 里**——就是为了躲这个 panic。

所以要加一行，并写清为什么：

```rust
// gem_alchemy/src/url.rs
// 本链只用自定义 provider；此条目仅为避免 alchemy_url 在装配时 panic
Chain::YourChain => "yourchain-mainnet",
```

⚠️ **这是 panic 不是编译错误。** 编译通过，跑到装配这条链的那一刻才崩。所以必须用 `cargo run -p cli -- balance <chain> <地址>` 实跑一次——它会第一时间暴露。

Ankr 和 Blockscout 那两个参数不用管：`format!()` 和 `configure_client()` 对任何链都安全。

`settings/src/lib.rs` 的 `Indexer` struct 和 `Settings.yaml` 的 `indexers:` 段里，alchemy/ankr/blockscout 三项**不能删**——它们是全局配置，别的链在用。你的链只是不会真的去请求它们。

#### 代价：没有兜底

| | Ethereum | 只挂一家的链 |
|---|---|---|
| provider | Blockscout → Ankr | 只有你的 |
| 第一家挂了 | 自动降级 | **交易记录和代币发现直接不可用** |

`try_in_order` 退化成"单次调用 + 错误直接上抛"。这不是 bug，是单一 provider 的必然结果。两点建议：

- 错误仍带 `YourProvider: ...` 前缀，排障能立刻定位——这个能力保留着
- 数据源有多个部署实例时，可以在**协议 crate 内部**做多端点重试；或者把请求走 `core/apps/egress`（出站 API 网关，自带多端点选择和失败冷却）

#### 更彻底的一条路（一般不需要）

想完全绕开 `EVMIndexer` 的装配，可以照 **Tempo** 的模式在闭包之前拦截：

```rust
// gem_tempo/src/provider.rs:32
pub fn new_or_else(client: EthereumClient<C>, fallback: impl FnOnce(...) -> Box<dyn ChainTraits>) -> Box<dyn ChainTraits> {
    if client.get_chain() == Chain::Tempo {
        Box::new(Self::new(client))    // ← 闭包整个不执行，alchemy_url 不被求值
    } else {
        fallback(client)
    }
}
```

这就是 Tempo 为什么**不需要**出现在 `alchemy_url` 的 match 里。代价是要自己组装 `EthereumProvider`，改动远大于加一行 `alchemy_url`——**只有当你的 provider 组装逻辑确实和 EVM 那套不同才值得**。

#### 顺带记一个设计问题

`alchemy_url` 用 `panic!` + eager evaluation 这个组合，逼着每条 EVM 链都要在一个跟自己无关的 match 里登记，而且违规是运行时崩溃而非编译错误。更好的形态是返回 `Option<String>`、装配处惰性求值。

但那是牵动所有链的重构，**不要混进接链或接 provider 的改动里**——按仓库规范记为待跟进项。

---

## 6. 非 EVM 链怎么做

`EVMIndexerClient` 是 EVM 专属的。非 EVM 链实现两个**公开** trait：

| 能力 | trait | 位置 |
|---|---|---|
| 交易记录 | `chain_traits::ChainTransactions` | `core/crates/chain_traits/src/lib.rs` |
| 代币发现 | 链自己 provider 的余额方法（`ChainBalances::get_balance_assets`） | 对应 `gem_*` crate |

参考现成的非 EVM 索引器：

```
core/crates/gem_solana/src/rpc/indexer/    Alchemy
core/crates/gem_sui/src/rpc/indexer/       Sui GraphQL
core/crates/gem_near/src/rpc/indexer/      FastNear
core/crates/gem_polkadot/src/rpc/indexer/  Subscan
core/crates/gem_algorand/src/rpc/indexer/  Algorand Indexer
core/crates/gem_tron/src/rpc/trongrid/     TronGrid
```

没有数据源时用 `chain_traits::EmptyTransactionsProvider` 占位，但要在 [core/docs/FEATURES.md](core/docs/FEATURES.md) 的索引表里明确写 `Unsupported`，别留空让它看起来像"已支持"。

---

## 7. 路 B：不碰 gem_evm

`EthereumProvider::new`（`gem_evm/src/rpc/provider.rs`）的签名：

```rust
pub fn new(
    client: EthereumClient<C>,
    transactions_by_address_provider: Box<dyn ChainTransactions>,   // ← pub trait
    asset_balance_provider: Box<dyn AssetBalanceProvider>,          // ← pub trait
) -> Self
```

这两个 trait 都是**公开**的：

- `chain_traits::ChainTransactions` → 交易记录
- `gem_evm::rpc::AssetBalanceProvider` → 代币发现

所以你可以在自己的独立 crate 里实现这两个，在装配处直接传进去，**完全不改 `gem_evm` 一行**。

| | 路 A | 路 B |
|---|---|---|
| 改 `gem_evm` | 需要 | 不需要 |
| failover 编排 | 白送 | **自己写** |
| 错误 provider 名前缀 | 白送 | 自己写 |
| 能和另三家组 failover 链 | ✅ | ❌ |

### 怎么选

| 情况 | 选 |
|---|---|
| 想和 Alchemy/Ankr/Blockscout 组 failover 链 | **路 A** |
| 只用你这一家，不挂官方三家 | **路 A 就够了**，见 [§5.4](#54-只用你自己的-provider不挂官方三家) |
| 硬性要求不改 `gem_evm` 一行 | 路 B |
| 非 EVM 链 | 只有路 B 的形态，见 [§6](#6-非-evm-链怎么做) |

⚠️ **"只用一家"不是选路 B 的理由。** 路 A 的 `provider_kinds` match 本来就支持单家甚至零家（11 条链只用一家，8 条链零家）。选路 B 的唯一理由是**不能改 `gem_evm`**。

**默认选路 A**，除非有明确理由不动 `gem_evm`。failover 和错误归因迟早要做，现有实现已经写好了，自己重写不划算。

---

## 8. 过滤策略

### 8.1 三家做了什么

`gem_blockscout/testdata/token_balances.json` 里 4 条记录，Blockscout 的一行 filter 挡掉 2 条：

| 合约 | type | reputation | 结果 |
|---|---|---|---|
| `0xtoken` | ERC-20 | ok | 通过 |
| `0xunpriced` | ERC-20 | ok | 通过 |
| `0xspam` | ERC-20 | **spam** | 被声誉挡掉 |
| `0xnft` | **ERC-721** | ok | 被类型挡掉 |

```rust
.filter(|b| b.token.token_type == "ERC-20"              // ← 类型限定
         && b.token.reputation.as_deref() == Some("ok"))     // ← 声誉判断
```

**这一行做了两件事，要分开决定。**

### 8.2 类型限定：不能省

假设 ERC-721 漏进来，下游不会拦住它：

1. `map_assets_balances` 只查零余额和地址合法性——NFT 余额是 1，**通过**
2. 进到 `get_token_data`，批量 `eth_call` 查 `name` / `symbol` / `decimals`
3. **ERC-721 没有 `decimals()`**（连 Metadata 扩展都没有）→ `decode_abi_uint8` 失败 → `map_token_data` 返回 `Err`

结果是这个条目加不进资产列表或显示异常，而**没有任何一层会告诉你原因是"把 NFT 当代币了"**。

如果数据源能在**请求参数**里限定只返回 ERC-20（像 Alchemy 那样），就在协议 crate 里写死，适配层保持纯转发——更干净。

### 8.3 声誉过滤：可以先不做

Alchemy 就不做声誉判断，有先例。

**后果明确且可逆**：用户资产列表会出现空投垃圾币。零余额那道过滤挡不住——空投垃圾币余额通常不为零，这正是它们的手法。

要加就是一行 `filter`，所以先不做是合理取舍，**前提是数据源将来能提供某种信号**（白名单参数、声誉字段、持有人数、市值）。如果它永远给不了任何信号，这个债后面只能在别的层还（比如自己维护黑名单）。

先不做时，在适配层留一行注释说明这是有意的范围决定：

```rust
// 暂不做声誉过滤：数据源当前无 reputation/whitelist 信号。
// 结果是空投垃圾币会进入资产列表，待数据源支持后在此补一行 filter。
```

---

## 9. 测试

按 [core/CLAUDE.md](core/CLAUDE.md) 的测试规范：

- **完整 JSON 放 `testdata/`，用 `include_str!` 载入**。不要在 Rust 文件里用 `serde_json::json!` 内联请求/响应/交易 JSON
- 一个 `test_<函数名>` 里放多个断言，不要拆成一堆单断言测试函数
- 不要测静态查找表、枚举接线、字面配置
- 集成测试只断言稳定不变量，不要对实时网络值做容差断言

### 两个测试分别测什么

| 位置 | 测什么 |
|---|---|
| 协议 crate 的 `client.rs` | **请求参数对不对**。照 `gem_ankr/src/client.rs` 的做法，用 `mock_jsonrpc_client` 断言 `params` 完整相等 |
| 适配层 `gem_evm/src/rpc/yourprovider.rs` | **响应映射对不对**。两路合并去重的顺序、类型过滤的效果 |

### testdata 要放脏数据

`blockscout.rs` 的测试断言 4 条余额只通过 2 条——**就是为了防有人后来把过滤条件删了**。

你的 testdata 也应该放：

- 一条**同时出现在两路**的交易（验证去重），Blockscout 的 `0xshared` 就是
- 一条块号乱序的（验证排序）
- 一条 ERC-721（验证类型限定）
- 一条垃圾币样本

暂不做声誉过滤时，**断言那条垃圾币当前会通过**。这样等你哪天加上过滤，这个断言会失败，提醒你更新测试而不是悄悄改变行为。

### 运行

```bash
cd core
just test gem-yourprovider
just test gem-evm
cargo clippy -p gem_yourprovider -p gem_evm -- -D warnings
just format
```

---

## 10. 验证：这条链路的静默失败模式

**这条链路上没有任何一处会因为数据错误而报错。** 这是接 indexer 最贵的地方。

| 症状 | 真实原因 | 报错吗 |
|---|---|:---:|
| UI 显示"没有代币" | 数据源的 token indexer 没跑 / 返回空数组 | ❌ |
| 交易记录只有一半 | 上游历史回填未完成 | ❌ |
| 条数和你传的 limit 不一致 | 分页参数被上游忽略（游标分页） | ❌ |
| 某几笔交易凭空消失 | provider 返回了链上不存在的哈希，回查阶段 `warn` 后丢弃 | ❌ 只有日志 |
| 代币显示异常 / 加不进列表 | ERC-721 漏进来，`decimals()` 查询失败 | ❌ |
| 资产列表全是垃圾币 | 没做声誉过滤（可能是有意的） | ❌ |

回查阶段单笔失败只 `warn` 不中断（`chain_providers.rs`），所以**对账发现条数少了，先查日志里的 `transaction not found`**。

### 必须用真实地址对账

| 测试地址类型 | 验证什么 |
|---|---|
| 持有多种代币 | 代币发现数量与浏览器一致 |
| 空地址 | 返回空数组而不是报错 |
| 大量历史记录 | 分页 limit 真的生效、顺序是倒序 |
| 只有代币转账、无原生转账 | 两路合并没漏掉单路 |
| 同一笔哈希在两路都出现 | 去重生效，不重复显示 |
| 持有 NFT | NFT 没被当成代币 |

按 [CLAUDE.md](CLAUDE.md)：跳过的记录、吞掉的错误、没测的分支要**显式说出来**。"接口返回 200"不是验证通过。

---

## 11. 工时

| 阶段 | 工时 | 说明 |
|---|---:|---|
| 协议 crate + 适配层骨架 | 0.5 天 | 照 `blockscout.rs` 抄 |
| 6 处注册 + 配置 | 0.25 天 | 全是一行式改动，但跨 3 个 crate |
| 分页 / 排序 / 去重语义对齐 | 0.5~1 天 | 游标分页时取上限 |
| 类型限定 + testdata | 0.25 天 | 不含声誉过滤的决策时间 |
| **真实地址对账** | **1~2 天** | **主要成本** |
| 合计 | **2.25~3.75 天** | |

前 0.5 天让 CI 变绿，后面 2~3 天在确认数据没骗你。

---

## 速查

| 目的 | 位置 / 命令 |
|---|---|
| trait 定义 | `core/crates/gem_evm/src/rpc/indexer/mod.rs:30` |
| 最佳模板（两路 + BTreeSet 排序去重） | `core/crates/gem_evm/src/rpc/blockscout.rs` |
| 最短模板（无排序无块号） | `core/crates/gem_evm/src/rpc/ankr.rs` |
| 按方向拆分的模板 | `core/crates/gem_evm/src/rpc/alchemy.rs` |
| 协议 crate 模板 | `core/crates/gem_blockscout/` |
| failover 编排（短路语义） | `primitives/src/async_result.rs` 的 `try_in_order` |
| **★ 定义某条链用哪几家的代码块** | `indexer/mod.rs:109`，`for_chain` 里的 `provider_kinds` match |
| 只挂自己的 provider 要注意什么 | [§5.4](#54-只用你自己的-provider不挂官方三家)（`alchemy_url` panic 陷阱） |
| 绕开 EVMIndexer 装配的先例 | `gem_tempo/src/provider.rs:32` 的 `new_or_else` |
| 后端装配处 | `core/crates/settings_chain/src/lib.rs:76` |
| 移动端装配处 | `core/gemstone/src/gateway/chain_factory.rs` |
| 交易详情回查 | `core/crates/settings_chain/src/chain_providers.rs:67` |
| 余额映射（零余额过滤在这） | `gem_evm/src/provider/balances_mapper.rs` |
| 各链索引器覆盖现状 | [core/docs/FEATURES.md](core/docs/FEATURES.md) 的索引 provider 表 |
| 找全部 `EVMIndexerClient` 实现 | `grep -rn "impl.*EVMIndexerClient" core/crates --include="*.rs"` |
