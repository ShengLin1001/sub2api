# Sub2API 后台 Reasoning Effort 映射表

- 日期：2026-09-06
- 产出：Claude
- 范围：当前工作树中的后端运行时代码、管理端配置及对应测试
- 口径：表中的“转发值”指 Sub2API 实际构造或保留在上游请求中的值；“记录值”指 `usage_log.reasoning_effort`，两者不是同一套归一化规则

## 1. 结论

Sub2API 没有一张对所有模型通用的静态 effort 表。最终行为由下列几层组合而成：

1. **分组策略**：OpenAI / Composite 分组可做精确映射和最大档位限制。
2. **协议转换**：Anthropic Messages、OpenAI Responses 和 Chat Completions 之间会转换字段、默认值和最高档名称。
3. **最终上游模型归一化**：模型映射完成后，GLM / DeepSeek 会把较宽的 OpenAI 档位收敛到原生 `high` / `max`。
4. **用量记录归一化**：日志会再次折叠值，不能据此反推请求原样发给了上游。
5. **模型列表声明**：Grok 的 `/models` 能力声明是给客户端看的元数据，不是全局转发规则。

最重要的快速查表如下：

| 最终上游模型或路径 | 客户端常见值 | 实际上游 effort 行为 | `usage_log` 行为 |
|---|---|---|---|
| GLM：`glm-*` | `low` / `medium` / `high` | 均转为 `high` | 显式值按 OpenAI 日志规则记录；若只有 `thinking=enabled/adaptive`，补记 `high` |
| GLM：`glm-*` | `xhigh` / `x-high` / `extra-high` / `max` / `ultracode` | 均转为 `max` | 通常折叠为 `xhigh`；`ultracode` 本身不进入通用日志档位 |
| DeepSeek：`deepseek-*` | `low` / `medium` / `high` | 均转为 `high` | 显式值按 OpenAI 日志规则记录；不做 thinking-only 默认补记 |
| DeepSeek：`deepseek-*` | `xhigh` / `x-high` / `extra-high` / `max` / `ultracode` | 均转为 `max` | 非 GPT-5.6 的显式 `max` 通常记为 `xhigh` |
| GPT-5.6 Sol / Terra / Luna | `low` / `medium` / `high` / `xhigh` / `max` | 普通 Responses、Chat Completions、API Key compact 均保留规范值 | `max` 仍记为 `max`，其余按规范值记录 |
| GPT-5.6 的 OpenAI OAuth `/responses/compact` | `max` | 特例降为 `xhigh` | 记为 `xhigh` |
| 其他 OpenAI 兼容模型 | `low` / `medium` / `high` / `xhigh` / `max` | 当前通用出站归一化保留这些值；`extra-high` 规范为 `xhigh` | `max` 折叠为 `xhigh`；`minimal` / `none` 不记录 |
| Kimi / Moonshot / MiniMax M / Qwen thinking 变体 | 仅 `thinking.type=enabled/adaptive`，无显式 effort | 不注入 effort 字段 | 仅日志补记 `high` |
| Anthropic 原生直连 | `output_config.effort` | 网关不按 Claude 型号重映射，通常透传 | `low` / `medium` / `high` / `xhigh` / `max` 可被日志识别 |
| Grok 4.5 / Grok Build 声明的可配置模型 | `low` / `medium` / `high` | 本层不做档位重映射 | `/models` 声明默认 `high` |
| Grok Composer | 任意 reasoning 控制字段 | `reasoning`、`reasoning_effort`、`reasoningEffort` 全部移除 | 不应把模型列表声明理解为 Composer 支持 effort |
| Bedrock Invoke | `output_config.effort` | 整个 `output_config` 被移除 | thinking 预算另行处理，不属于 effort 映射 |

> 当前工作树含一组尚未提交的既有修改：出站归一化已由 GLM 专用逻辑扩展为 GLM / DeepSeek 共用逻辑，并集中到实际发送前。本文按**当前工作树行为**汇总，而不是仅按最近一次 Git commit。

