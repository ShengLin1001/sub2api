# Sub2API 三 Provider 接入 Codex 与 Claude Code

- 日期：2026-09-05
- 产出：Codex
- 状态：本地三 Provider 接入与 Claude Code 模型选择器已完成；Paratera 端到端通过；codex-pj 与 codex-zmy 的 GPT-6 Astra 已完成映射、计费和真实请求验证

## 最终结构

~~~text
claude / codex
  ├─ 默认启动 ------------------------------> 原订阅登录
  └─ -pj <provider>
       ├─ paratera-api -> Sub2API group 9 -> paratera-api
       ├─ codex-pj     -> Sub2API group 2 -> codex-pj
       └─ codex-zmy    -> Sub2API group 8 -> codex-zmy
~~~

Claude Code 与 Codex 只在本次进程中切换 Base URL、下游密钥和默认模型。没有设置 `CLAUDE_CONFIG_DIR` 或 `CODEX_HOME`，因此本地 session、memory、skills、plugins、hooks 和其他用户状态继续共用原目录。

## 本地密钥目录

密钥统一放在：

~~~text
%USERPROFILE%\.sub2api\
├─ paratera-api\
│  └─ keys.dpapi.json   # claude、codex 两个密文字段
├─ codex-pj\
│  └─ keys.dpapi.json   # key 密文字段
└─ codex-zmy\
   └─ keys.dpapi.json   # key 密文字段
~~~

旧目录 `%USERPROFILE%\.sub2api-paratera` 已移除。

三组 provider 入口对应的实际下游密钥如下：

| Provider | Sub2API API key | ID | Group |
|---|---|---:|---|
| `paratera-api` for Codex | `paratera-codex` | 5 | `paratera-agent` / 9 |
| `paratera-api` for Claude Code | `paratera-claude-code` | 6 | `paratera-agent` / 9 |
| `codex-pj` | `codex-pj` | 4 | `openai-default` / 2 |
| `codex-zmy` | `codex-zmy` | 3 | `openai-zmy` / 8 |

Paratera 保留两把独立下游密钥，以继续区分 Claude Code 与 Codex 的用量、撤销和审计；另外两组各使用自己的单一 key，同时供两个客户端调用。

上述 Sub2API 下游 key 均由当前 Windows 用户的 DPAPI 加密。目录 ACL 仅允许当前用户和 `SYSTEM` 完全控制；这些 Sub2API key 未以明文写入 TOML、JSON settings 或 Bash 配置。

## 命令入口

入口统一定义在 `%USERPROFILE%\.bash_soft_env`：

~~~bash
claude
claude -pj paratera-api
claude -pj codex-pj
claude -pj codex-zmy

codex
codex -pj paratera-api
codex -pj codex-pj
codex -pj codex-zmy
~~~

为了兼容上一版命令，`paratera` 仍作为 `paratera-api` 的别名：

~~~bash
claude -pj paratera
codex -pj paratera
~~~

未知 provider 返回退出码 2。命令后的其他参数原样传给真实 CLI。

`get_sub2api_key <provider> <field>` 是唯一的 DPAPI 解密函数。Claude 和 Codex wrapper 都复用它；解密结果只进入 Bash 局部变量和目标 CLI 子进程环境，进程退出后消失。

## Codex 配置

用户级 `%USERPROFILE%\.codex\config.toml` 中只保留一个通用 provider：

~~~toml
[model_providers.sub2api]
name = "Sub2API"
base_url = "https://racknerd-c27bbab.tailaaf4af.ts.net/v1"
env_key = "SUB2API_API_KEY"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
~~~

三个 profile 文件：

| 文件 | Provider | 默认模型 |
|---|---|---|
| `~/.codex/paratera-api.config.toml` | `sub2api` | `GLM-5.3` |
| `~/.codex/codex-pj.config.toml` | `sub2api` | `gpt-5.6-sol` |
| `~/.codex/codex-zmy.config.toml` | `sub2api` | `gpt-5.6-sol` |

Bash wrapper 解密选定 key，临时设置 `SUB2API_API_KEY`，然后执行 `codex -p <provider>`。普通 `codex` 不注入该变量，继续使用原 ChatGPT 订阅登录。

