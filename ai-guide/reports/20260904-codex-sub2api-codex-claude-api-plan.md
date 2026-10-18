# Sub2API 同时接入 Codex 与 Claude Code 的下一步计划

- 日期：2026-09-04
- 产出：Codex
- 目标仓库：`F:/BaiduSyncdisk/version20240608/main_code_space/other/sub2api`
- 部署目标：SSH 别名 `vps-107`
- 状态：实施前计划；尚未创建 Paratera 账户、分组或下游密钥

## 1. 结论

当前部署版本已经具备所需的协议转换能力，第一阶段不需要修改 Sub2API 源码。

建议只创建一套 Paratera 上游账户和一个专用 OpenAI 分组，再给 Codex 与 Claude Code 分别签发下游密钥：

```text
Codex
  POST /v1/responses
          |
          v
Sub2API paratera-agent 分组
  Responses -> Chat Completions
          |
          v
Paratera POST /v1/chat/completions

Claude Code
  POST /v1/messages
          |
          v
Sub2API paratera-agent 分组
  Anthropic Messages -> Chat Completions
          |
          v
Paratera POST /v1/chat/completions
```

Sub2API 再把上游结果分别转换回 Responses SSE 和 Anthropic Messages SSE。这样可以避开 Paratera 当前流式 `/v1/responses` 不能正常发出 `response.completed` 的问题。

需要特别说明：Anthropic 官方文档明确表示，其不支持通过第三方网关把 Claude Code 路由到非 Claude 模型。因此，Claude Code → Sub2API → GLM-5.3 是技术兼容路径，不是 Anthropic 官方支持的组合；Claude Code 升级后需要重新做回归测试。

## 2. 已核实的当前状态

### 2.1 VPS

- `vps-107` 可通过 SSH 访问。
- Sub2API、PostgreSQL、Redis 容器当前均处于健康状态。
- Sub2API 镜像版本为 `0.1.171`，镜像 revision 为 `f0e7a9c7a23a7d02fb159b62fa809621eb0475a6`。
- 当前数据库中已有 OpenAI OAuth 账户，但还没有 Paratera API Key 账户。
- 当前服务通过公网 `18080` 端口提供明文 HTTP，不能安全传输新的下游 API Key。

### 2.2 已部署版本具备的能力

已在部署 revision 上确认：

- `/v1/responses` 可以调度 OpenAI 平台分组。
- `/v1/messages` 可以在分组允许后调度 OpenAI 平台分组。
- OpenAI API Key 账户可以设置 `openai_responses_mode=force_chat_completions`。
- `/v1/responses` 可以转换到上游 `/v1/chat/completions`。
- `/v1/messages` 可以转换到上游 `/v1/chat/completions`，并把结果转换回 Anthropic Messages 格式。
- 已有文本、流式事件和工具调用转换测试，但 Paratera 的实际端到端工具调用仍需在账户接入后验证。

关键源码：

- [`backend/internal/server/routes/gateway.go`](../../backend/internal/server/routes/gateway.go)：注册 `/v1/messages`、`/v1/messages/count_tokens` 和 `/v1/responses`。
- [`backend/internal/service/openai_gateway_messages.go`](../../backend/internal/service/openai_gateway_messages.go)：Anthropic Messages 到 OpenAI/Chat Completions 的转换入口。
- [`backend/internal/service/openai_gateway_responses_chat_fallback.go`](../../backend/internal/service/openai_gateway_responses_chat_fallback.go)：Responses 到 Chat Completions 的转换入口。
- [`backend/internal/pkg/openai_compat/upstream_capability.go`](../../backend/internal/pkg/openai_compat/upstream_capability.go)：`force_chat_completions` 配置判定。

### 2.3 Paratera

当前实测结果：

- `GLM-5.3` 的 `/v1/chat/completions` 流式请求可以正常完成并返回 `[DONE]`。
- `GLM-5.3` 的 `/v1/responses` 非流式请求可以完成。
- `GLM-5.3` 的 `/v1/responses` 流式请求会在输出正文后返回内部错误，缺少 `response.completed`。

因此不能使用 Sub2API 的“自动检测”。自动检测若只看到非流式 Responses 成功，可能把 Paratera 误判为完整支持 Responses。账户必须显式选择“强制 Chat Completions”。

## 3. 目标配置

### 3.1 上游账户

在管理后台新建一个账户：

| 字段 | 建议值 |
|---|---|
| 名称 | `paratera-glm` |
| 平台 | OpenAI |
| 类型 | API Key |
| Base URL | `https://llmapi.paratera.com/v1` |
| API Key | 从安全位置录入现有 Paratera Key，不写入文档或 Git |
| Responses API 支持 | **强制 Chat Completions** |
| WebSocket | 关闭 |
| 状态 | 启用 |