## 2. 字段与处理顺序

### 2.1 三种请求字段

| 协议 | 字段 |
|---|---|
| OpenAI Responses | `reasoning.effort` |
| OpenAI-compatible Chat Completions | `reasoning_effort` |
| Anthropic Messages | `output_config.effort` |

`thinking.type` / `thinking.budget_tokens` 是另一套控制面。它们在部分桥接路径中会随 effort 生成，但不能与 effort 档位直接等同。

### 2.2 OpenAI Responses / Chat Completions 请求

```text
客户端显式 effort
  → OpenAI / Composite 分组精确映射
  → 分组最大档位限制
  → 账号/渠道模型映射
  → 按最终上游模型做出站归一化
  → 发送上游

另行提取：显式字段 → 模型名后缀 → thinking-only 日志回退
  → usage_log.reasoning_effort
```

### 2.3 Anthropic Messages 转 OpenAI 上游

```text
output_config.effort（缺省则桥接为 medium）
  → GPT effort 后缀兼容处理
  → Anthropic → Responses 或 Chat Completions 映射
  → 根据最终 GPT-5.6 模型修正 max
  → 仅当客户端原本显式填写 output_config.effort 时应用分组策略
  → 按最终上游模型做 GLM / DeepSeek 出站归一化
  → 发送上游
```

这里有两个容易忽略的边界：

- `thinking.type` 不参与 Messages → OpenAI 的 effort 档位选择。
- 客户端省略 `output_config.effort` 时，桥接代码生成的 `medium` **不受分组 ceiling 影响**；这是有意保留的桥接默认值。

## 3. 分组级映射与上限

### 3.1 可配置平台与值域

只有以下分组平台支持 `max_reasoning_effort` 和 `reasoning_effort_mappings`：

- `openai`
- `composite`，但仅在该请求最终解析到 OpenAI 平台时生效

Anthropic、Gemini、Antigravity、Grok 分组填写非空策略会被拒绝。

管理端和后端共同使用六档值域：

```text
minimal < low < medium < high < xhigh < max
```

| 输入写法 | 配置中规范值 | 备注 |
|---|---|---|
| `minimal` | `minimal` | 最低可配置档 |
| `low` | `low` |  |
| `medium` | `medium` |  |
| `high` | `high` |  |
| `xhigh`、`x-high`、`x_high`、`extra high`、`extrahigh` | `xhigh` | 去除连字符、下划线和空格后识别 |
| `max` | `max` | 独立于 `xhigh`，排序更高 |
| `none` | 不支持 | 不是分组策略值 |
| 其他值 | 不支持 | 创建或更新配置时报错 |

### 3.2 执行规则

| 规则 | 实际行为 |
|---|---|
| 处理字段 | 同时遍历 `reasoning.effort` 与 `reasoning_effort` |
| 映射方式 | 精确匹配、单次映射 |
| 顺序 | 先 mapping，再 ceiling |
| 链式映射 | 不支持；`max→xhigh`、`xhigh→low` 对输入 `max` 的结果是 `xhigh` |
| 缺失字段 | 不生成，不会为了满足上限而“抬高”或注入值 |
| 空字符串 | 不处理 |
| 非字符串 | 不处理 |
| 未知显式值 | 无匹配时原样保留，ceiling 也无法给它排序 |
| 数量限制 | 最多 64 条 mapping |
| 重复来源 | 规范化后同一 `from` 只能出现一次 |

示例：mapping 配置为 `max → xhigh`，ceiling 为 `medium`，请求值为 `MAX`，最终转发值是 `medium`。

更新 API 对 mappings 使用三态语义：

- 字段省略：保持原配置；
- 空数组：清空；
- 非空数组：整体替换。

## 4. 最终上游模型的出站映射

出站归一化读取最终映射后的 `mappedModel`。因此客户端请求 Claude 或自定义别名、但账号最终映射到 `GLM-*` / `DeepSeek-*` 时，也会进入对应规则。