Codex 官方配置机制是先加载 `~/.codex/config.toml`，再叠加 `~/.codex/<profile>.config.toml`；profile 只改变列出的 provider/model 字段，不需要复制整套 Codex 状态。[OpenAI Codex 配置参考](https://learn.chatgpt.com/zh-Hans/docs/config-file/config-reference)

旧 `~/.codex/paratera.config.toml` 和 `~/.local/bin/codex-paratera.ps1` 已移除。

## Claude Code 配置

三个附加 settings 文件：

| 文件 | 默认请求模型 | `/model` 可选模型 |
|---|---|---|
| `~/.claude/paratera-api.settings.json` | `GLM-5.3` | `GLM-5.3`、`GLM-5.3-Flash`、`GLM-5.2`、`DeepSeek-V4-Pro-0813`、`DeepSeek-V4-Flash-0731`、`Kimi-K3` |
| `~/.claude/codex-pj.settings.json` | `gpt-5.6-sol` | `gpt-6-astra`、`gpt-5.6-sol`、`gpt-5.6-terra`、`gpt-5.6-luna` |
| `~/.claude/codex-zmy.settings.json` | `gpt-5.6-sol` | `gpt-6-astra`、`gpt-5.6-sol`、`gpt-5.6-terra`、`gpt-5.6-luna` |

这些文件设置默认模型和 provider 专属 `modelPicker`，不重复 plugin、hook、skill 或 permission 配置。`modelPicker.replaceBuiltInOptions=true` 隐藏不属于当前 Sub2API key 的内置 Claude 模型；GPT 列表不包含裸 `gpt-5.6`、`gpt-5.5` 或更早版本。

Claude Code 的 gateway discovery 只把 ID 以 `claude` 或 `anthropic` 开头的模型加入选择器，无法发现当前 `GLM-*`、`DeepSeek-*`、`Kimi-*` 和 `gpt-*` ID，因此未保留无效的 `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY` 开关，改用 Claude Code v2.1.242+ 原生 `modelPicker`。[Claude Code LLM gateway model selection](https://code.claude.com/docs/en/llm-gateway)、[Claude Code settings reference](https://code.claude.com/docs/en/settings-reference#modelpicker)

Bash wrapper 为本次进程设置：

- `ANTHROPIC_BASE_URL=https://racknerd-c27bbab.tailaaf4af.ts.net`
- `ANTHROPIC_AUTH_TOKEN=<DPAPI 解密结果>`
- `claude --settings ~/.claude/<provider>.settings.json`

`--settings` 是高优先级的附加设置层，不会替换 `~/.claude/settings.json`；没有在附加文件中出现的字段继续从用户和项目配置加载。Claude 官方文档也说明，只有设置 `CLAUDE_CONFIG_DIR` 才会整体迁移 settings、session history 和 plugins。[Claude Code settings](https://code.claude.com/docs/en/settings)、[.claude directory](https://code.claude.com/docs/en/claude-directory)

因此三种第三方启动方式仍共同使用：

- `~/.claude/projects/`：session transcript 与 auto memory
- `~/.claude/skills/`：用户 skills
- `~/.claude/plugins/`：安装插件及其 hooks/skills
- `~/.claude/settings.json`：用户 permissions、enabledPlugins 等
- 当前项目中的 `CLAUDE.md`、`.claude/settings*.json` 和其他项目配置

普通 `claude` 不加载这些 provider settings，也不注入 gateway credential，继续使用原 claude.ai Pro 登录。

## Plugin、hook、skill 真实验证

使用 `claude -pj paratera-api --debug-file ... -p ...` 进行了真实第三方 provider 启动，不是只检查文件存在。

Claude Code 调试日志确认：

- 从 `C:\Users\louis\.claude\plugins\installed_plugins.json` 加载 2 个已安装插件。
- `claude-hud@claude-hud` 与 `ponytail@ponytail` 均为 enabled。
- 从 `C:\Users\louis\.claude\skills` 加载 3 个用户 skill。
- 从 Ponytail plugin 加载 6 个 plugin skill。
- 从插件注册 3 个 hook。
- `SessionStart:startup` hook 执行成功，并注入 `PONYTAIL MODE ACTIVE`。
- 模型调用 `p-code-style` 时，Skill tool 返回 `outcome=ok`。

三个 provider 分别运行 `auth status` 和 `plugin list` 后均得到：

~~~text
projectsDirectory=C:\Users\louis\.claude\projects
enabled_plugins=2
~~~

这证明 provider settings 不需要重复写 plugin 配置；它只覆盖 model 和 modelPicker，而插件、hook、skill 来自共同的 `~/.claude` 配置根。

## 验收结果

### 已通过

- `~/.bash_soft_env`：Bash 语法通过。
- 三个 Claude provider 和三个 Codex provider：profile/settings 均能解析并启动。
- 四个 DPAPI 密文字段：均能由当前 Windows 用户解密，长度校验通过。
- 默认 Claude：仍为 `claude.ai` / `Pro`。
- `paratera-api` + Claude Code：真实文本请求成功。
- `paratera-api` + Codex：真实 Responses 请求成功，启动信息显示 `provider: sub2api`、`model: GLM-5.3`。
- Claude Code 共享 plugin/hook/skill：运行时调试证据通过。
- 三个 Claude provider：均使用同一个 projects directory，并列出同样的 2 个 enabled plugins。
- Claude Code v2.1.263 实际启动 `claude -pj paratera` 后，`/model` 显示 `GLM-5.3` 及另外 5 个 provider 模型。
- Claude Code v2.1.263 实际启动 `claude -pj codex-pj` 后，`/model` 只显示 `gpt-6-astra`、`gpt-5.6-sol`、`gpt-5.6-terra`、`gpt-5.6-luna` 四个 provider 模型；`codex-zmy` 使用相同且已解析验证的 picker 配置。

### OpenAI OAuth 与 GPT-6 Astra

初次验收时两个 OpenAI OAuth 上游账号曾返回 `401 Token revoked: invalidated oauth token`。本次复查时，VPS 数据库中的 `codex-pj`（account 4）和 `codex-zmy`（account 5）均为 `status=active`、`schedulable=true`，旧阻塞状态已失效。

OpenAI 官方已经发布 GPT-6 Astra，准确模型 ID 为 `gpt-6-astra`。[GPT-6 Astra model](https://developers.openai.com/api/docs/models/gpt-6-astra)

`/backend-api/codex/models?client_version=0.153.4` 返回的两个 ChatGPT OAuth 上游 manifest 尚未列出 `gpt-6-astra`，但经用户明确授权后完成了实际能力验证：

1. 在 `/root/software/sub2api/backups/20260905-before-gpt6-astra.dump` 保存变更前完整 PostgreSQL 备份。
2. 为 `codex-pj`（account 4）和 `codex-zmy`（account 5）增加 `gpt-6-astra → gpt-6-astra` 身份映射，只重建 `sub2api` 容器刷新调度快照，并确认服务恢复 `healthy`。
3. 两把下游 key 的 `/v1/models` 均开始返回 `gpt-6-astra`。
4. 分别通过 Anthropic 兼容的 `/v1/messages` 发出 `max_tokens=1` 最小请求；两次均返回 HTTP 200、`model=gpt-6-astra`、`stop_reason=end_turn`，各使用 8 个输入 token 和 5 个输出 token。
5. 两条 usage log 均按 token 模式记录：输入 `$0.00008`、输出 `$0.00025`、总计及实际扣费 `$0.00033`。这与官方每百万输入 `$10`、输出 `$50` 的定价一致，未触发缺失定价或零计费。

因此 Astra 已加入两个 `modelPicker`；裸 `gpt-5.6`、`gpt-5.5` 和更早版本仍不显示。

## 安全与边界

- provider token 不写入 settings/TOML，不永久 export。
- wrapper 使用子 shell，代理和认证变量不会污染调用后的终端。
- 默认订阅登录未删除，也没有执行 `claude /logout` 或 `codex login`。
- 使用 gateway credential 时，Claude.ai connectors、Remote Control 和 voice 等依赖 claude.ai 身份的功能会在该次进程中不可用；退出第三方进程后普通 `claude` 恢复。
- Claude Code 对 `GLM-5.3`、`gpt-5.6-sol` 可能显示 `unrecognized_model`，因为它们不是 Claude 内置模型名；是否完整支持工具、流式和未来协议字段由 Sub2API 转换层及上游决定。

## 回滚

- 默认使用 `claude` 或 `codex` 即回到原订阅，无需登出。
- 删除对应 `~/.claude/<provider>.settings.json` 或 `~/.codex/<provider>.config.toml` 可移除单个入口。
- 删除 `~/.codex/config.toml` 中的 `model_providers.sub2api` 可移除 Codex 的通用 Sub2API provider。
- 禁用 VPS 下游 key 或分组可从服务端停止对应链路。
- Paratera 部署前数据库备份仍为 `/root/software/sub2api/backups/20260905-paratera-before.dump`。