不要把该账户加入现有 `openai-default`、`openai-zmy` 等 OAuth 分组，否则 Codex/Claude Code 请求可能被调度到错误的上游账户。

### 3.2 专用分组

新建一个 OpenAI 平台分组：

| 字段 | 建议值 |
|---|---|
| 名称 | `paratera-agent` |
| 平台 | OpenAI |
| 账户 | 仅 `paratera-glm` |
| 允许 `/v1/messages` 调度 | 开启 |
| Opus 映射模型 | `GLM-5.3` |
| Sonnet 映射模型 | `GLM-5.3` |
| Haiku 映射模型 | `GLM-5.3` |
| 模型列表 | 第一阶段仅暴露 `GLM-5.3` |
| RPM/并发 | 先设置保守值，稳定后再按观测调整 |

系列映射用于接住 Claude Code 发出的 `claude-opus-*`、`claude-sonnet-*` 和 `claude-haiku-*` 模型名。Codex 直接请求 `GLM-5.3`。

### 3.3 下游密钥

不要让两个客户端共用一把密钥。创建两把绑定到同一 `paratera-agent` 分组的下游密钥：

| 密钥名称 | 用途 | 本地环境变量 |
|---|---|---|
| `paratera-codex` | Codex | `SUB2API_PARATERA_CODEX_KEY` |
| `paratera-claude-code` | Claude Code | `SUB2API_PARATERA_CLAUDE_KEY` |

这样可以分别统计、限流、轮换和吊销。密钥值不得进入仓库、Shell 历史、截图或交付文档。

## 4. 实施顺序

### 阶段 0：安全前置与备份

1. 记录当前容器镜像 digest、revision 和 Compose 配置。
2. 使用 PostgreSQL 原生备份工具生成一次可恢复备份，并验证备份文件非空。
3. 轮换当前管理员密码。仓库中的既有 VPS 部署说明包含明文管理员凭据，不能继续沿用。
4. 将部署说明里的真实密码替换为占位符；不得把该文件提交到 Git，直到完成脱敏检查。
5. 在以下两种接入方式中选择一种：
   - 正式方案：域名 + HTTPS 反向代理；
   - 过渡方案：Sub2API 只经 SSH 本地端口转发访问。

过渡方案命令：

```powershell
ssh -N -L 18080:127.0.0.1:18080 vps-107
```

后续示例统一使用：

```text
http://127.0.0.1:18080
```

如果完成 HTTPS，则替换为实际 `https://` 域名。

### 阶段 1：后台配置

1. 在管理后台创建 `paratera-glm` OpenAI API Key 账户。
2. 明确选择“强制 Chat Completions”，不要选择“自动”。
3. 创建 `paratera-agent` OpenAI 分组。
4. 开启“允许 `/v1/messages` 调度”。
5. 将 Opus、Sonnet、Haiku 三类请求都映射到 `GLM-5.3`。
6. 仅把 `paratera-glm` 加入该分组。
7. 分别签发 Codex 和 Claude Code 下游密钥。

优先使用管理后台或管理 API，不直接修改数据库。

### 阶段 2：Codex 接入

保留现有 ChatGPT 登录和 `paratera` 直连 profile，新建独立 provider/profile。不要覆盖内置 `openai` provider。

在 `%USERPROFILE%/.codex/config.toml` 中加入：

```toml
[model_providers.sub2api_paratera]
name = "Sub2API Paratera"
base_url = "http://127.0.0.1:18080/v1"
env_key = "SUB2API_PARATERA_CODEX_KEY"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false

[profiles.sub2api-paratera]
model_provider = "sub2api_paratera"
model = "GLM-5.3"
```

Codex 自定义 provider 当前只支持 `responses` 作为 `wire_api`；这里由 Sub2API 把请求转给 Paratera Chat Completions。

只在启动该次会话的终端中使用由安全工具注入的密钥，不要把真实值写进命令历史：

```powershell
# SUB2API_PARATERA_CODEX_KEY 已由 secrets helper 注入当前进程
codex -p sub2api-paratera
```

### 阶段 3：Claude Code 接入

Claude Code 使用 Anthropic Messages 接口，因此 Base URL 不带 `/v1`：

```powershell
$env:ANTHROPIC_BASE_URL = 'http://127.0.0.1:18080'
$env:ANTHROPIC_AUTH_TOKEN = $env:SUB2API_PARATERA_CLAUDE_KEY
claude
```

`ANTHROPIC_AUTH_TOKEN` 会作为 Bearer token 发送给 Sub2API。该环境变量存在时，这个 Claude Code 进程不会使用已登录的 Claude 订阅凭据；关闭终端或清除变量即可回到订阅账户：

```powershell
Remove-Item Env:ANTHROPIC_BASE_URL -ErrorAction SilentlyContinue
Remove-Item Env:ANTHROPIC_AUTH_TOKEN -ErrorAction SilentlyContinue
```