| 客户端/桥接后的值 | `glm-*` | `deepseek-*` | 其他模型族 |
|---|---|---|---|
| `low` | `high` | `high` | `low` |
| `medium` | `high` | `high` | `medium` |
| `high` | `high` | `high` | `high` |
| `xhigh`、`x-high`、`x_high` | `max` | `max` | `xhigh` |
| `extra-high`、`extra_high`、`extra high`、`extrahigh` | `max` | `max` | `xhigh` |
| `max` | `max` | `max` | `max` |
| `ultracode` | `max` | `max` | 不识别，原字段不改 |
| `minimal`、`none`、未知值 | 不识别，原字段不改 | 不识别，原字段不改 | 不识别，原字段不改 |

“原字段不改”不代表该值获得上游支持，只表示这个归一化器既不拒绝也不删除它，最终是否接受由上游决定。

实现还有一个字段优先级细节：先读取非空的 `reasoning.effort`，只有它为空时才读 `reasoning_effort`。如果两者同时存在，出站归一化只改前者；分组策略则会分别处理两者。

## 5. Anthropic 与 OpenAI 协议转换

### 5.1 Anthropic Messages → OpenAI Responses / Chat Completions

两个桥接入口使用相同映射：

| Anthropic `output_config.effort` | 桥接后的 OpenAI effort |
|---|---|
| 省略或空 | `medium` |
| `low` | `low` |
| `medium` | `medium` |
| `high` | `high` |
| `max` | 通常为 `xhigh` |
| 其他非空值 | 原样传入后续处理 |

`max` 还有最终模型修正：

| 最终 OpenAI 上游模型 | Anthropic `max` 最终发往上游 |
|---|---|
| GPT-5.6 Sol / Terra / Luna | `max` |
| 其他 GPT / 一般 OpenAI 模型 | `xhigh` |
| GLM / DeepSeek | 桥接值最终经族级归一化成为 `max` |

因此 `/v1/messages` 上的分组 mapping 实际匹配的是**转换后的 OpenAI 值**。例如，Anthropic `max` 发往旧 GPT 时已变为 `xhigh`，此时 `from: xhigh` 能匹配，`from: max` 不能匹配；发往 GPT-5.6 时则相反。

### 5.2 OpenAI Responses → Anthropic Messages

| OpenAI `reasoning.effort` | Anthropic `output_config.effort` | 生成的 `thinking` |
|---|---|---|
| 省略或空 | 不生成 | 不生成 |
| `low` | `low` | 不生成 |
| `medium` | `medium` | `enabled`，`budget_tokens=4096` |
| `high` | `high` | `enabled`，`budget_tokens=10240` |
| `xhigh` | `max` | `enabled`，`budget_tokens=32768` |
| `max` | `max`（运行时代码原样通过） | `enabled`，`budget_tokens=32768` |
| 其他非空值，如 `minimal` / `none` | 原样通过 | `enabled`，默认 `budget_tokens=10240` |

最后一行是实现边界，不是声明该值受 Anthropic 官方支持：转换器没有先校验值域，未知非空值会走 passthrough 和默认预算分支。

## 6. GPT / Codex 模型名后缀与 `max` 特例

### 6.1 模型别名归一化

OpenAI/Codex 路由会把已知 effort 后缀从模型名中剥离：

| 客户端模型名族 | 归一化上游模型 |
|---|---|
| `gpt-5.4-{none,low,medium,high,xhigh}` | `gpt-5.4` |
| `gpt-5.3-{none,low,medium,high,xhigh}` | `gpt-5.3-codex` |
| `gpt-5.3-codex-{low,medium,high,xhigh}` | `gpt-5.3-codex` |
| `gpt-5.2-{none,low,medium,high,xhigh}` | `gpt-5.2` |
| GPT-5.6 Sol / Terra / Luna 的已知 effort 或日期后缀 | 对应 Sol / Terra / Luna 基名 |
| 泛化 `gpt-5.6` | `gpt-5.6-sol` |
| `gpt-5`、`gpt-5.1` | `gpt-5.4` |
| `gpt-5.1-codex` | `gpt-5.3-codex` |
| `gpt-5.2-codex` | `gpt-5.2` |

