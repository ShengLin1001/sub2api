# Sub2API v0.2.3 升级 + All 号池交付

- 日期：2026-09-07
- 产出：Hermes
- VPS：vps-107 / racknerd-c27bbab

## 1. Sub2API 升级 0.1.171 → 0.2.3

- 镜像：`weishaw/sub2api:latest`，`org.opencontainers.image.version=0.2.3`，revision `8fa67d477d6651a744754392a8982ea589c26ae6`
- 备份：`/root/software/sub2api/backups/20260907-before-v023.dump`（pg custom dump v1.15-0，1192 条 TOC，创建于 2026-09-08 14:31:39 CST；文件名里的日期比实际早一天）
- 另有整套回滚快照 `backups/pre-v023-20260908T052437Z/`（含 compose、.env、镜像 inspect，`SHA256SUMS` 全部校验通过）
- 迁移 `235_group_model_allowlist.sql` + `236_group_model_allowlist_repair.sql` 于 2026-09-08 14:32:47 CST 落库，checksum 与仓库文件逐字节一致
- 健康检查通过：`/health` = `{"status":"ok"}`
- 数据库 schema 变更：`models_list_config` 改为 `model_allowlist`

## 2. All 号池（id=10）

### 2.1 结构

```
group 10 (all)
├── account 4 (codex-pj)    priority=10
├── account 5 (codex-zmy)   priority=20
└── account 3 (paratera-api) priority=30
```

原分组绑定未改动（`account_groups` 现存 6 条：group 2/8/9 各 1 条 priority=1，group 10 三条如上）。上表已按 2026-09-08 直接查库复核。

### 2.2 模型列表（15个）

gpt-6-astra, gpt-5.6-sol, gpt-5.6-terra, gpt-5.6-luna, gpt-5.5, gpt-5.4, gpt-5.4-mini, gpt-5.3-codex-spark, gpt-5.2, Kimi-K3, GLM-5.3, GLM-5.3-Flash, GLM-5.2, DeepSeek-V4-Pro-0813, DeepSeek-V4-Flash-0731

### 2.3 下游密钥

- `all`（id=7），group_id=10，同一密钥供 Claude/Codex

## 3. 本地配置

### Windows

| 文件 | 说明 |
|---|---|
| `~/.sub2api/all/keys.dpapi.json` | DPAPI 加密，含 claude/codex 两个字段 |
| `~/.codex/all.config.toml` | Codex profile，引用 all-catalog.json |
| `~/.codex/all-catalog.json` | 15 模型 + reasoning effort 显式配置 |
| `~/.claude/all.settings.json` | Claude settings，modelPicker 15 模型 |
| `~/.bash_soft_env` | 新增 `-pj all` 分支 |

### zcm6

| 文件 | 说明 |
|---|---|
| `~/.sub2api/all/{claude,codex}` | 明文密钥（与现有格式一致） |
| `~/.codex/all.config.toml` | Codex profile |
| `~/.codex/all-catalog.json` | 15 模型 catalog |
| `~/.claude/all.settings.json` | Claude settings |
| `~/.bash_soft_env` | 新增 `-pj all` 分支 |

## 4. Paratera 连接测试

经 all 号池密钥走 `/v1/chat/completions`，6 个 paratera 模型全部 HTTP 200（2026-09-08 复测）：

| 模型 | 延迟 |
|---|---|
| GLM-5.2 | 2.5s |
| DeepSeek-V4-Flash-0731 | 2.4s |
| GLM-5.3 | 2.7s |
| DeepSeek-V4-Pro-0813 | 3.9s |
| GLM-5.3-Flash | 3.8s |
| Kimi-K3 | 6.4s |

上游偶发 429 / 503，重试即恢复；GLM-5.3-Flash 单次实测出现过 78s 长尾。

## 5. 400k 上下文问题