第一阶段不要全局持久化这些变量，也不要执行 `/logout`。这样不会破坏现有 Claude Code 订阅登录。

对非官方 Base URL，Claude Code 默认关闭 MCP tool search。第一阶段保持 `ENABLE_TOOL_SEARCH` 未设置，只验证普通工具调用；只有确认 Sub2API 能完整转发 `tool_reference` 后才考虑启用。

## 5. 验收计划

所有测试都必须经过 Sub2API，不能只用 Paratera 直连结果代替。

### 5.1 基础接口

- `GET /health` 返回 200。
- 两把下游密钥都只能进入 `paratera-agent` 分组。
- `/v1/models` 只暴露计划允许的模型。
- Sub2API 日志显示上游实际调用 `/v1/chat/completions`，而不是 Paratera `/v1/responses`。

### 5.2 Codex

1. 新建一次短文本会话。
2. 完成一次本地只读工具调用，例如读取一个临时测试文件。
3. 确认流中存在正常终止事件，且不再出现：

   ```text
   stream closed before response.completed
   ```

4. 新会话通过后，再用新 profile 恢复此前失败的长会话。
5. 连续执行至少 10 个短回合，确认无重复断流和异常重试。

### 5.3 Claude Code

1. 用 `claude -p` 做一次纯文本请求。
2. 启动交互会话，执行一次只读 Bash/PowerShell 工具调用。
3. 再执行一次完整的工具调用往返：模型提出工具调用、客户端执行、工具结果返回模型、模型完成最终回答。
4. 检查流式事件可以正常结束，并确认 `/status` 显示自定义 Base URL。
5. 连续执行至少 10 个短回合，观察模型映射、上下文延续和工具调用稳定性。

### 5.4 通过标准

- Codex 文本与工具调用均完成，流中断问题不再出现。
- Claude Code 文本与工具调用均完成，不出现模型名不支持或事件格式错误。
- 两个客户端在后台分别产生可识别的用量记录。
- 禁用任意一把下游密钥不会影响另一客户端。
- 公网链路使用 HTTPS，或调用全程位于 SSH 隧道内。
- Paratera 上游 key 始终只保存在 Sub2API 服务端。

任何一项未满足，都只能标记为“部分兼容”，不能宣布正式切换完成。

## 6. 回滚方案

按以下顺序回滚，不删除历史数据：

1. 禁用 `paratera-codex` 和 `paratera-claude-code` 下游密钥。
2. 禁用 `paratera-agent` 分组。
3. 禁用 `paratera-glm` 上游账户。
4. Codex 切回原 `openai` 或 `paratera` profile。
5. 清除 Claude Code 的 `ANTHROPIC_BASE_URL` 和 `ANTHROPIC_AUTH_TOKEN`，重新启动后用 `/status` 确认恢复订阅登录。
6. 只有发生配置或数据损坏时才恢复 PostgreSQL 备份。

## 7. 第一阶段明确不做

- 不修改 Sub2API 源码；现有部署 revision 已具备所需转换入口。
- 不让 Codex 和 Claude Code 共用下游密钥。
- 不覆盖 Codex 内置 `openai` provider。
- 不注销 Claude Code 订阅账户。
- 不直接写数据库。
- 不宣称支持 Responses 专有的远程 compaction、background mode、WebSocket、内置 web search 等能力。
- 不在未验证 `tool_reference` 前开启 Claude Code MCP tool search。
- 不在公网明文 HTTP 上发送任何真实 API Key。

## 8. 建议的实施检查单

- [ ] 备份 PostgreSQL 并验证可读
- [ ] 轮换并脱敏现有明文管理员凭据
- [ ] 建立 HTTPS 或 SSH 隧道
- [ ] 创建 `paratera-glm` 账户
- [ ] 设置“强制 Chat Completions”
- [ ] 创建 `paratera-agent` 分组
- [ ] 开启 `/v1/messages` 调度
- [ ] 配置三类 Claude 模型映射到 `GLM-5.3`
- [ ] 创建两把独立下游密钥
- [ ] 新建 Codex 独立 profile
- [ ] 以进程级环境变量启动 Claude Code
- [ ] 完成 Codex 文本与工具调用验收
- [ ] 完成 Claude Code 文本与工具调用验收
- [ ] 完成 10 回合稳定性验证
- [ ] 记录最终配置、测试时间和回滚点，不记录密钥值

## 9. 参考资料

- OpenAI Codex 配置参考：<https://learn.chatgpt.com/docs/config-file/config-reference>
- Claude Code 环境变量：<https://code.claude.com/docs/en/env-vars>
- Claude Code LLM gateway 说明：<https://code.claude.com/docs/en/llm-gateway>