通用可剥离后缀是：

```text
none, minimal, low, medium, high, xhigh，或 YYYY-MM-DD 日期
```

`max` 不属于通用后缀集合。`gpt-5.1-codex-max` 是单独登记的模型别名；GPT-5.6 对 `max` 另有专门识别逻辑。

在直接 OpenAI 路径中，仅从模型后缀推导出的 effort 主要用于恢复用量元数据；不能把“模型名被剥离”理解成所有路径都会额外注入一个 effort 字段。Anthropic Messages 兼容入口则会把已识别的 GPT 后缀转换成 `output_config.effort`，且客户端显式 `output_config.effort` 优先于后缀。

### 6.2 GPT-5.6 `max`

GPT-5.6 识别范围包括：

- 泛化 `gpt-5.6`；
- `gpt-5.6-sol`；
- `gpt-5.6-terra`；
- `gpt-5.6-luna`；
- provider 路径前缀、日期后缀和已知 effort 后缀变体。

| 路径 | GPT-5.6 输入 `max` |
|---|---|
| 普通 Responses | 保留 `max` |
| Chat Completions | 保留 `max` |
| OpenAI API Key `/responses/compact` | 保留 `max` |
| OpenAI OAuth `/responses/compact` | 降为 `xhigh` |
| Remote compaction v2 | 保留 `max` |
| 用量记录 | 保留为 `max` |

OpenAI OAuth compact 的降级是端点兼容特例：当前 ChatGPT compact 端点只接受到 `xhigh`。

## 7. 用量日志归一化

### 7.1 OpenAI 请求

提取优先级为：

1. `reasoning.effort`；
2. `reasoning_effort`；
3. 若两者都没有，则依次从 upstream、billing、original 等模型候选的末尾后缀推导。

多模型候选用于解决 OAuth 模型归一化已剥掉后缀、但原始模型名仍保留 `-high` / `-xhigh` / `-max` 的情况。

| 请求值或模型后缀 | 一般模型日志值 | GPT-5.6 日志值 |
|---|---|---|
| `none` | 空 / `NULL` | 空 / `NULL` |
| `minimal` | 空 / `NULL` | 空 / `NULL` |
| `low` | `low` | `low` |
| `medium` | `medium` | `medium` |
| `high` | `high` | `high` |
| `xhigh`、`x-high`、`extra-high` | `xhigh` | `xhigh` |
| `max` | `xhigh` | `max` |
| 未知值 | 空 / `NULL` | 空 / `NULL` |

这解释了一个看似矛盾的现象：非 GPT-5.6 的直接 OpenAI 请求可能把 `max` 原样发给上游，但日志仍记为 `xhigh`。

### 7.2 Anthropic 原生请求

`output_config.effort` 的日志归一化接受：

```text
low, medium, high, xhigh, max
```

空值或未知值记为空。兼容类型注释声明的常规 Anthropic 值域是 `low | medium | high | max`；日志额外接受 `xhigh`，这是内部兼容行为。

### 7.3 只有 thinking、没有 effort 的模型

当以下三个条件同时满足时，Sub2API 只在用量日志中补记 `high`：

1. 没有提取到显式 effort；
2. `thinking.type` 为 `enabled` 或 `adaptive`；
3. 最终映射模型属于 passback-required 白名单。

| 模型族 | thinking-only 日志回退 |
|---|---|
| `kimi-*` | `high` |
| `moonshot-*` | `high` |
| Kimi Code 裸别名 `k3`、`k3-256k` | `high` |
| `glm-*` | `high` |
| `minimax-m*` | `high` |
| `qwen-*` / `qwen2-*` / `qwen3-*` / `qwen4-*` 且名称含 `-thinking` | `high` |
| `deepseek-*` | 不补；显式 effort 或上游默认负责 |
| Claude / GPT / 未知模型 | 不补 |

