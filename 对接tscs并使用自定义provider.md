# 对接 tscs 并使用自定义 provider

> 面向：执行 tscs 接入的工程师
> 内容：一份可照做的工单。链注册 + 自定义 provider（交易记录 + 代币发现）两个阶段，含全部改动位置、代码、验证步骤和提交清单
> 快照：`8c5e21bde4`（2026-09-15）。行号是快照，对不上时用文中给的 grep 定位法

**全文 `{{占位符}}` 标记待填参数。开工前先把 [§0](#0-开工前把这张表填满) 填满，然后全局替换。**

参考文档（本文是它们针对 tscs 的收敛版，遇到疑问回去查）：
- [如何添加新链（包括EVM兼容）.md](如何添加新链（包括EVM兼容）.md) — 链注册的完整清单和原理
- [编写自定义provider提供交易记录和代币发现.md](编写自定义provider提供交易记录和代币发现.md) — provider 的架构约束和三家参考实现
- [项目结构.md](项目结构.md) — 模块职责

---

## 目录

0. [开工前：把这张表填满](#0-开工前把这张表填满)
1. [总览](#1-总览)
2. [阶段一：链注册](#2-阶段一链注册)
3. [阶段二：自定义 provider](#3-阶段二自定义-provider)
4. [阶段三：双端](#4-阶段三双端)
5. [验证](#5-验证)
6. [安全检查](#6-安全检查)
7. [提交](#7-提交)
8. [完整改动清单](#8-完整改动清单)

---

## 0. 开工前：把这张表填满

### 0.1 链参数

| 占位符 | 含义 | 值 | 怎么确认 |
|---|---|---|---|
| `{{CHAIN_ENUM}}` | Rust 枚举名（大驼峰） | `Tscs` | 命名和 `Chain` 枚举现有风格一致 |
| `{{CHAIN_SLUG}}` | 序列化字符串（小写） | `tscs` | `#[strum(serialize_all = "lowercase")]` 自动推导，确认无冲突 |
| `{{CHAIN_ID}}` | **EVM chain id** | | `curl -s -X POST <rpc> -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}'` |
| `{{NATIVE_NAME}}` | 原生币全名 | | 官方文档 |
| `{{NATIVE_SYMBOL}}` | 原生币符号 | | 官方文档 |
| `{{NATIVE_DECIMALS}}` | 原生币精度 | | 官方文档，EVM 通常 18 |
| `{{NETWORK_NAME}}` | 网络显示名 | | 用于 UI |
| `{{BLOCK_TIME_MS}}` | 出块时间（毫秒） | | 连续取两个块的 timestamp 差 |
| `{{RPC_URL}}` | 默认 RPC 端点 | | 官方 |
| `{{EXPLORER_NAME}}` | 浏览器名称 | | |
| `{{EXPLORER_URL}}` | 浏览器地址 | | |
| `{{MIN_PRIORITY_FEE}}` | 最低优先费（wei） | | 参考同类链，Arc 用 `1_000_000` |
| `{{CHAIN_STACK}}` | `Native` / `Optimism` / `ZkSync` | | OP Stack 或 zkStack 派生链要选对应值 |
| `{{IS_L2}}` | 是否以太 L2 | | 影响 UI 图标分组 |
| `{{RANK}}` | 排序权重 | | 参考 `chain_config.rs` 里同量级链 |
| `{{MULTICALL3}}` | Multicall3 是否部署在标准地址 | | 见 [§0.4](#04-必须实测的三件事) |
| `{{COINGECKO_PLATFORM}}` | CoinGecko platform id | 或 `无` | |
| `{{COINGECKO_MARKET}}` | 原生币 market id | 或 `无` | |
| `{{PYTH_FEED}}` | 原生币 Pyth feed id | 或 `无` | |

⚠️ **`{{CHAIN_ID}}` 必须实测，不要从文档抄。** 填错的后果是交易签名绑定到错误的链，最坏情况是资金损失。用上面的 `eth_chainId` 命令从你要配的那个 RPC 端点直接读。

**`slip44` 固定 `60`**（与以太共用地址格式和派生路径）。如果 tscs 声明了自己的 slip44，停下来先确认——那意味着地址派生不兼容，就不是"EVM 兼容链"了，得走[非 EVM 路径](如何添加新链（包括EVM兼容）.md)。

### 0.2 自定义 provider 参数

| 占位符 | 含义 | 值 |
|---|---|---|
| `{{PROVIDER_NAME}}` | provider 显示名（错误前缀用） | |
| `{{PROVIDER_CRATE}}` | 协议 crate 名 | `gem_{{小写名}}` |
| `{{PROVIDER_ENUM}}` | Rust 枚举变体名 | |
| `{{PROVIDER_URL}}` | API base url | |
| `{{PROVIDER_AUTH}}` | 鉴权方式（api key / header / 无） | |
| `{{TRANSPORT}}` | REST 还是 JSON-RPC | |
| `{{TX_ENDPOINT}}` | 查地址交易的接口 | |
| `{{TOKEN_TRANSFER_ENDPOINT}}` | 查地址代币转账的接口 | |
| `{{BALANCE_ENDPOINT}}` | 查地址代币余额的接口 | |
| `{{PAGINATION}}` | **按页还是游标分页** | |
| `{{HAS_BLOCK_NUMBER}}` | 交易响应是否带块号 | |
| `{{TYPE_FILTER_LOCATION}}` | 类型限定能否在请求参数做 | |

三个关键问题的影响：

| 回答 | 影响 |
|---|---|
| 游标分页 | `limit: usize` 表达不了，要在协议层多轮拉取或适配层 `.take(limit)` 兜底。**最容易踩的坑** |
| 不带块号 | 可以接受（Ankr 就不带），`TransactionReference::new(hash, None)`，排序托付上游 |
| 请求参数能限定 ERC-20 | 在协议 crate 写死，适配层保持纯转发（更干净） |

### 0.3 已定的决策

| 决策 | 内容 | 依据 |
|---|---|---|
| **不做声誉过滤** | 暂不判断垃圾币。**类型限定仍然保留** | 见 [§3.4](#34-过滤策略) |
| 不做 swap / NFT / 质押 | `is_swap_supported: false` 等 | 本次范围 |
| 走路 A（改 `gem_evm`） | 为了白拿 failover 和错误归因 | 见[参考文档 §7](编写自定义provider提供交易记录和代币发现.md) |

### 0.4 必须实测的三件事

```bash
# 1. chain id —— 从你要配置的那个 RPC 端点直接读，不要抄文档
curl -s -X POST {{RPC_URL}} -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}'

# 2. Multicall3 是否部署在标准地址（批量代币余额依赖它）
#    返回非 "0x" 即已部署
curl -s -X POST {{RPC_URL}} -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_getCode",
       "params":["0xcA11bde05977b3631167028862bE2a173976CA11","latest"],"id":1}'

# 3. 出块时间 —— 取两个相邻块的 timestamp 差
curl -s -X POST {{RPC_URL}} -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}'
```

**Multicall3 没部署的话停下来**：`gem_evm/src/provider/balances.rs` 的批量代币余额走它，缺了要额外写降级逻辑（逐个 `balanceOf`），那是本文范围外的额外工作。

---

## 1. 总览

| 阶段 | 内容 | 工时 |
|---|---|---:|
| 一 | 链注册（~20 处一行式改动 + 一个配置块） | 1~1.5 天 |
| 二 | 自定义 provider（协议 crate + 适配层 + 6 处注册） | 1~1.5 天 |
| 三 | 双端（生成 + 图标） | 0.5 天 |
| 验证 | 真实地址对账 | 1~2 天 |
| **合计** | | **3.5~5.5 天** |

阶段一和阶段二可以并行，但**先做阶段一**——provider 的 `for_chain` 需要 `EVMChain::{{CHAIN_ENUM}}` 这个变体存在才能编译。

### 前置：团队评审

上游 `docs/BLOCKCHAIN_REQUIREMENTS.md`（本地 HEAD 没有，在上游分支）要求新链先开 issue 走评审：主网已上线、共识与信任模型公开、**有公开的独立审计**、本地签名、节点/SDK 源码开放、余额与交易历史可靠、有响应及时的技术联系人。

**先确认 tscs 过得了这一关再写代码。** 自定义 provider 这件事本身说明 tscs 没有被 Alchemy/Ankr/Blockscout PRO 覆盖，评审时"交易历史可靠"这条需要你拿出证据。

### 版本提示

本地 HEAD 落后上游较多，两处位置在上游已搬家：

| 内容 | 本地 HEAD | 上游 |
|---|---|---|
| 节点健康检查样例 | `core/crates/settings_chain/src/node_check.rs` | `core/crates/primitives/src/node_check.rs` |
| Android 链属性 | `android/gemcore/.../ext/Chain.kt` 有穷举 `when` | 已改为从 Rust `ChainConfig` 读 |

**建议先 rebase 再开工**，否则阶段三会多做一批只在旧代码里存在的适配。

---

## 2. 阶段一：链注册

### 2.1 枚举

`core/crates/primitives/src/chain.rs`（Chain 枚举末尾）：

```rust
{{CHAIN_ENUM}},
```

`core/crates/primitives/src/chain_evm.rs`（EVMChain 枚举末尾）：

```rust
{{CHAIN_ENUM}},
```

> 序列化字符串由 `#[strum(serialize_all = "lowercase")]` 自动推导成 `{{CHAIN_SLUG}}`，不用手写。

### 2.2 链配置（唯一的实质配置块）

`core/crates/primitives/src/chain_config.rs`，在 `CHAIN_CONFIGS` 的 `Vec` 末尾追加：

```rust
ChainConfig {
    chain: Chain::{{CHAIN_ENUM}},
    network_id: "{{CHAIN_ID}}",
    denom: None,
    slip44: 60,
    chain_type: ChainType::Ethereum,
    default_asset_type: Some(AssetType::ERC20),
    account_activation_fee: None,
    token_activation_fee: None,
    minimum_account_balance: None,
    block_time: {{BLOCK_TIME_MS}},
    rank: {{RANK}},
    is_swap_supported: false,
    is_nft_supported: false,
    is_defi_supported: false,
    is_utxo: false,
    evm: Some(EvmChainConfig {
        min_priority_fee: {{MIN_PRIORITY_FEE}},
        chain_stack: ChainStack::{{CHAIN_STACK}},
        is_ethereum_layer2: {{IS_L2}},
        weth_contract: None,
    }),
    stake: None,
},
```

⚠️ **这是 `Vec` 不是 `match`，漏了不报编译错**——运行时 `chain.config()` 直接 panic。

### 2.3 一行式改动

| 文件 | 改什么 |
|---|---|
| `primitives/src/asset.rs` | `Chain::{{CHAIN_ENUM}} => ChainAsset::with_network_name(chain, "{{NETWORK_NAME}}", "{{NATIVE_NAME}}", "{{NATIVE_SYMBOL}}", {{NATIVE_DECIMALS}})` |
| `primitives/src/node_config.rs` | `Chain::{{CHAIN_ENUM}} => vec![Node::new("{{RPC_URL}}", NodePriority::High)]` |
| `primitives/src/block_explorer.rs` | `Chain::{{CHAIN_ENUM}} => vec![{{EXPLORER_NAME}}::boxed()]` |
| `primitives/src/explorers/` | **新建或复用**一个 explorer：`Explorer::boxed(Metadata::with_token("{{EXPLORER_NAME}}", "{{EXPLORER_URL}}"))`。Blockscout 系的加进 `explorers/blockscout.rs` |
| `primitives/src/explorers/etherscan.rs` | `EVMChain::{{CHAIN_ENUM}} => {{EXPLORER_NAME}}::new_{{CHAIN_SLUG}}()` |
| `primitives/src/wallet_connect_namespace.rs` | 两处（`:29` `:71`）；不支持 WC 就归到 `=> None` 那组 |
| `chain_primitives/src/token_id.rs` | 归到 EVM 的 `0x` 那组 |
| `gem_derivation/src/mnemonic/scheme.rs` | 归到 `DerivationScheme::Bip44` 那组 |
| `gem_derivation/src/private_key/path.rs` | 复用以太路径 `m/44'/60'/0'/0/0` |
| `gem_derivation/testdata/derivation_expectations.json` | 加派生测试向量 |
| `gem_evm/src/multicall3.rs` | `{{MULTICALL3}}` 已部署 → 归到 `0xcA11bde05977b3631167028862bE2a173976CA11` 那组 |
| `settings_chain/src/node_check.rs` | `Chain::{{CHAIN_ENUM}} => (DEFAULT_EVM_ADDRESS, Some("<一个真实交易哈希>"))`。主网刚上线没有样例交易时填 `None`，并照 Arc 的做法在测试里豁免并写明原因 |

### 2.4 价格（穷举 match，必改）

这两处**没有 `_ =>` 兜底**，不改编译不过：

```rust
// core/crates/coingecko/src/mapper.rs
// COINGECKO_CHAIN_PLATFORMS 表里加（有 platform 的话）
(Chain::{{CHAIN_ENUM}}, "{{COINGECKO_PLATFORM}}"),

// get_coingecko_market_id_for_chain 的 match 里
Chain::{{CHAIN_ENUM}} => "{{COINGECKO_MARKET}}",
// 没有上架 → Chain::{{CHAIN_ENUM}} => return None,
```

```rust
// core/crates/prices/src/providers/pyth/mapper.rs 的 price_feed_id_for_chain
Chain::{{CHAIN_ENUM}} => "{{PYTH_FEED}}",
// 没有 feed → 归到 return None 那组
```

> 原生币没上 CoinGecko/Pyth 是常见情况（新链基本都这样），填 `return None` 即可，不是错误。

### 2.5 RPC 路由（四处配套）

```yaml
# core/Settings.yaml 的 chains: 段
  {{CHAIN_SLUG}}:
    url: {{RPC_URL}}
```

```yaml
# core/apps/dynode/chains.yml
  - chain: {{CHAIN_SLUG}}
    urls:
      - url: {{RPC_URL}}
```

```rust
// core/crates/settings/src/lib.rs 的 Chains struct
pub {{CHAIN_SLUG}}: Chain,
```

```rust
// core/crates/settings_chain/src/lib.rs:203 附近
Chain::{{CHAIN_ENUM}} => &settings.chains.{{CHAIN_SLUG}},
```

### 2.6 阶段一验证

```bash
cd core
cargo build -p primitives -p gem_evm -p settings_chain
just test primitives
```

此时 tscs 应该已经能查原生币余额、查代币元数据、构造转账。**交易记录和代币发现还是空的**——那是阶段二。

---

## 3. 阶段二：自定义 provider

原理和架构约束见[参考文档](编写自定义provider提供交易记录和代币发现.md)。这里只给 tscs 的执行步骤。

关键约束回顾：`EVMIndexerClient` 是 `pub(crate)`（`gem_evm/src/rpc/indexer/mod.rs:30`），所以**适配层必须写在 `gem_evm` 里**，协议逻辑单独成 crate。

### 3.1 协议 crate

新建 `core/crates/{{PROVIDER_CRATE}}/`，照 `core/crates/gem_blockscout/` 的四件套：

```
src/lib.rs        导出 Client + 公开 model 类型
src/client.rs     请求构造 + 反序列化
src/model.rs      响应结构
src/testkit.rs    include_str! 指向 testdata/
testdata/*.json   真实响应样本
```

`model.rs` 要点（参考 `core/crates/gem_ankr/src/model.rs`）：

- 外层包装结构体用 `pub(super)`，只把真正要用的字段设 `pub`
- 数字字符串用 `serde_serializers::deserialize_biguint_from_str`
- 字段名用 `#[serde(rename_all = "camelCase")]` 对齐上游

注册 crate：`core/Cargo.toml` 的 workspace `members` 加 `crates/{{PROVIDER_CRATE}}`。

### 3.2 适配层

新建 `core/crates/gem_evm/src/rpc/{{PROVIDER_CRATE去掉gem_前缀}}.rs`。模板（以 `blockscout.rs` 为基准，两路合并 + `BTreeSet` 一步排序去重）：

```rust
use std::cmp::Reverse;
use std::collections::BTreeSet;
use std::error::Error;

use gem_client::Client as Transport;
use {{PROVIDER_CRATE}}::Client as {{PROVIDER_ENUM}}Client;
use num_bigint::BigUint;

use super::{EVMIndexerClient, TransactionReference};

impl<C: Transport> EVMIndexerClient for {{PROVIDER_ENUM}}Client<C> {
    async fn get_transactions_by_address(
        &self,
        address: &str,
        limit: usize,
    ) -> Result<Vec<TransactionReference>, Box<dyn Error + Send + Sync>> {
        // 两路：普通交易 + 代币转账。两路都打网络时用 try_join! 并发
        let (transactions, token_transfers) = futures::try_join!(
            self.get_transactions(address, limit),
            self.get_token_transfers(address, limit),
        )?;

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
        Ok({{PROVIDER_ENUM}}Client::get_token_balances(self, address)
            .await?
            .into_iter()
            // 类型限定必须保留（见 §3.4）。
            // 暂不做声誉过滤：数据源当前无 reputation/whitelist 信号。
            // 结果是空投垃圾币会进入资产列表，待数据源支持后在此补一行 filter。
            .filter(|balance| balance.token_type == "ERC-20")
            .map(|balance| (balance.contract_address, balance.value))
            .collect())
    }
}
```

按 `{{HAS_BLOCK_NUMBER}}` 调整：

- **带块号** → 照上面写
- **不带块号** → 用 `HashSet` 去重 + `TransactionReference::new(hash, None)`，顺序托付上游（照 `ankr.rs`）

按 `{{PAGINATION}}` 调整：

- **按页** → 直接传 `limit`
- **游标分页** → 协议层多轮拉取拼到 limit，或适配层 `.take(limit)` 兜底并接受可能不足

### 3.3 六处注册

| # | 位置 | 改什么 |
|---|---|---|
| 1 | `gem_evm/src/rpc/mod.rs:1-3` 旁边 | `mod {{模块名}};` |
| 2 | `gem_evm/src/rpc/indexer/mod.rs:36` | `Provider` enum 加 `{{PROVIDER_ENUM}}({{PROVIDER_ENUM}}Client<C>)` |
| 3 | 同上 `:42` | `ProviderKind` enum 加 `{{PROVIDER_ENUM}}` |
| 4 | 同上 `:73` | `name()` 返回 `"{{PROVIDER_NAME}}"` |
| 5 | 同上 `:82` | `impl EVMIndexerClient for Provider` 的**两个** match 各加一路分发 |
| 6 | 同上 `:108` | `for_chain` 加 `EVMChain::{{CHAIN_ENUM}} => vec![ProviderKind::{{PROVIDER_ENUM}}]`，以及闭包里的构造分支 |

配置：

```rust
// core/crates/settings/src/lib.rs:43 的 Indexer struct
pub {{provider字段名}}: ProviderSettings,
```

```yaml
# core/Settings.yaml:372 附近的 indexers: 段
  {{provider字段名}}:
    url: "{{PROVIDER_URL}}"
    key:
      secret: ""
```

```rust
// core/crates/settings_chain/src/lib.rs:76 的 EVMIndexer::for_chain(...) 调用
// 多传一个 client
```

⚠️ `for_chain` 现在是 5 个位置参数，加第 6 个会很难读。**可以考虑收成 struct，但别混在这次 PR 里。**

接进来自动获得：`try_in_order` 顺序 failover、`IndexerProviderError` 的 `{{PROVIDER_NAME}}: ...` 错误前缀、`MAX_PAGE_SIZE = 50` 上限保护。

### 3.4 过滤策略

`gem_blockscout` 的那一行 filter 做了**两件事**，本次只保留第一件：

| 过滤 | 本次 | 理由 |
|---|---|---|
| 类型限定 `== "ERC-20"` | ✅ **保留** | 见下 |
| 声誉判断 `reputation == "ok"` | ❌ 不做 | 数据源无信号，Alchemy 也不做，可逆 |

**类型限定为什么不能省**：ERC-721 漏进来后下游拦不住——`map_assets_balances` 只查零余额和地址合法性（NFT 余额是 1，通过），然后 `get_token_data` 批量 `eth_call` 查 `decimals()`，而 **ERC-721 没有 `decimals()`** → `map_token_data` 返回 `Err`。结果是加不进列表或显示异常，**且没有任何一层会告诉你原因**。

如果 `{{TYPE_FILTER_LOCATION}}` 显示能在请求参数里限定 ERC-20（像 Alchemy 的 `params: [addr, "erc20"]`），就在协议 crate 写死，适配层保持纯转发。

**不做声誉过滤的后果**：用户资产列表会出现空投垃圾币。零余额过滤挡不住（垃圾币余额通常不为零，这正是其手法）。要加就是一行 filter。

### 3.5 测试

按 [core/CLAUDE.md](core/CLAUDE.md)：完整 JSON 放 `testdata/` 用 `include_str!`，**不要在 Rust 文件里用 `json!` 内联**；一个 `test_<函数名>` 多断言。

| 测哪层 | 测什么 | 参考 |
|---|---|---|
| 协议 crate `client.rs` | **请求参数对不对**（断言 `params` 完整相等） | `gem_ankr/src/client.rs` |
| 适配层 | **响应映射对不对**（合并顺序、去重、类型过滤） | `gem_evm/src/rpc/blockscout.rs` |

testdata 必须放这些脏数据：

| 样本 | 验证 |
|---|---|
| 同一哈希出现在两路 | 去重生效（Blockscout 的 `0xshared`） |
| 块号乱序 | 排序生效 |
| 一条 ERC-721 | 类型限定生效 |
| 一条垃圾币 | **断言它当前会通过**——将来加声誉过滤时这个断言会失败，提醒你更新测试而不是悄悄改变行为 |

---

## 4. 阶段三：双端

### 4.1 生成

```bash
just generate
```

产出（**不要手改**）：
- iOS：`ios/Packages/Primitives/Sources/Generated/Chain.swift`、`ChainEvm.swift`
- Android：`android/gemcore/src/main/kotlin/com/wallet/core/primitives/generated/Chain.kt`、`ChainEvm.kt`

### 4.2 iOS

| 位置 | 改什么 |
|---|---|
| `ios/Packages/Style/Sources/Resources/Assets.xcassets/chains/` | 新建 `{{CHAIN_SLUG}}.imageset`（svg + `Contents.json`） |
| `ios/Packages/Style/Sources/Images.swift` | 注册图标 |
| `ios/Packages/PrimitivesComponents/Sources/Types/ChainImage.swift` | 仅当原生币复用别的链图标时（如 L2 用 ETH 图标） |

### 4.3 Android

上游版本链属性从 Rust `ChainConfig` 经 UniFFI 读，图标由生成的枚举解析，**基本 0 改动**。

⚠️ **当前本地 HEAD** 还有几处对 `Chain` 的穷举 `when`，加枚举成员会编译不过：

- `android/gemcore/src/main/kotlin/com/gemwallet/android/ext/Chain.kt` 的 `toChainType()` 和 `assetType()`
- `android/gemcore/src/main/kotlin/com/gemwallet/android/domains/asset/IconUrlGeneration.kt` 的"复用 ETH 图标"链清单

**先 rebase 能省掉这一整块。**

### 4.4 文档

[core/docs/FEATURES.md](core/docs/FEATURES.md) 三张表：

| 表 | 填什么 |
|---|---|
| 链能力表 | tscs 一行，`Address history` 填 `✅`（有自定义 provider），Swap/NFT/DeFi 填 `❌` |
| WalletConnect 覆盖表 | 按实际支持情况 |
| 交易索引 provider 表 | `{{PROVIDER_NAME}}` + 链接到你的适配层文件 |

按该文档开头的图例填（`✅` / `❌` / `➖` / `🏗️` / `⚪`），并更新 reviewed 日期。

---

## 5. 验证

按 CLAUDE.md：开发过程中只跑 targeted 命令，**最终验证集中跑一批**。

```bash
# Core
cd core
just test primitives
just test gem-evm
just test {{PROVIDER_CRATE去掉gem_前缀用连字符}}
cargo clippy -p primitives -p gem_evm -p {{PROVIDER_CRATE}} -- -D warnings
just format

# 绑定 + 双端
cd ..
just generate
cd ios && just build
cd ../android && just build
```

### 这条链路不会因为数据错误而报错

| 症状 | 真实原因 | 报错吗 |
|---|---|:---:|
| UI 显示"没有代币" | provider 返回空数组 / token indexer 没跑 | ❌ |
| 交易记录只有一半 | 上游历史回填未完成 | ❌ |
| 条数和 limit 不一致 | 分页参数被上游忽略 | ❌ |
| 某几笔凭空消失 | provider 返回了链上不存在的哈希，回查阶段 `warn` 后丢弃 | ❌ 只有日志 |
| 代币显示异常 | ERC-721 漏进来，`decimals()` 失败 | ❌ |
| 资产列表全是垃圾币 | 没做声誉过滤（本次有意如此） | ❌ |

对账发现条数少了，**先查日志里的 `transaction not found`**（`settings_chain/src/chain_providers.rs`）。

### 必须用真实地址对账

| 地址类型 | 验证 |
|---|---|
| 持有多种代币 | 代币发现数量与浏览器一致 |
| 空地址 | 返回空数组而不是报错 |
| 大量历史 | limit 真的生效、顺序是倒序 |
| 只有代币转账无原生转账 | 两路合并没漏单路 |
| 同一哈希在两路都出现 | 去重生效，不重复显示 |
| 持有 NFT | NFT 没被当成代币 |
| — | 原生币余额与浏览器对数 |
| — | 交易状态 pending → confirmed → failed 三态各走一遍 |
| — | 派生地址与官方测试向量逐字节比对 |
| — | 签出的交易能在链上广播成功 |

**"接口返回 200"不是验证通过。** 跳过的记录、吞掉的错误、没测的分支要显式说出来。

---

## 6. 安全检查

本次改动碰到了 `gem_derivation`（派生路径 + 测试向量），属于[高风险模块](skills/security.md)（`密钥 / 签名`）。

| 检查项 | 要求 |
|---|---|
| `{{CHAIN_ID}}` 实测确认 | **从目标 RPC 读到的值**，不是抄文档。填错 = 交易发错链 |
| 派生测试向量 | 与官方向量逐字节比对，自己造的不算 |
| `slip44: 60` | 确认 tscs 确实与以太共用派生路径 |
| 地址校验拒测试网地址 | EVM 地址格式相同，靠 chain id 区分——确认 WalletConnect 的 `eip155:{{CHAIN_ID}}` 正确 |
| 无密钥落盘 | 本次不应新增任何日志/持久化路径 |
| AI 参与度 | `gem_derivation` 部分任务卡填「不参与」或「辅助」，人工编写 + 技术负责人 Review |
| 溯源注释 | AI 生成的代码加 `// @ai-generated: claude \| YYYY-MM-DD \| T00X` |

---

## 7. 提交

建议拆两个 PR，别混在一起：

| PR | 内容 | 理由 |
|---|---|---|
| 1 | 链注册（阶段一 + 阶段三） | 可独立验证：余额、转账、代币元数据。地址历史暂为空 |
| 2 | 自定义 provider（阶段二） | 独立 review provider 的映射逻辑和过滤策略 |

commit message 按仓库惯例（`<type>: <中文描述>` + 中文 body）：

```
feat: 接入 tscs（chain id {{CHAIN_ID}}）

作为 EVM 家族成员接入：{{NATIVE_SYMBOL}} 为原生币，标准 EIP-1559 手续费，
{{MULTICALL3说明}}，{{EXPLORER_NAME}} 浏览器，不支持 swap / NFT / 质押。

{{价格接入说明：CoinGecko platform "xxx" + market "yyy" / 暂无上架，返回 None}}

地址历史和代币发现由自定义 provider {{PROVIDER_NAME}} 提供，见后续 PR。
```

```
feat: 接入 {{PROVIDER_NAME}} 作为 tscs 的索引 provider

提供 tscs 的地址交易历史和代币自动发现，接进 EVMIndexer 的 failover 链。

实现要点：
1. 交易记录合并两路（普通交易 + 代币转账），{{去重排序方式}}。
2. 代币发现保留 ERC-20 类型限定；暂不做声誉过滤——数据源当前无
   reputation/whitelist 信号，空投垃圾币会进入资产列表，待数据源支持后补。
   testdata 里保留了垃圾币样本并断言其当前通过，加过滤时该断言会失败以提醒更新。
3. {{分页说明：按页直接传 limit / 游标分页需多轮拉取}}
```

---

## 8. 完整改动清单

### 阶段一：链注册

- [ ] `core/crates/primitives/src/chain.rs` — `Chain` 枚举
- [ ] `core/crates/primitives/src/chain_evm.rs` — `EVMChain` 枚举
- [ ] `core/crates/primitives/src/chain_config.rs` — **配置块（漏了运行时 panic）**
- [ ] `core/crates/primitives/src/asset.rs` — 原生资产
- [ ] `core/crates/primitives/src/node_config.rs` — 默认 RPC
- [ ] `core/crates/primitives/src/block_explorer.rs` — 浏览器映射
- [ ] `core/crates/primitives/src/explorers/` — 新建或复用 explorer
- [ ] `core/crates/primitives/src/explorers/etherscan.rs` — EVMChain → explorer
- [ ] `core/crates/primitives/src/wallet_connect_namespace.rs` — **两处**
- [ ] `core/crates/chain_primitives/src/token_id.rs` — token id 格式
- [ ] `core/crates/gem_derivation/src/mnemonic/scheme.rs` — Bip44
- [ ] `core/crates/gem_derivation/src/private_key/path.rs` — 派生路径
- [ ] `core/crates/gem_derivation/testdata/derivation_expectations.json` — **测试向量**
- [ ] `core/crates/gem_evm/src/multicall3.rs` — Multicall3 地址
- [ ] `core/crates/settings_chain/src/node_check.rs` — 健康检查样例
- [ ] `core/crates/coingecko/src/mapper.rs` — **穷举，必改**
- [ ] `core/crates/prices/src/providers/pyth/mapper.rs` — **穷举，必改**
- [ ] `core/crates/settings/src/lib.rs` — `Chains` struct
- [ ] `core/Settings.yaml` — `chains:` 段
- [ ] `core/apps/dynode/chains.yml` — 节点代理
- [ ] `core/crates/settings_chain/src/lib.rs` — chain → settings

### 阶段二：自定义 provider

- [ ] `core/crates/{{PROVIDER_CRATE}}/` — 协议 crate（lib/client/model/testkit + testdata）
- [ ] `core/Cargo.toml` — workspace members
- [ ] `core/crates/gem_evm/src/rpc/{{模块名}}.rs` — 适配层
- [ ] `core/crates/gem_evm/src/rpc/mod.rs` — `mod` 声明
- [ ] `core/crates/gem_evm/src/rpc/indexer/mod.rs` — `Provider` enum
- [ ] 同上 — `ProviderKind` enum
- [ ] 同上 — `name()`
- [ ] 同上 — **两个** match 分发
- [ ] 同上 — `for_chain`
- [ ] `core/crates/settings/src/lib.rs` — `Indexer` struct
- [ ] `core/Settings.yaml` — `indexers:` 段
- [ ] `core/crates/settings_chain/src/lib.rs` — `for_chain` 调用传 client
- [ ] `core/crates/gem_evm/Cargo.toml` — 依赖协议 crate

### 阶段三：双端与文档

- [ ] `just generate`
- [ ] iOS 图标 imageset + `Images.swift`
- [ ] Android 穷举 `when`（**仅本地 HEAD 需要；rebase 后可跳过**）
- [ ] `core/docs/FEATURES.md` 三张表

### 验证

- [ ] `just test` 相关 crate
- [ ] `cargo clippy -- -D warnings`
- [ ] `just format`
- [ ] iOS + Android 构建
- [ ] 真实地址对账（[§5](#5-验证) 的 10 项）
- [ ] 安全检查（[§6](#6-安全检查)）
