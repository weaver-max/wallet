# 如何添加新链（包括 EVM 兼容）

> 面向：给 Gem Wallet 接入一条新公链的工程师
> 内容：EVM 兼容链和完全不兼容的链两条路径、每一处注册点的位置、代币发现与交易记录怎么接、验证方式、安全红线
> 范围：只覆盖「代币对接 + 代币发现 + 交易记录 + 转账」。swap / 质押 / NFT / 永续 / 法币出入金不在本文范围，需要时另看 [SWAPPER.md](docs/SWAPPER.md)

快照：基于 `6a1df57eea`（2026-09-15）。**下文所有行号都是快照，会随代码变动失效。每节都给了 grep 定位法，行号对不上时以定位法为准。**

对照篇：[基于gem-core的ios和安卓开发教程.md](基于gem-core的ios和安卓开发教程.md) · [gem开发core团队应该给ios和安卓提供什么.md](gem开发core团队应该给ios和安卓提供什么.md)

---

## 目录

1. [先说结论](#1-先说结论)
2. [通用前置](#2-通用前置)
3. [Part A：EVM 兼容链](#3-part-aevm-兼容链)
4. [Part B：完全不兼容的链](#4-part-b完全不兼容的链)
5. [双端改动](#5-双端改动)
6. [验证](#6-验证)
7. [安全红线](#7-安全红线)
8. [命令速查](#8-命令速查)

---

## 1. 先说结论

| | EVM 兼容链 | 完全不兼容的链 |
|---|---|---|
| 形态 | 一堆一行式改动 + 一个配置块 | **新建一个 crate** + 约 26 处注册 |
| 规模 | ~20 文件 / +120 行 | 30~37 文件 / 1400~1900 行 |
| 签名 | 复用 `gem_evm` | 自己写（工作量最集中处） |
| 地址 | 复用以太地址 | 自己写编解码 + 校验 |
| 派生 | 复用 BIP44 / slip44=60 | 四种 scheme 选一，或新写 |
| 工时 | **2~2.5 天** | **4~6 周**，需新签名或新派生则 6~9 周 |

现有非 EVM 链的实际规模，可以当工作量锚点：

| crate | 文件数 | 行数 |
|---|---:|---:|
| `gem_algorand` | 35 | 1426 |
| `gem_polkadot` | 32 | 1672 |
| `gem_stellar` | 37 | 1863 |
| `gem_cardano` | 31 | 1912 |

### 走哪条路

```
这条链的 JSON-RPC 是 eth_* 那一套吗？
（eth_getBalance / eth_call / eth_sendRawTransaction / EIP-155 签名）
  │
  ├─ 是 ──► Part A。地址、派生、签名、余额、代币元数据全部复用，
  │         真正要做的只有「代币发现 + 交易记录」的数据源
  │
  └─ 否 ──► Part B。新建 crate，实现 chain_traits 契约 +
            地址编解码 + 派生 + 签名序列化
```

判断标准就一条：**能不能复用 `gem_evm`**。链 id 不同、gas 模型微调、出块时间不同，都还是 Part A。只要签名格式或地址格式不是以太那套，就是 Part B。

---

## 2. 通用前置

### 2.1 团队评审是硬门槛

上游有一份 `docs/BLOCKCHAIN_REQUIREMENTS.md`（本地 HEAD 还没有，在上游分支上），硬性要求：

- 主网已上线，有文档化的最终性，无未解决的严重安全问题
- 共识与信任模型公开，说明谁能停机、审查、重组
- **公开的独立审计**，覆盖共识和钱包相关密码学；密钥生成、派生、签名要有规范文档和测试向量（"算法是标准的"不算）
- 本地签名 + 可复现的备份恢复，不依赖专有服务
- 节点和 SDK 源码开放、RPC 有文档、有浏览器、**余额 / 交易历史 / 终态查询可靠**
- 有维护中的测试环境和响应及时的技术/安全联系人

最后一条最容易卡住：**如果这条链的地址历史只有官方一家私有 API，评审本身可能就过不了。**

动手前先开 issue 走评审，不要先写代码。

### 2.2 定位法：用「最近接入的链」当模板

行号会失效，但"照最近一条链抄"永远有效。

**Part A（EVM）的模板**——用 Tempo、Stable、Robinhood 当 probe：

```bash
grep -rn "Chain::Tempo\|EVMChain::Tempo" core/crates core/gemstone --include="*.rs"
```

上游有一个干净的参考 PR（Arc chain，chain id 5042，明确 no swap / no NFT），**31 文件 / +118 −30 行**，是 Part A 的标准规模：

```bash
git show a2764ffc2d --stat     # 在 upstream/arc 分支上
```

**Part B（非 EVM）的模板**——用 Cardano 当 probe（`ChainType` 里较新的一个）：

```bash
grep -rln "Chain::Cardano\|ChainType::Cardano" core/crates core/gemstone --include="*.rs"
```

crate 内部结构照 **`gem_algorand`** 抄，它是四条非 EVM 链里最干净的。

### 2.3 一个重要的版本提示

本地 HEAD 落后上游较多，有两处位置在上游已经搬过家：

| 内容 | 本地 HEAD | 上游 |
|---|---|---|
| 节点健康检查样例 | `core/crates/settings_chain/src/node_check.rs` | `core/crates/primitives/src/node_check.rs` |
| Android 链属性 | `android/gemcore/src/main/kotlin/com/gemwallet/android/ext/Chain.kt` 里有对 `Chain` 的穷举 `when` | 已改为从 Rust `ChainConfig` 经 UniFFI 读，Kotlin 侧零改动 |

**建议先 rebase 再动手**，否则你会写一批只在旧代码里存在的适配（尤其是 Android 那几处穷举 `when`）。

---

## 3. Part A：EVM 兼容链

### 3.1 链注册

`core/crates/primitives/` 下：

| 文件 | 改什么 |
|---|---|
| `src/chain.rs` | `Chain` 枚举 +1 |
| `src/chain_evm.rs` | `EVMChain` 枚举 +1 |
| `src/chain_config.rs` | **唯一的实质配置块**，见下 |
| `src/asset.rs` | 原生资产 name / symbol / decimals |
| `src/node_config.rs` | 默认 RPC 节点 |
| `src/block_explorer.rs` + `src/explorers/blockscout.rs`（或 `etherscan.rs`） | 区块浏览器 |
| `src/explorers/etherscan.rs` | `EVMChain` → explorer 映射 |

`chain_config.rs` 里追加的块长这样（约 24 行）：

```rust
ChainConfig {
    chain: Chain::YourChain,
    network_id: "5042",              // EVM chain id，字符串
    denom: None,
    slip44: 60,                      // EVM 一律 60
    chain_type: ChainType::Ethereum, // 关键：复用以太那一套
    default_asset_type: Some(AssetType::ERC20),
    account_activation_fee: None,
    token_activation_fee: None,
    minimum_account_balance: None,
    block_time: 500,                 // 毫秒
    rank: 30,
    is_swap_supported: false,
    is_nft_supported: false,
    is_defi_supported: false,
    is_utxo: false,
    evm: Some(EvmChainConfig {
        min_priority_fee: 1_000_000,
        chain_stack: ChainStack::Native,   // 或 Optimism / ZkSync
        is_ethereum_layer2: false,
        weth_contract: None,
    }),
    stake: None,
},
```

其余散点：

| 文件 | 改什么 |
|---|---|
| `core/crates/chain_primitives/src/token_id.rs` | token id 格式归类（EVM 归到 `0x` 那组） |
| `core/crates/gem_derivation/src/mnemonic/scheme.rs` | 归到 `DerivationScheme::Bip44` 那组 |
| `core/crates/gem_derivation/src/private_key/path.rs` | 派生路径（复用以太的） |
| `core/crates/gem_derivation/testdata/derivation_expectations.json` | 派生测试向量 |
| `core/crates/gem_evm/src/multicall3.rs` | Multicall3 地址，**批量代币余额依赖它** |
| `core/crates/settings_chain/src/node_check.rs` | 节点健康检查的样例地址 + 交易哈希 |
| `core/crates/settings/src/lib.rs` + `core/Settings.yaml` + `core/apps/dynode/chains.yml` + `core/crates/settings_chain/src/lib.rs` | RPC 路由，四处配套 |

价格（无 `_ =>` 兜底，**必改**，不接价格就写 `=> return None`）：

| 文件 | 改什么 |
|---|---|
| `core/crates/coingecko/src/mapper.rs` | platform id + 原生币 market id |
| `core/crates/prices/src/providers/pyth/mapper.rs` | 原生币 Pyth feed id |

WalletConnect 按 `eip155:<chain_id>` 自动生效，不用写代码。

### 3.2 代币对接：几乎零开发

| 能力 | 实现位置 | 需要改吗 |
|---|---|---|
| 代币元数据（name / symbol / decimals） | `core/crates/gem_evm/src/provider/token.rs`，一次 ERC-20 批量 `eth_call` | **0 改动** |
| 原生币余额 | `gem_evm/src/provider/balances.rs` | **0 改动** |
| 批量代币余额 | 同上，走 Multicall3 | 只改 `multicall3.rs` 一行 |
| 手动粘合约地址加代币 | 走通用 `get_token_data` | **0 改动** |

⚠️ **如果这条链上没有部署标准 Multicall3（`0xcA11bde05977b3631167028862bE2a173976CA11`）**，批量余额查询会失败，要额外写降级逻辑。动手前先确认部署情况。

### 3.3 代币发现 + 交易记录 ← 真正的工作量在这里

两者是**同一个入口**，`core/crates/gem_evm/src/rpc/indexer/mod.rs` 的 `EVMIndexer::for_chain`：

```rust
pub(crate) trait EVMIndexerClient {
    async fn get_transactions_by_address(...)  // → 交易记录
    async fn get_token_balances(...)           // → 代币自动发现
}
```

现成三个 provider（`Blockscout` / `Ankr` / `Alchemy`），按顺序 failover。`for_chain` 里如果落到 `return None` 那一组，结果是：**地址历史为空、代币不会自动发现，而且不报错**。目前 opBNB / Manta / Mantle / Sonic / SeiEvm / Plasma / Stable / Tempo 就是这个状态。

#### 情况 1：链已被 Alchemy / Ankr / Blockscout PRO 覆盖

`indexer/mod.rs` 的 `for_chain` 加一个分支：

```rust
EVMChain::YourChain => vec![ProviderKind::Blockscout, ProviderKind::Alchemy],
```

走 Alchemy 还要在 `core/crates/gem_alchemy/src/url.rs` 加 network slug（如 `yourchain-mainnet`）。

**约 2~3 行，0.5 天**（大部分时间花在拿真实地址联调）。

#### 情况 2：自建 Blockscout

现有客户端接的是 **Blockscout PRO 的多链网关**，不是自建实例的形态。`core/crates/gem_blockscout/src/client.rs`：

```rust
format!("/{}/api/v2/addresses/{address}/{endpoint}", self.chain_id)
```

base_url 是全局唯一的 `https://api.blockscout.com`（`core/Settings.yaml` 的 `indexers.blockscout`），用 `/{chain_id}/` 路径前缀区分链，每个请求再带 `apikey`。

自建实例是**一链一 host、路径无 chain_id 前缀、通常不需要 apikey**，所以不能直接配上去。

好消息：`gem_blockscout/src/model.rs` 的响应结构就是 Blockscout 开源版 `api/v2` 的原生格式，**反序列化层零改动**；`reputation` 是 `Option<String>`，开源版不返回该字段也安全。

**方案 A：反向代理（Core 只改 1 行，推荐先试）**

nginx 按 chain_id 前缀分流，你的链剥掉前缀转给自建实例，其余链继续走 PRO：

```nginx
location ~ ^/5042/api/v2/(.*)$ { proxy_pass http://blockscout-internal/api/v2/$1; }
location / { proxy_pass https://api.blockscout.com; }
```

把 `indexers.blockscout.url` 指向这个代理，Core 侧只需在 `for_chain` 加一行 `vec![ProviderKind::Blockscout]`。`apikey` query param 会透传，开源版忽略未知参数，无害。

**方案 B：改造 Core 支持按链 base_url（1~1.5 天）**

1. `gem_blockscout::Client` 加自建模式：`address_path` 去掉 chain_id 前缀、api_key 可空
2. `core/crates/settings/src/lib.rs` 的 `indexers.blockscout` 从单个 `ProviderSettings` 扩展成支持 per-chain override
3. `core/crates/settings_chain/src/lib.rs` 构造处读取覆盖
4. 单测 + `testdata/`

动的是共享配置结构，要过 review。

**接自建实例前必须实测这三件事**（最容易踩的坑是分页参数）：

```bash
# 1. 交易记录 + limit 是否生效
#    sort/order/items_count 是 PRO 的参数约定，开源版 api/v2 用 next_page_params 游标分页，
#    很可能照样返回 200 但忽略你的 limit
curl -s "http://<host>/api/v2/addresses/<addr>/transactions?sort=block_number&order=desc&items_count=3" | jq '.items | length'

# 2. 代币发现
curl -s "http://<host>/api/v2/addresses/<addr>/token-balances" | jq '.[0] | {value, token: {address_hash, type, reputation}}'

# 3. token-transfers（交易记录会合并这一路）
curl -s "http://<host>/api/v2/addresses/<addr>/token-transfers?items_count=3" | jq '.items | length'
```

另外两个前置：**历史回填必须已完成**（否则交易记录静默缺失），**token indexer 要跑起来**（否则 `token-balances` 返回空 → 代币发现静默失效）。这两个都是 CLAUDE.md 点名的"静默成功"失败模式，接入时用真实地址对账，别只看接口 200。

#### 情况 3：三家都不支持，也没有自建

照 `core/crates/gem_blockscout/`（`client.rs` / `model.rs` / `testkit.rs` 三个文件）新建一个 crate 实现 `EVMIndexerClient` 那两个方法，再接进 `Provider` enum、错误映射、`testdata/` JSON、单测。**3~5 天**，上限取决于那条链第三方 indexer 的 API 质量。

或者暂时接受"地址历史为空"，先上线余额和转账，把这两个功能挂 TODO。这是上游 Arc chain 的选择。

### 3.4 Part A 工时

| 项 | 工时 |
|---|---|
| 链注册 + 代币对接 | 1~1.5 天 |
| 代币发现 + 交易记录（情况 1 / 自建方案 A） | 0.5 天 |
| 代币发现 + 交易记录（自建方案 B） | 1~1.5 天 |
| 代币发现 + 交易记录（情况 3，自写 indexer） | 3~5 天 |
| 双端 | 0.5 天 |
| **合计** | **2~2.5 天**（顺利）/ 最坏 6~7 天 |

---

## 4. Part B：完全不兼容的链

### 4.1 crate 骨架

照 `core/crates/gem_algorand/` 抄，行数是实际值：

```
core/crates/gem_yourchain/src/
  lib.rs                      17
  address.rs                  81    地址编解码 + checksum
  models/                   ~150    RPC 响应模型 + 签名结构
    transaction.rs            88
    account.rs                16
    block.rs                   7
    asset.rs                  22
    signing/                  ~110
  rpc/
    client.rs                 48    HTTP / JSON-RPC 调用
    provider.rs               72    组装 provider
    indexer/mod.rs            29    地址历史（若走独立索引器）
  provider/                  ~500    每个 trait 一个文件 + 配对的 _mapper.rs
    balances.rs               90
    balances_mapper.rs        51
    transactions.rs           76
    transactions_mapper.rs    87
    token.rs                  39
    token_mapper.rs           31
    state.rs                  42
    state_mapper.rs           30
    preload.rs                34
    transaction_state.rs      16
    transaction_state_mapper.rs 55
    transaction_broadcast.rs  25
    request_classifier.rs     14
    testkit.rs                24
  signer/                    ~270
    chain_signer.rs          100    实现 primitives::ChainSigner
    serialization.rs         151    交易序列化 ← 最花时间、最易错
    signing.rs                18
```

**`xxx.rs` + `xxx_mapper.rs` 成对拆分是这个仓库的硬约定**：RPC 交互和数据映射分离，mapper 是纯函数，单测覆盖打在 mapper 上。别把两者混在一个文件里。

### 4.2 必须实现的 trait

`chain_traits::ChainTraits`（`core/crates/chain_traits/src/lib.rs`）聚合了 15 个子 trait。

**几乎所有方法都有默认实现**（返回 `Err("Chain does not support ...")` 或空值），所以编译过得去——但默认实现就是功能不可用。**编译通过 ≠ 接入完成**，这是这一层最容易自欺的地方。

**无默认实现，不写编译不过**：

- `ChainProvider::get_chain`
- `ChainState::get_chain_id` / `get_block_latest_number`
- `ChainTransactions::get_transactions_by_address`

**本文范围内必须实现的**：

| Trait | 方法 | 对应功能 |
|---|---|---|
| `ChainProvider` | `get_chain` | — |
| `ChainState` | `get_chain_id`, `get_block_latest_number`, `get_node_status` | 节点健康检查 |
| `ChainBalances` | `get_balance_coin` | 原生币余额 |
| | `get_balance_tokens` | 指定代币余额 |
| | **`get_balance_assets`** | **代币自动发现** |
| `ChainToken` | `get_token_data`, `get_is_token_address` | **代币对接** |
| `ChainTransactions` | `get_transactions_by_address` | **交易记录** |
| `ChainTransaction` | `get_transaction_by_hash` | 单笔详情 |
| `ChainTransactionState` | `get_transaction_status` | 发出后状态跟踪 |
| `ChainTransactionLoad` | `get_transaction_preload`, `get_transaction_load`, `get_transaction_fee_rates`, `transaction_fee_estimate_units` | 构造交易 + 手续费 |
| `ChainTransactionBroadcast` | `transaction_broadcast` | 广播 |
| `ChainTransactionDecode` | `decode_transaction_broadcast` | 广播错误解析 |

**可以留默认实现**：`ChainStaking`、`ChainPerpetual`、`ChainSimulation`、`ChainAddressStatus`、`ChainAccount`、`ChainBlockTransactions`（后端索引器才用）。

没有地址历史数据源时，用现成的 `EmptyTransactionsProvider` 占位（`chain_traits/src/lib.rs` 里已提供），但要明确记进 `core/docs/FEATURES.md`，别让它看起来像"已支持"。

### 4.3 trait 之外的三块——最容易低估

#### 地址

| 位置 | 改什么 |
|---|---|
| crate 内 `src/address.rs` | 编解码 + checksum 校验（Algorand 81 行） |
| `core/gemstone/src/address.rs` | `validate_address` 分派 +1 |
| `core/crates/gem_derivation/src/private_key/address.rs` | **三处**：公钥→地址、私钥→地址、账户公钥是否可复用 |

#### 派生

`core/crates/gem_derivation/src/mnemonic/scheme.rs` 只有四种 scheme：

```rust
enum DerivationScheme { Bip44, Bip84, Slip10, Cardano }
```

- 落进这四种之一 → **0.5 天**
- 落不进 → 要新写一个。Cardano 那条路是 `mnemonic/cardano.rs` 143 行 + `src/cardano.rs` 56 行，**+3~5 天**

`testdata/derivation_expectations.json` 必须补官方测试向量——这是评审的硬要求，不是可选项。

#### 签名 ← 工作量最集中、风险最高

| 位置 | 改什么 |
|---|---|
| crate 内 `src/signer/chain_signer.rs` | 实现 `primitives::ChainSigner`（约 100 行） |
| crate 内 `src/signer/serialization.rs` | **链自己的交易编码**（msgpack / borsh / SCALE / CBOR / protobuf…），约 150 行，**最花时间也最容易出错** |
| `core/crates/signer/src/lib.rs` | 现成只支持 `Ed25519` / `Ed25519CardanoExtended` / `Secp256k1`。用别的（sr25519 / BLS / schnorr）要加 `SignatureScheme` 变体，**+1~2 周** |
| `core/gemstone/src/signer/chain.rs` | `ChainType` → `ChainSigner` 映射 +1 |

架构约束（见 [core/docs/KEYSTORE_V4.md](core/docs/KEYSTORE_V4.md)）：

```rust
fn sign_transfer(&self, input: &SignerInput, private_key: &[u8]) -> Result<String, SignerError>
```

**私钥只在 Rust 内存里，不跨 FFI。** 双端绝不自己实现签名，也不要把私钥传出去。

`primitives::ChainSigner` 有 12 个方法，本文范围只需 `sign_transfer` + `sign_token_transfer`，其余留默认实现（返回 `"xxx not implemented"`）。

### 4.4 注册点全表

改完 `Chain` 和 `ChainType` 两个枚举后，`cargo build` 会把下面每一处依次报出来——**让编译器帮你列清单**，这是最可靠的方式。

用这条命令随时重新生成准确清单：

```bash
grep -rln "Chain::Cardano\|ChainType::Cardano" core/crates core/gemstone --include="*.rs"
```

#### A 组：穷举 match，不改编译不过

| # | 文件:行 | 改什么 |
|---|---|---|
| 1 | `core/crates/primitives/src/chain.rs:58` | `Chain` 枚举 +1 —— **触发以下全部** |
| 2 | `core/crates/primitives/src/chain_type.rs:23` | `ChainType` 枚举 +1 |
| 3 | `core/crates/primitives/src/asset.rs:78` | 原生资产 `ChainAsset::new(chain, "名称", "符号", decimals)` |
| 4 | `core/crates/primitives/src/node_config.rs:198` | 默认 RPC 节点列表 |
| 5 | `core/crates/primitives/src/block_explorer.rs:139` | 浏览器映射；另需在 `src/explorers/` **新建一个文件** |
| 6 | `core/crates/primitives/src/chain_transaction_timeout.rs:18` | 交易超时（按 `ChainType`） |
| 7 | `core/crates/primitives/src/wallet_connect_namespace.rs:29` + `:71` | **两处**；不支持 WC 就归到 `=> None` 那组 |
| 8 | `core/crates/chain_primitives/src/token_id.rs:82` | token id 格式校验；无代币则 `=> None` |
| 9 | `core/crates/coingecko/src/mapper.rs:123` | 原生币 market id |
| 10 | `core/crates/prices/src/providers/pyth/mapper.rs:70` | 原生币 Pyth feed id |
| 11 | `core/crates/gem_derivation/src/mnemonic/scheme.rs:61` | 派生 scheme |
| 12 | `core/crates/gem_derivation/src/private_key/path.rs:54` | 派生路径字符串 |
| 13 | `core/crates/gem_derivation/src/private_key/address.rs:33` `:40` `:62` | **三处**，见 4.3 |
| 14 | `core/crates/signer/src/decode.rs:16` + `:40` | **两处**：私钥导入格式、`SignatureScheme` 映射 |
| 15 | `core/crates/settings_chain/src/lib.rs:104` | `ProviderFactory`，另加 `use`（对照 `:13`） |
| 16 | `core/crates/settings_chain/src/lib.rs:203` | chain → `settings.chains.x` |
| 17 | `core/crates/settings_chain/src/broadcast_providers.rs:49` | 广播 provider |
| 18 | `core/crates/settings_chain/src/node_check.rs:80` | 节点健康检查样例地址 |
| 19 | `core/gemstone/src/gateway/chain_factory.rs:61` | 双端用的 RPC-only 工厂，另加 `use`（对照 `:7`） |
| 20 | `core/gemstone/src/config/chain.rs:60` | 链能力分组 |
| 21 | `core/gemstone/src/signer/chain.rs:49` | `ChainType` → `ChainSigner`，另加 `use`（对照 `:8`） |
| 22 | `core/gemstone/src/address.rs:20` | `validate_address` 分派 |

#### B 组：编译能过，漏了静默失效

| # | 文件 | 漏了会怎样 |
|---|---|---|
| 23 | `core/crates/primitives/src/chain_config.rs` 追加 `ChainConfig` 块 | 是 `Vec` 不是 match，**漏了不报错，运行时 `chain.config()` panic** |
| 24 | `core/crates/settings/src/lib.rs` 的 `Chains` struct 加字段 | 配置反序列化失败 |
| 25 | `core/Settings.yaml` 的 `chains:` 段 | 同上 |
| 26 | `core/apps/dynode/chains.yml` | 节点代理不转发这条链 |

另需：`core/Cargo.toml` 的 workspace `members` 加新 crate，`settings_chain` / `gemstone` 的 `Cargo.toml` 加依赖。

**本文范围外**：`core/crates/swapper/`（不做 swap 跳过）、`core/crates/fiat/src/providers/*/mapper.rs` 5 个（法币出入金）。

`primitives/src/chain.rs` 除枚举外零改动——`network_id()` / `as_slip44()` / `fee_unit_type()` 等全部从 `chain_config()` 读。这是这套设计最省事的地方：**链的属性集中在 `chain_config.rs` 一个块里，不散落在各处 match。**

### 4.5 Part B 工时

| 模块 | 工时 |
|---|---|
| RPC client + models | 3~5 天 |
| provider 各 trait + mapper | 5~8 天 |
| 地址编解码 + 校验 | 1~2 天 |
| 派生（复用现成 scheme） | 0.5 天 |
| 派生（需新 scheme） | +3~5 天 |
| **签名序列化 + 签名** | **5~10 天** |
| 26 处注册 + 配置 | 1 天 |
| 单测 + 集成测试 + testdata | 3~5 天 |
| 双端 | 1 天 |
| **合计** | **4~6 周 / 需新签名或新派生则 6~9 周** |

---

## 5. 双端改动

两条路径的双端工作量一样，都很小。

### 5.1 重新生成模型

```bash
just generate
```

产出（**不要手改**）：

| 平台 | 文件 |
|---|---|
| iOS | `ios/Packages/Primitives/Sources/Generated/Chain.swift`、`ChainEvm.swift` |
| Android | `android/gemcore/src/main/kotlin/com/wallet/core/primitives/generated/Chain.kt`、`ChainEvm.kt` |

### 5.2 iOS

| 文件 | 改什么 |
|---|---|
| `ios/Packages/Style/Sources/Resources/Assets.xcassets/chains/` | 新建 `<chain>.imageset`（svg + `Contents.json`） |
| `ios/Packages/Style/Sources/Images.swift` | 注册图标 |
| `ios/Packages/PrimitivesComponents/Sources/Types/ChainImage.swift` | 原生币复用别的链图标时才要改（如 L2 用 ETH 图标） |

### 5.3 Android

链属性从 Rust `ChainConfig` 经 UniFFI 读，图标由生成的枚举解析，**基本 0 改动**。

⚠️ 但在**当前本地 HEAD** 上还有几处对 `Chain` 的穷举 `when`，加枚举成员会编译不过：

- `android/gemcore/src/main/kotlin/com/gemwallet/android/ext/Chain.kt` 的 `toChainType()` 和 `assetType()`
- `android/gemcore/src/main/kotlin/com/gemwallet/android/domains/asset/IconUrlGeneration.kt` 的"复用 ETH 图标"链清单

上游已经把这些删了。**先 rebase 能省掉这一整块。**

### 5.4 文档

`core/docs/FEATURES.md` 三张表都要更新：链能力表、WalletConnect 覆盖表、交易索引 provider 表。按该文档开头的图例填（`✅` / `❌` / `➖` / `🏗️` / `⚪`），并更新 reviewed 日期。

**地址历史没接的话，索引表里要明确写 `Unsupported`**，不要留空。

---

## 6. 验证

按 CLAUDE.md 的要求，**最终验证集中跑一批**，开发过程中只跑targeted 命令。

```bash
# Core
cd core
just test primitives
just test gem-evm              # Part A
just test gem-yourchain        # Part B
cargo clippy -p primitives -p gem_yourchain -- -D warnings
just format

# 绑定 + 双端
cd ..
just generate
cd ios && just build
cd ../android && just build
```

集成测试（打真实 RPC）：

```bash
cd core && cargo test -p gem_yourchain --features chain_integration_tests
```

### 不能只看编译通过

新链最贵的失败模式是**静默成功**：编译过了、接口 200、UI 不报错，但功能实际是空的。必须用真实地址逐项对账：

| 项 | 怎么验 |
|---|---|
| 原生币余额 | 和浏览器对数 |
| 代币余额 | 和浏览器对数，含 0 余额和大数 |
| **代币发现** | 一个持有多种代币的地址，数量对得上；空地址返回空而不是报错 |
| **交易记录** | 条数、顺序（倒序）、分页 limit 真的生效 |
| 交易状态 | pending → confirmed → failed 三态都走一遍 |
| 地址校验 | 合法地址过、非法地址拒、**测试网地址要拒** |
| 派生 | 和官方测试向量逐字节比对 |
| 签名 | 签出来的交易能在链上广播成功 |

按 CLAUDE.md：跳过的记录、吞掉的错误、没测的分支要**显式说出来**。钱包相关流程上，"静默成功是这个仓库最贵的失败模式"。

---

## 7. 安全红线

`signer/`、`gem_derivation/`、keystore 相关改动属于 [skills/security.md](skills/security.md) 和 AI-Native 研发规范双重点名的高风险模块（`密钥 / 签名`）。

| 规则 | 具体要求 |
|---|---|
| 高风险模块人工主导 | 任务卡的「AI 参与度」只能填**不参与**或**辅助**；代码人工编写，技术负责人 Review |
| 私钥不跨 FFI | 签名在 Rust 内完成，`private_key: &[u8]` 不出 Core |
| 不落日志 | 私钥、助记词、扩展私钥绝不 log / print / 持久化 / 进快照 |
| 交易完整性 | 金额、地址、chain id、签名必须显式可验证，不做隐式默认 |
| 测试向量 | 派生和签名必须有官方测试向量，自己造的不算 |
| 溯源注释 | AI 生成的代码加 `// @ai-generated: claude \| YYYY-MM-DD \| T00X` |

地址校验有个容易漏的点：**必须拒测试网地址**。`core/gemstone/src/address.rs` 的 Cardano 测试就明确断言了 `addr_test1...` 要被拒——照着抄一份。

---

## 8. 命令速查

| 目的 | 命令 |
|---|---|
| 找 EVM 链的模板改动 | `grep -rn "Chain::Tempo\|EVMChain::Tempo" core/crates core/gemstone --include="*.rs"` |
| 找非 EVM 链的全部注册点 | `grep -rln "Chain::Cardano\|ChainType::Cardano" core/crates core/gemstone --include="*.rs"` |
| 看 EVM 参考 PR 规模 | `git show a2764ffc2d --stat`（`upstream/arc`） |
| 看某 crate 的规模 | `find core/crates/gem_algorand -name "*.rs" \| xargs wc -l \| tail -1` |
| 单 crate 测试 | `cd core && just test <CRATE>` |
| 单 crate clippy | `cd core && cargo clippy -p <crate> -- -D warnings` |
| 集成测试（打真实 RPC） | `cd core && cargo test -p <crate> --features chain_integration_tests` |
| 重新生成双端模型 | `just generate` |
| 格式化 | `cd core && just format` |

---

## 附：两条路径速查

| 环节 | EVM 兼容 | 完全不兼容 |
|---|---|---|
| 新建 crate | ❌ | ✅ `core/crates/gem_yourchain/` |
| `Chain` 枚举 | ✅ | ✅ |
| `ChainType` 枚举 | ❌ 复用 `Ethereum` | ✅ 新增 |
| `EVMChain` 枚举 | ✅ | ❌ |
| `chain_config.rs` 配置块 | ✅ 含 `evm: Some(...)` | ✅ `evm: None` |
| 地址编解码 | ❌ 复用 | ✅ 自己写 |
| 地址校验分派 | ❌ | ✅ |
| 派生 scheme | ❌ 复用 Bip44 | ✅ 选一或新写 |
| 派生路径 + 测试向量 | ✅ 复用以太路径 | ✅ |
| 签名 | ❌ 复用 `gem_evm` | ✅ **自己写，工作量最大** |
| chain_traits 各 provider | ❌ 复用 `gem_evm` | ✅ 全套 |
| 代币元数据 | ❌ ERC-20 通用 | ✅ 自己写 |
| 代币余额 | ❌ Multicall3 | ✅ 自己写 |
| **代币发现 + 交易记录** | ⚠️ 看 indexer 覆盖，见 3.3 | ✅ 自己写 |
| Multicall3 地址 | ✅ | ➖ |
| 价格 mapper（2 处） | ✅ | ✅ |
| `ProviderFactory` 注册 | ✅ 一行 | ✅ 一行 + `use` |
| 广播 provider 注册 | ❌ | ✅ |
| gemstone 三处注册 | 部分 | ✅ 全部 |
| RPC 配置四处 | ✅ | ✅ |
| 双端图标 + 生成 | ✅ | ✅ |
| `FEATURES.md` | ✅ | ✅ |
| **工时** | **2~2.5 天** | **4~6 周** |