此回退不改上游请求体，不等于为模型设置了 `reasoning_effort=high`。

## 8. Grok 特殊行为

### 8.1 `/models` 能力声明

只有以下模型 ID 会声明 `supportsReasoningEffort=true`：

- `grok-4.5`
- `grok-4.5-latest`
- `grok`
- `grok-latest`
- `grok-build`
- `grok-build-latest`
- `grok-build-0.1`

声明的选项为：

| 值 | 默认 |
|---|---|
| `low` | 否 |
| `medium` | 否 |
| `high` | 是 |

这是模型列表元数据。它没有自动给请求注入 `high`，也没有给 Grok 分组开启管理端 mapping / ceiling。

### 8.2 Composer 禁用 effort

最终模型为下列别名之一时，Responses 请求会删除全部 reasoning 控制形态：

- `grok-composer`
- `grok-composer-2.5-fast`
- `composer-2.5`
- 带 provider 路径前缀但末段等价的模型名

删除字段：

```text
reasoning
reasoning_effort
reasoningEffort
```

另外，Grok 的可选 Chat Completions → Responses 桥接若遇到非 `null` 的 `reasoning_effort`，会判定语义无法无损保留，让请求继续走原始 Chat Completions 路径，而不是静默丢弃该值。

## 9. 不属于 reasoning-effort 映射的 thinking 预算

以下逻辑虽然也控制“思考强度”，但不是 effort 档位表的一部分：

| 路径 / 模型 | thinking 行为 |
|---|---|
| OpenAI Responses → Anthropic | 根据 effort 生成 `thinking.type=enabled` 和 4096 / 10240 / 32768 预算，见第 5.2 节 |
| Bedrock Fable 5 | `enabled` 改为 `adaptive`；`enabled/adaptive` 均移除手工 `budget_tokens` |
| Bedrock Opus 4.7+ | `enabled` 改为 `adaptive` 并移除 `budget_tokens` |
| 其他 Bedrock 模型 | `enabled` 且未给预算时补 `10000` |
| Antigravity 高阶 Opus（4.6+） | `adaptive` 映射为 `thinkingBudget=24576` |
| Antigravity 其他 adaptive | 默认动态预算 `-1` |
| Antigravity Gemini 2.5 Flash | 正预算最多 `24576` |

Bedrock Invoke 还会直接删除 `output_config`，所以 Claude effort 不会经该路径原样到达 Bedrock。

## 10. 已知边界与不一致

1. **执行代码默认 `medium`，注释却写默认 `high`**：Messages → OpenAI 两个桥接函数实际初始化 `effort := "medium"`；附近旧注释称“两边默认 high”。本文按可执行代码和测试采用 `medium`。
2. **分组排序与日志排序不同**：分组中 `max` 是高于 `xhigh` 的独立档；一般 OpenAI 用量日志却把 `max` 折叠成 `xhigh`，只有 GPT-5.6 保留。
3. **`minimal` 跨层语义不一致**：分组策略接受 `minimal`，OpenAI 日志将其视为空，当前出站模型归一化也不主动规范它。
4. **未知值多处采用 passthrough**：分组执行器和协议桥接不会统一拒绝所有未知值；能否成功最终取决于上游。
5. **模型元数据不是运行时规则**：`model_prices_and_context_window.json` 中的 `supports_*_reasoning_effort` 字段没有查到 Go 运行时消费方，不应拿它替代上述请求转换代码。
6. **最终模型优先**：GLM / DeepSeek 规则按账号或渠道映射后的上游模型判定，而不是按客户端最初填写的模型名判定。

## 11. 源码依据

### 分组策略

