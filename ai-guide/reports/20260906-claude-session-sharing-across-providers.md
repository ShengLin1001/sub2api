# Codex 与 Claude Code 在多 provider 下的 session 共用行为

- 日期：2026-09-06
- 环境：Windows 10 / git-bash，`codex-cli 0.153.4`
- 触发问题：`codex -pj codex-zmy` 的会话额度耗尽后，切回原生订阅的 codex，`codex resume` 列表里找不到该会话；按 session id 直接进入，仍然报额度耗尽。而同样的 wrapper 方式下 Claude Code 的 session 是跨 provider 可见的。

## 1. 结论

| | Codex CLI | Claude Code |
| --- | --- | --- |
| 历史存储 | `~/.codex/sessions/<Y>/<M>/<D>/rollout-*.jsonl` + 索引库 `~/.codex/state_5.sqlite` | `~/.claude/projects/<escaped-cwd>/<sessionId>.jsonl`，无索引库 |
| 是否记录 provider | 记录。`threads` 表有 `model_provider` 列 | 不记录。transcript 无任何 provider / baseUrl 字段 |
| picker 过滤维度 | cwd + `model_provider` | 仅 cwd |
| resume 时 model/provider 来源 | 从 thread 记录恢复，CLI 覆盖被忽略 | 从当前 settings + 环境变量取 |
| 跨 provider 共用 | 否 | 是 |

两边的封装（`~/.bash_soft_env` 里的 `codex -pj` / `claude -pj`）本身没有问题，也没有把历史目录分家。差异完全来自两个 CLI 自身的会话模型。

## 2. Codex：provider 是会话的持久属性

### 2.1 存储没有分家

`codex -pj codex-zmy` 展开为 `codex -p codex-zmy`，`-p` 的语义是「把 `$CODEX_HOME/<name>.config.toml` 叠加在 base config 之上」：

```toml
# ~/.codex/codex-zmy.config.toml
model_provider = "sub2api"
model = "gpt-5.6-sol"
model_reasoning_effort = "high"
service_tier = "default"
```

`CODEX_HOME` 未变，rollout 与索引库都是同一份。

### 2.2 分家的是索引里的一列

`~/.codex/state_5.sqlite` 的 `threads` 表按 provider 分布：

```
openai 394 | paratera 22 | sub2api 8 | sub2api_paratera 1
```

app-server 的 `ThreadListParams` 含 `modelProviders` 字段，对应 SQL 拼接片段（从 `codex.exe` 中提取）：

```sql
... AND threads.source IN ( ...
    AND threads.model_provider IN ( ...
    AND threads.cwd IN ( ...
```

原生 codex 启动时 provider 为 `openai`，picker 只列同 provider 的 thread，sub2api 的会话被过滤掉。

注意 `codex resume --all` 帮不上忙 —— 其说明是 "disables **cwd** filtering"，管的是工作目录，不是 provider。

> 置信度说明：`model_provider` 列与 `modelProviders` 过滤参数是二进制中的直接证据；「resume picker 确实传了该过滤器」为推断，但与实测现象一致。

### 2.3 按 id resume 仍绑第三方，是设计如此

`ThreadResumeParams` 的字段只有 `history` / `path` / `runtimeWorkspaceRoots` / `permissions` / `initialTurnsPage`，**没有 model 或 modelProvider**。provider 从 thread 记录恢复。二进制中还存在这些运行期提示：

```
model_provider requested=… active=…
config overrides were provided and ignored while running
```

因此 `codex -c model_provider=openai resume <id>` 无效，会被忽略，请求照旧发往 sub2api，照旧额度耗尽。

### 2.4 实测数据佐证

会话 `01a07507-76d4-78b1-95cd-0b65d8acd608`：

- rollout 的 `session_meta`：`"model_provider": "openai"`（启动时）
- `threads` 表当前：`model_provider = sub2api`，`model = gpt-5.6-sol`

同批次的 `01a07505-…` 为 `sub2api / Kimi-K3`。说明 provider 是随会话演进的活状态并回写索引 —— 会话内用 `/model` 切到第三方模型（glm-5.3-flash / Kimi-K3），整个 thread 就被绑到 sub2api 上了。

### 2.5 该设计的合理性

不是纯粹的缺陷。`Kimi-K3` 在 OpenAI 端不存在，若允许把该 thread 直接 resume 到订阅 provider，首次请求就会因模型名无效而失败。绑定 provider 保证了会话自洽。

## 3. Claude Code：只按 cwd 分，不记 provider

历史是一层扁平文件：

```
~/.claude/projects/F--BaiduSyncdisk-version20240608-main-code-space-other-sub2api/<sessionId>.jsonl
```

抽取该目录下 transcript 的全部字段：

```
apiBlockIndex, apiErrorStatus, attachment, content, cwd, effort, entrypoint, error,
gitBranch, message, messageId, modelUsage, parentUuid, permissionMode, promptId,
sessionId, timestamp, totalCostUSD, type, userType, uuid, version, …
```

无 provider、无 baseUrl。`--resume` 即列出 `<escaped-cwd>/` 目录下的 jsonl，与当前 provider 无关。

wrapper 中的 `--settings ~/.claude/<provider>.settings.json` 只叠加配置，不改历史目录（改历史目录需要 `CLAUDE_CONFIG_DIR`）。settings 文件只承载 model 与 modelPicker：

```json
// ~/.claude/codex-zmy.settings.json
{ "model": "gpt-5.6-sol",
  "modelPicker": { "replaceBuiltInOptions": true, "options": [ … ] } }
```

因此 resume 一个第三方会话回订阅时，model 由**当前** settings 决定，历史照读不误。

代价：唯一的分家维度是 cwd，换目录同样找不到；且 `replaceBuiltInOptions: true` 的模型列表与历史中实际跑过的模型可以对不上，Claude 不做校验。

## 4. 实操方案（Codex）

### 4.1 把历史搬到订阅额度上 —— 用 fork，不用 resume

```bash
codex fork 01a07507-76d4-78b1-95cd-0b65d8acd608
```

`fork` 新建 thread、只继承历史，其参数接受 `-p` / `-m` / `-c`（见 `codex fork --help`），原生运行即绑定 openai 订阅。这是本场景的正解。

`resume` 是接着原 thread 跑，settings 不可覆盖 —— 两个命令的差别就是问题的答案。

### 4.2 只想在 picker 里看到该会话

用同一 provider 启动后再选：

```bash
codex -pj codex-zmy      # 然后 /resume
```

### 4.3 排查命令

```bash
# 会话按 provider 的分布
python -c "
import sqlite3
c=sqlite3.connect('file:$HOME/.codex/state_5.sqlite?mode=ro',uri=True)
for r in c.execute('select model_provider,count(*) from threads group by 1 order by 2 desc'): print(r)
"

# 单个会话的 provider / model
python -c "
import sqlite3
c=sqlite3.connect('file:$HOME/.codex/state_5.sqlite?mode=ro',uri=True)
for r in c.execute(\"select id,model_provider,model,cwd,title from threads where id like '01a07507%'\"): print(r)
"

# rollout 启动时记录的 provider
head -c 400 ~/.codex/sessions/2026/09/05/rollout-*01a07507*.jsonl
```

## 5. 待确认

- `codex fork` 跨 provider 继承历史后，第三方模型产生的 assistant 消息在订阅端是否被完整接受（未实测，建议先用短会话验证）。
- picker 是否可通过配置关闭 provider 过滤：`codex resume` 无对应 flag，`~/.codex/config.toml` 中亦未见相关键；如需该能力只能向上游提。