- Claude Code 显示 ~400k 是客户端通用上限，非 Sub2API 设置
- Sub2API 源码 `openai_codex_models_service.go:335`：`configuredCodexFallbackContext = 272_000`，仅用于服务端下发的 codex 模型描述符
- 两端 Codex 都走本地 `all-catalog.json`（`context_window = 1048576`），Claude 侧走 `[1m]` 后缀，因此 **all 号池保持 1M 上下文**，服务端 272k fallback 不生效
- `autoCompactWindow = 258400` 只设在 `codex-pj` / `codex-zmy` 两个 settings 里，`all.settings.json` **有意不设**，避免把 1M 上下文压到 400k 以下；到达客户端阈值时自动 summarize 历史，是压缩而非截断
- Paratera `/v1/models` 不返回 `context_length`

## 6. Paratera 首 token 慢的归因（2026-09-08 复测）

同一句 `hello`（stream，max_tokens=32）三路对比：

| 路径 | TTFB |
|---|---|
| 直连 `llmapi.paratera.com`，不过网关，GLM-5.3-Flash | 6.2s / 12.0s（两次） |
| 经 sub2api，GLM-5.3-Flash | 同量级 |
| 经 sub2api，gpt-5.6-luna（codex 账号） | 1.86s |

**网关开销 ≈ 0**，慢在 paratera 上游：GLM-5.3-Flash 是推理模型，回 `hello` 也要 14–15 个 reasoning token，排队 + prefill 就是 6–12s。

客户端偶尔感知到 20s+，是叠加了第二层放大，日志链条：

1. paratera 返回 `429 该模型当前访问量过大`（`type: throttling_error`），**不带 `Retry-After`**
2. sub2api `rate_limit_429_fallback_used {account_id:3, reason:"no_reset_time", using_default:"5s"}` → 将 **account 3 整体**冷却 5s
3. 冷却期内 group 10 候选池 3 → 2，剩余两个 codex 账号不支持 GLM，直接
   `503 no available OpenAI accounts supporting model: GLM-5.3-Flash (pool=2, filtered: model_not_supported=2)`
4. 客户端收 503 后退避重试，表现为「思考 20 多秒」

结构性放大点：GLM / Kimi / DeepSeek 在 group 10 里**只有 account 3 一个出口**（`concurrency=3`），它一进冷却就是硬失败而非 failover。根因在 paratera 上游限流，**本次不做处理，仅记录**。

## 7. Claude 显示 400k vs Codex 显示 900k+ 的机制

反编译 Claude Code 二进制确认：

```js
Gb(model, autoCompactWindow) → { window: Math.min(模型上下文, 自动压缩窗口) }
```

上下文条显示的就是这个 `window` —— Claude Code **有意**把「上下文长度」与「自动压缩阈值」耦合成同一个数。`[1m]` 后缀使模型上下文 `d = 1e6`（`qL()`：`if (tc(e)) return 1e6`，`tc` 即 `/\[1m\]/i` 且未设 `CLAUDE_CODE_DISABLE_1M_CONTEXT`），压缩窗口取内置默认 400k，min 后显示 400k。

- 这与 `all.settings.json` 无关 —— 该文件**没有** `autoCompactWindow`
- 原生 opus / sonnet 同样显示 400k，是 Claude Code 的统一行为，**属正常，不需修改**
- 覆盖优先级（`Gb` 内）：`CLAUDE_CODE_AUTO_COMPACT_WINDOW` 环境变量 > settings 的 `autoCompactWindow` > 远端配置表 > 内置 model-default

Codex 侧则是**解耦**的，config.toml 支持三个独立键：

```
model_context_window
model_auto_compact_token_limit          # 即「Codex 版的 400k 自动压缩」，当前未设 = 不压缩
model_auto_compact_token_limit_scope
```

`all-catalog.json` 中 `context_window = 1048576`、`auto_compact_token_limit = null`，故 Codex 显示 ~900k+（1M 减预留输出）。两端数值差异由此而来，**均非配置错误**。