- [`backend/internal/domain/reasoning_effort.go`](../../backend/internal/domain/reasoning_effort.go)：mapping 数据结构。
- [`backend/internal/service/openai_reasoning_effort_policy.go`](../../backend/internal/service/openai_reasoning_effort_policy.go)：值域、规范化、排序、mapping 与 ceiling 执行。
- [`backend/internal/service/openai_reasoning_effort_policy_test.go`](../../backend/internal/service/openai_reasoning_effort_policy_test.go)：单次映射、先映射后限高、缺失/未知/非字符串行为。
- [`backend/internal/handler/composite_platform.go`](../../backend/internal/handler/composite_platform.go)：Composite 平台判定及 Messages 显式值绑定。
- [`backend/internal/handler/admin/group_handler.go`](../../backend/internal/handler/admin/group_handler.go)：管理 API 字段及更新三态。
- [`frontend/src/views/admin/groupsReasoningEffort.ts`](../../frontend/src/views/admin/groupsReasoningEffort.ts)：管理端六档选项和校验。

### 模型与出站归一化

- [`backend/internal/service/gateway_request.go`](../../backend/internal/service/gateway_request.go)：GLM / DeepSeek 出站归一化、Claude 日志归一化和 thinking-only 回退。
- [`backend/internal/service/gateway_request_test.go`](../../backend/internal/service/gateway_request_test.go)：GLM、DeepSeek、Kimi、GPT-5.6 与未知模型用例。
- [`backend/internal/service/thinking_protocol.go`](../../backend/internal/service/thinking_protocol.go)：Claude strict 与国产 passback-required 模型族分类。
- [`backend/internal/service/openai_model_alias.go`](../../backend/internal/service/openai_model_alias.go)：GPT/Codex 别名和 GPT-5.6 识别。
- [`backend/internal/service/openai_codex_transform.go`](../../backend/internal/service/openai_codex_transform.go)：模型后缀与旧型号归一化。

### 协议转换与用量

- [`backend/internal/pkg/apicompat/anthropic_to_responses.go`](../../backend/internal/pkg/apicompat/anthropic_to_responses.go)：Messages → Responses 默认值及 `max→xhigh`。
- [`backend/internal/pkg/apicompat/chatcompletions_anthropic_bridge.go`](../../backend/internal/pkg/apicompat/chatcompletions_anthropic_bridge.go)：Messages → Chat Completions 同等映射。
- [`backend/internal/pkg/apicompat/responses_to_anthropic_request.go`](../../backend/internal/pkg/apicompat/responses_to_anthropic_request.go)：Responses → Messages effort 与 thinking budget。
- [`backend/internal/service/openai_compat_model.go`](../../backend/internal/service/openai_compat_model.go)：Messages 模型后缀及最终 GPT-5.6 `max` 修正。
- [`backend/internal/service/openai_gateway_request_body.go`](../../backend/internal/service/openai_gateway_request_body.go)：OpenAI 用量提取、后缀推导、日志归一化和 compact 特例。
- [`backend/internal/service/openai_reasoning_effort_candidates_test.go`](../../backend/internal/service/openai_reasoning_effort_candidates_test.go)：模型候选和后缀日志回退。
- [`backend/internal/service/openai_gpt56_max_test.go`](../../backend/internal/service/openai_gpt56_max_test.go)：GPT-5.6 普通请求与 compact 路径测试。

### Grok、Bedrock 与 Antigravity

- [`backend/internal/handler/gateway_handler.go`](../../backend/internal/handler/gateway_handler.go)：Grok `/models` reasoning 能力声明。
- [`backend/internal/pkg/xai/models.go`](../../backend/internal/pkg/xai/models.go)：Grok 默认模型和别名。
- [`backend/internal/service/openai_gateway_grok.go`](../../backend/internal/service/openai_gateway_grok.go)：Composer effort 字段删除。
- [`backend/internal/service/openai_gateway_grok_chat_bridge.go`](../../backend/internal/service/openai_gateway_grok_chat_bridge.go)：Chat → Responses 桥接准入。
- [`backend/internal/service/bedrock_request.go`](../../backend/internal/service/bedrock_request.go)：Bedrock 删除 `output_config` 及 thinking 兼容处理。
- [`backend/internal/pkg/antigravity/request_transformer.go`](../../backend/internal/pkg/antigravity/request_transformer.go)：Antigravity thinking budget 转换。