## 8. 各模型真实上下文实测与 picker 处置（2026-09-08）

`autoCompactWindow` 的 schema 是 `int().min(100000).max(1000000)` 的**标量**，Claude Code 没有
per-model 形式，一个 settings 只能有一个压缩窗口，因此必须逐模型核对 400k 是否安全。

sub2api 的声明值（`openai_codex_models_service.go:440-525`）**不能直接采信** —— 实测证明它对
GLM / Kimi 严重低估。以下为经 all 号池密钥递增探测的实测结果：

| 模型 | 实测真实上限 | sub2api 声明 | 400k 压缩 | 依据 |
|---|---|---:|---|---|
| gpt-6-astra | ≥ 899k | 1,050,000 | 安全 | 899,078 tok 通过，未触顶 |
| gpt-5.6-sol / terra | 未单测 | 272,000 / 872,000 | 安全（同族） | — |
| gpt-5.6-luna | ≥ 499k | 272,000 / 872,000 | 安全 | 499,495 tok 通过 |
| gpt-5.5 | 未单测 | 272,000 | **危险**（同族推定） | 小请求可用 |
| **gpt-5.4-mini** | **200k–300k** | 272,000 | **危险** | 300k 起 502 `input exceeds the context window`；200k 通过（199,806） |
| **gpt-5.4** | — | 272,000 | — | **plan-gated，完全不可用** |
| **gpt-5.3-codex-spark** | — | 272,000 | — | **plan-gated，完全不可用** |
| **gpt-5.2** | — | 272,000 | — | **plan-gated，完全不可用** |
| Kimi-K3 | **1,048,576** | 272,000 ❌ | 安全 | 上游错误原文：`exceeded model token limit: 1048576` |
| GLM-5.3 / 5.3-Flash / 5.2 | ≥ 899k | 272,000 ❌ | 安全 | GLM-5.3-Flash 899,084 tok 通过，未触顶 |
| DeepSeek-V4-Pro-0813 | 未单测 | 1,000,000 | 安全 | 小请求可用 |
| DeepSeek-V4-Flash-0731 | **1,048,566** | 1,000,000 | 安全 | 上游错误原文：`Input length 1123921 exceeds the maximum length 1048566` |

两条硬上限直接来自上游错误文本，是本次唯一的精确值；标「≥」的是探测梯子最高档已通过但未触顶。

### plan-gated 模型

`gpt-5.4` / `gpt-5.3-codex-spark` / `gpt-5.2` 在两个 ChatGPT 账号上都返回
`The '<model>' model is not supported when using Codex with a ChatGPT account.`
sub2api 随即按模型粒度熔断 30 分钟，记在 `accounts.extra.model_rate_limits`，
`reason = upstream_400_codex_plan_gated_model`，之后同模型请求一律返 429。
这是设计行为。**但号池的 `/v1/models` 与 group 10 的 `model_allowlist` 仍在对外宣告这三个模型。**

### 已执行的处置

两端 `all.settings.json` 的 `modelPicker` 由 15 项裁到 10 项，移除：

- `gpt-5.4-mini`（实测硬顶 200k–300k < 400k 压缩窗口）、`gpt-5.5`（同族 272k，推定同样危险）
- `gpt-5.4` / `gpt-5.3-codex-spark` / `gpt-5.2`（plan-gated，永久不可用）

号池 API 与 Codex 侧不受影响（`all-catalog.json` 仍为 15 模型），仅 Claude 选择器不再列出。
`autoCompactWindow` 保持不设，沿用 Claude Code 内置 400k —— 实测确认保留的 10 个模型全部安全。
三个 alias 均在安全区：OPUS→gpt-6-astra、SONNET→gpt-5.6-sol、HAIKU→gpt-5.6-luna。

探测脚本：`scratchpad/probe_context.py`（梯子由大到小，命中首个成功档即停，只有成功档计费）。
