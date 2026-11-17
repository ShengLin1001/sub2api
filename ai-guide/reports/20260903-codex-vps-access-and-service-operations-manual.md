# VPS 环境、访问方式与运维手册

> 生成日期：2026-09-03（America/Los_Angeles）  
> 适用服务器：`vps-107` / `racknerd-c27bbab`  
> 文档级别：管理员内部使用  
> 本文不记录任何密码、SSH 私钥、Sub2API Key、VLESS UUID 或 Hysteria 认证信息。

## 1. 当前结论

服务器已经完成 Sub2API 的公网入口收口：

```text
普通 API 用户
  -> HTTPS Funnel: racknerd-c27bbab.tailaaf4af.ts.net
  -> Tailscale 加密转发
  -> 127.0.0.1:18080
  -> Sub2API
```

当前推荐地址：

| 用途 | 地址 |
| --- | --- |
| Sub2API 管理页面 | `https://racknerd-c27bbab.tailaaf4af.ts.net/` |
| OpenAI 兼容 Base URL | `https://racknerd-c27bbab.tailaaf4af.ts.net/v1` |
| 健康检查 | `https://racknerd-c27bbab.tailaaf4af.ts.net/health` |
| VPS 公网地址 | `107.172.161.141` |

原有 Sub2API Key 本身没有变化。用户只需把旧的：

```text
http://107.172.161.141:18080/v1
```

替换为：

```text
https://racknerd-c27bbab.tailaaf4af.ts.net/v1
```

旧公网 `18080` 已无法连接。VLESS 的 TCP 443 和 Hysteria 的 UDP 443 保持不变。

## 2. 服务器环境快照

以下数据来自 2026-09-03/04 的实时检查：

| 项目 | 当前状态 |
| --- | --- |
| 主机名 | `racknerd-c27bbab` |
| 云主机 | RackNerd KVM VPS |
| 操作系统 | Ubuntu 24.04 LTS |
| 内核 | Linux `6.8.0-134-generic` |
| 架构 | x86-64 |
| CPU | 1 vCPU |
| 内存 | 961 MiB，总体可用约 372 MiB（采集时） |
| Swap | 1.0 GiB，已用约 453 MiB（采集时） |
| 系统盘 | 19 GiB，已用 6.8 GiB，可用约 11 GiB |
| Docker | 29.7.1 |
| Docker Compose | v5.4.0 |
| Xray | 26.6.1 |
| Hysteria | 2.9.2 |
| ZeroTier | 1.16.2，状态 ONLINE |
| Tailscale | 1.102.3，状态 Running |
| Sub2API 时区 | `Asia/Shanghai` |
| Sub2API 运行模式 | `simple` / `release` |

系统提示存在较新的 Ubuntu 内核，但本次没有重启服务器，以免中断代理服务。

## 3. Docker 与数据服务

实际 Compose 目录：

```text
/root/software/sub2api/compose
```

当前容器：

| 容器 | 镜像 | 状态 | 网络边界 |
| --- | --- | --- | --- |
| `sub2api` | `weishaw/sub2api:latest` | running / healthy | `127.0.0.1:18080 -> 8080/tcp` |
| `sub2api-postgres` | `postgres:16-alpine` | running / healthy | 仅 Docker 内部 `5432/tcp` |
| `sub2api-redis` | `redis:8-alpine` | running / healthy | 仅 Docker 内部 `6379/tcp` |

端口收口前的 Compose 备份：

```text
/root/software/sub2api/compose/docker-compose.yml.pre-tailscale-20260904
```

常用只读检查：

```bash
cd /root/software/sub2api/compose
docker compose ps
docker compose logs --tail=100 sub2api
docker compose logs --tail=100 postgres
docker compose logs --tail=100 redis
curl http://127.0.0.1:18080/health
```

仅在确有需要时重启 Sub2API：

```bash
cd /root/software/sub2api/compose
docker compose restart sub2api
```

不要用不带服务名的 `docker compose restart`，否则会连带重启数据库和 Redis。

## 4. 当前公网端口边界

UFW 已启用并设置为开机启动：

```text
默认入站：deny
默认出站：allow
默认转发：deny
```

实时外网验证结果：

| 端口 | 公网状态 | 服务与说明 |
| --- | --- | --- |
| TCP 22 | 可达 | SSH，仅公钥认证 |
| TCP 443 | 可达 | Xray / VLESS |
| UDP 443 | 防火墙允许，服务监听 | Hysteria |
| TCP 2096 | 可达 | x-ui 进程持有；暂时保留，避免破坏现有订阅 |
| TCP 1234 | 已阻断 | x-ui 管理面板 |
| TCP 9993 | 已阻断 | ZeroTier TCP API；此前外网请求会返回 401 |
| TCP 18080 | 已阻断 | Sub2API 仅回环监听 |
| UDP 9993 | 允许 | ZeroTier |
| UDP 41641 | 允许 | Tailscale |

查看防火墙：

```bash
sudo ufw status verbose
```

安装 UFW 时，Ubuntu 自动移除了与其冲突的 `iptables-persistent` 和 `netfilter-persistent` 软件包。启用 UFW 前，实际 INPUT 链中没有发现既有自定义持久规则，仅有 Tailscale 规则。

修改防火墙前，必须先保证 TCP 22、TCP/UDP 443 的允许规则存在，并保留一个已经登录的 SSH 窗口。

## 5. SSH 登录

### 5.1 本机管理员登录

本机已经配置 SSH 别名时：

```bash
ssh vps-107
```

服务器有效 SSH 策略：

```text
Port 22
PermitRootLogin without-password
PubkeyAuthentication yes
PasswordAuthentication no
AllowTcpForwarding yes
GatewayPorts no
```

含义：root 和普通用户都不能通过 SSH 密码登录；root 可以通过已经授权的公钥登录。

旧 root 密码即使正确，也不会被 SSH 服务用于认证。不要为了方便重新开启 `PasswordAuthentication yes`。

### 5.2 同学账号登录

已创建账号：

```text
用户名：classmate
所属组：classmate, sudo
认证方式：ED25519 公钥
账户密码：锁定，不允许密码登录
sudo：NOPASSWD
```

已安装公钥指纹：

```text
SHA256:++krHAsbBdygduUg+Hw7q6WVtBTJa55LPoE6x62gWV8
```

同学使用私钥登录：

```bash
ssh -i ~/.ssh/vps107-classmate classmate@107.172.161.141
```

Windows `~/.ssh/config` 示例：

```sshconfig
Host vps-107
    HostName 107.172.161.141
    User classmate
    IdentityFile ~/.ssh/vps107-classmate
    IdentitiesOnly yes
```

然后可直接运行：

```bash
ssh vps-107
sudo -n true
sudo -i
```

只可以把 `.pub` 公钥发给管理员；不得发送或上传无 `.pub` 后缀的私钥文件。

## 6. 登录 x-ui / 3x-ui

### 6.1 当前配置

| 项目 | 当前值 |
| --- | --- |
| 服务 | `x-ui.service`，active / enabled |
| 管理端口 | TCP 1234 |
| 公网访问 | 已由 UFW 阻断 |
| TLS | 已启用 |
| 管理路径 | `/LFBrIQuszzpjRxd6kz/` |
| 管理用户名 | `zhangmingyang` |
| Xray 入站 | VLESS / TCP 443 / enabled |

密码不写入本文。如果忘记密码，管理员可通过 SSH 运行：

```bash
sudo x-ui
```

然后选择菜单中的 `Reset Username & Password`。该操作会改变登录凭据，不要把它当作普通检查命令运行。

### 6.2 推荐登录方法：SSH 隧道

在本机建立隧道：

```bash
ssh -N -L 11234:127.0.0.1:1234 vps-107
```

同学没有 SSH 别名时：

```bash
ssh -N -L 11234:127.0.0.1:1234 \
  -i ~/.ssh/vps107-classmate classmate@107.172.161.141
```

保持命令窗口运行，在浏览器打开：

```text
https://127.0.0.1:11234/LFBrIQuszzpjRxd6kz/
```

x-ui 当前证书签给 VPS 公网 IP，因此通过 `127.0.0.1` 隧道访问时，浏览器可能提示证书名称不匹配。只有在确认地址是 `127.0.0.1`、SSH 隧道由本人建立时，才可以处理该提示；不要对未知公网证书忽略警告。

结束访问时按 `Ctrl+C` 关闭隧道。

### 6.3 x-ui 运维命令

```bash
sudo x-ui status
sudo systemctl status x-ui --no-pager
sudo journalctl -u x-ui -n 100 --no-pager
pgrep -af xray-linux-amd64
sudo ss -lntup
```

`x-ui restart` 可能同时重启 Xray，导致 VLESS 用户短暂断线。只查看状态时不要运行重启命令。

## 7. 登录和使用 Sub2API

### 7.1 管理员网页登录

浏览器直接打开：

```text
https://racknerd-c27bbab.tailaaf4af.ts.net/
```

当前管理员邮箱为：

```text
peijun627728@gmail.com
```

使用现有管理员密码登录。密码不写入本文。如果实际管理员邮箱后来在系统中修改，以登录页和数据库中的当前账号为准。

Sub2API 管理页面通过 Funnel 暴露在公网，但后台服务端口 `18080` 不在公网；登录鉴权、TOTP、限流和每用户独立 Key 仍然必须启用和维护。

### 7.2 用户自助注册

公网注册入口：

```text
https://racknerd-c27bbab.tailaaf4af.ts.net/register
```

当前已开放邮箱密码注册，并启用了以下校验：

- Gmail SMTP 邮箱验证码；
- Cloudflare Turnstile（Managed 模式），受保护主机名为 `racknerd-c27bbab.tailaaf4af.ts.net`。

新用户注册时必须先完成 Turnstile，再获取并填写邮箱验证码。邀请码仍未启用。新用户默认余额为 `0`、并发为 `5`，注册后仍需管理员配置余额或授权才能实际调用付费模型。

SMTP 使用管理员 Gmail 账号和 Google 应用专用密码。应用专用密码及 Turnstile 密钥只保存在服务配置中，不应写入本文、Git、聊天或截图。若撤销 Google 应用专用密码，需要在 Sub2API 中更新 SMTP 密码后重新发送测试邮件。

### 7.3 普通用户使用 Key

普通用户不需要 SSH、Tailscale 或 ZeroTier，只需要 HTTPS Base URL 和分配给自己的 Sub2API Key。

Bash：

```bash
export OPENAI_BASE_URL="https://racknerd-c27bbab.tailaaf4af.ts.net/v1"
export OPENAI_API_KEY="<用户自己的 Sub2API Key>"
```

PowerShell：

```powershell
$env:OPENAI_BASE_URL = "https://racknerd-c27bbab.tailaaf4af.ts.net/v1"
$env:OPENAI_API_KEY = "<用户自己的 Sub2API Key>"
```

最小测试：

```bash
curl https://racknerd-c27bbab.tailaaf4af.ts.net/v1/models \
  -H "Authorization: Bearer $OPENAI_API_KEY"
```

不要把真实 Key 写入共享文档、Git、聊天截图或公开 shell 脚本。每位用户应使用独立 Key，并分别配置额度、限速、有效期和撤销能力。

### 7.4 SSH 应急访问

如果 Funnel 临时故障，管理员仍可通过 SSH 隧道访问：

```bash
ssh -N -L 18081:127.0.0.1:18080 vps-107
```

本机管理页面：

```text
http://127.0.0.1:18081/
```

本机 API Base URL：

```text
http://127.0.0.1:18081/v1
```

这里的 HTTP 流量实际封装在 SSH 加密连接中。不要因为 Funnel 故障而重新公开 `18080`。

## 8. Tailscale Funnel 运维

当前公网 Funnel：

```text
https://racknerd-c27bbab.tailaaf4af.ts.net
  -> http://127.0.0.1:18080
```

检查状态：

```bash
sudo systemctl status tailscaled --no-pager
sudo tailscale status
sudo tailscale funnel status
```

重新声明当前 Funnel：

```bash
sudo tailscale funnel --bg http://127.0.0.1:18080
```

仅在明确需要停止公网 API 时使用：

```bash
sudo tailscale funnel --https=443 off
```

不要为排错随意执行 `tailscale down`、`tailscale logout` 或 Funnel `off`；这些命令会直接使公开 Base URL 失效。

Tailscale 和 UFW 均已设置为开机启动。当前没有通过重启 VPS 做破坏性验证；重启后应按本节和第 11 节重新检查。

## 9. VLESS、Hysteria 与订阅入口

### 9.1 VLESS

当前 x-ui 数据库中的启用入站：

```text
protocol=vless
listen=107.172.161.141
port=443/tcp
enabled=true
```

为避免 Xray 抢占 Tailscale 地址的 TCP 443，VLESS 监听地址已从所有网卡收窄为服务器公网 IP `107.172.161.141`。VLESS UUID、传输方式、TLS/REALITY 参数、公网 IP 和端口均未改变，因此此前分发的 VLESS 节点保持有效。修改监听地址时重启过一次 x-ui/Xray，已有连接可能发生过一次短暂重连。

### 9.2 Hysteria

当前 Hysteria 2.9.2 监听 UDP 443，`hysteria-server.service` 为 active / enabled。UFW 保留 UDP 443，因此此前分发的 Hysteria 配置保持有效。

### 9.3 TCP 2096

TCP 2096 由 x-ui 进程监听，HTTPS 根路径返回 404；它不是已确认的 `webPort`。该端口可能承担带隐藏路径的订阅服务，因此当前继续允许公网访问。

在确认现有订阅链接是否包含 `:2096` 之前，不要关闭该端口。即使关闭订阅入口，已经导入的节点通常仍能连接，但客户端将无法获取后续配置更新。

## 10. 服务状态和日志

服务状态：

```bash
sudo systemctl status docker --no-pager
sudo systemctl status x-ui --no-pager
sudo systemctl status hysteria-server --no-pager
sudo systemctl status zerotier-one --no-pager
sudo systemctl status tailscaled --no-pager
sudo systemctl status ufw --no-pager
```

代理进程和端口：

```bash
pgrep -af xray-linux-amd64
pgrep -af hysteria
sudo ss -lntup
```

日志：

```bash
sudo journalctl -u x-ui -n 100 --no-pager
sudo journalctl -u hysteria-server -n 100 --no-pager
sudo journalctl -u tailscaled -n 100 --no-pager
cd /root/software/sub2api/compose
docker compose logs --tail=100 sub2api
```

输出日志前先检查是否包含 API Key、UUID、用户请求或上游凭据，不要原样发布完整日志。

## 11. 验证清单

### 11.1 Sub2API

```bash
curl -fsS https://racknerd-c27bbab.tailaaf4af.ts.net/health
curl -fsS http://127.0.0.1:18080/health
sudo tailscale funnel status
```

预期：两个健康检查均成功，Funnel 指向 `127.0.0.1:18080`。

未携带 Key 的请求应被拒绝：

```bash
curl -i https://racknerd-c27bbab.tailaaf4af.ts.net/v1/models
```

预期 HTTP 401。

### 11.2 公网端口

在 Windows 外部客户端检查：

```powershell
Test-NetConnection 107.172.161.141 -Port 22
Test-NetConnection 107.172.161.141 -Port 443
Test-NetConnection 107.172.161.141 -Port 1234
Test-NetConnection 107.172.161.141 -Port 18080
```

预期：22、443 成功；1234、18080 失败。

### 11.3 代理

```bash
sudo systemctl is-active x-ui
sudo systemctl is-active hysteria-server
sudo ss -lntp | grep ':443'
sudo ss -lnup | grep ':443'
```

预期：x-ui、Hysteria 均 active；TCP 443 分别由 Xray 监听公网 IP、Tailscale 监听其 `100.x` 地址，UDP 443 由 Hysteria 监听。

当前实施后的真实回归结果：

```text
Funnel /health: HTTP 200
携带现有 Key 的 /v1/models: HTTP 200，13 个模型
流式 /v1/chat/completions: HTTP 200, text/event-stream
SSE: 收到多个 data 块并以 [DONE] 结束
公网 TCP 18080: blocked
公网 TCP 1234: blocked
公网 TCP 9993: blocked
公网 TCP 22/443/2096: reachable
Xray/Hysteria PID: Sub2API 重建前后未变化
注册公开配置: registration/email_verify/turnstile 均为 enabled
Gmail SMTP: STARTTLS 登录成功，测试邮件已实际到达收件箱
```

## 12. 常见故障处理

### 12.1 HTTPS 域名返回 502 或无法连接

按顺序检查：

```bash
curl -i http://127.0.0.1:18080/health
cd /root/software/sub2api/compose
docker compose ps
docker compose logs --tail=100 sub2api
sudo tailscale status
sudo tailscale funnel status
```

- 本地健康检查失败：处理 Sub2API 容器。
- 本地成功、Funnel 失败：处理 Tailscale/Funnel。
- 如果 `tailscaled` 日志出现 `address already in use`，检查 Xray 是否错误监听了所有网卡的 TCP 443；当前正确状态是 Xray 监听 `107.172.161.141:443`，Tailscale 监听 `100.93.112.72:443`。
- 如果只有 Windows 浏览器报 `ERR_CONNECTION_RESET`，检查系统代理是否把 `.ts.net` 或 `100.x` 流量转发给本地代理。当前电脑已在既有 `ProxyOverride` 末尾追加 `*.ts.net;100.*`，其余代理规则保持不变。
- 不要先重启 Xray、Hysteria 或整台 VPS。

### 12.2 API 返回 401

检查：

- Base URL 是否为新的 HTTPS `/v1` 地址；
- 是否使用 Sub2API 下游 Key，而不是上游供应商 Key；
- Key 是否被禁用、过期或额度耗尽；
- Key 是否绑定了可用分组。

不要把完整 Key 粘贴到工单或日志中。

### 12.3 x-ui 页面打不开

1. 确认 SSH 隧道窗口仍在运行；
2. 确认使用 `11234` 本地端口和完整管理路径；
3. 检查 `sudo systemctl is-active x-ui`；
4. 检查 `sudo ss -lntp | grep ':1234'`；
5. 不要临时把 1234 重新开放到公网。

### 12.4 VLESS 无法连接

```bash
sudo systemctl status x-ui --no-pager
pgrep -af xray-linux-amd64
sudo ss -lntp | grep ':443'
sudo ufw status verbose
```

确认 TCP 443 仍被允许。不要修改 Sub2API/Tailscale 来排查 VLESS，它们是独立数据路径。

### 12.5 Hysteria 无法连接

```bash
sudo systemctl status hysteria-server --no-pager
pgrep -af hysteria
sudo ss -lnup | grep ':443'
sudo ufw status verbose
```

确认 UDP 443 而非仅 TCP 443 被允许。

### 12.6 注册验证码未收到

先查看脱敏后的邮件队列日志：

```bash
docker logs --since 30m sub2api 2>&1 \
  | grep -Ei 'email|smtp|verify|queue|captcha|turnstile' \
  | sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+/[redacted-email]/g'
```

- 出现 `Turnstile Verification successful` 和 `Enqueued verify code`，随后出现 SMTP 错误：检查 SMTP 配置。
- 出现 `invalid SMTP from address`：检查数据库中的实际配置键 `smtp_from`；管理 API 的 JSON 字段名虽然是 `smtp_from_email`，服务内部读取的数据库键是 `smtp_from`。
- 队列发送成功但未收到：检查垃圾邮件、收件方拦截规则，并确认地址拼写。

修复配置后，失败的旧任务不会自动重试，需要用户在注册页重新发送验证码。

## 13. 安全与交接规则

1. 不共享 root 私钥；每位管理员使用独立 SSH 用户和独立公钥。
2. 不重新开启 SSH 密码登录。
3. 不把 x-ui 1234、Sub2API 18080 或 ZeroTier TCP 9993 重新开放到公网。
4. 普通 API 用户使用 HTTPS Funnel，不需要 SSH。
5. 每位 API 用户使用独立下游 Key；设置额度、限速、有效期并保留撤销能力。
6. 不分发上游供应商原始 Key、OAuth Token 或 Cookie。
7. 修改防火墙前先保留 SSH 会话并检查 22、TCP/UDP 443。
8. 重启 x-ui 可能重启 Xray；无关排错不要重启它。
9. 继续保留 2096，直到确认订阅用途并完成迁移方案。
10. Tailscale Funnel 是公网入口，不代表 Sub2API 无需自身鉴权和安全更新。

## 14. 当前变更记录

- 删除了本地部署文档中记录的 root 明文密码；没有修改服务器 root 密码。
- 创建 `classmate` 独立公钥账号并授予可审计的 sudo 权限。
- 安装并登录 Tailscale 1.102.3。
- 启用后台 Funnel，将公开 HTTPS 转发到 `127.0.0.1:18080`。
- 将 Sub2API Docker 发布地址由 `0.0.0.0:18080` 改为 `127.0.0.1:18080`。
- 仅重建 Sub2API 容器，未重启 Xray/Hysteria。
- 安装并启用 UFW，默认拒绝入站。
- 保留 SSH、VLESS、Hysteria、Tailscale、ZeroTier 和临时 2096 所需规则。
- 阻断公网 TCP 1234、9993、18080。
- 管理员邮箱修改为 `peijun627728@gmail.com`，并清空 `.env` 中已失效的旧管理员明文密码。
- 开放邮箱密码自助注册；新用户默认余额保持为 `0`，邀请码未启用。
- 配置 Gmail SMTP 并启用邮箱验证码；已完成 STARTTLS 登录和真实收件验证。
- 修正 SMTP 发件人数据库键为服务实际读取的 `smtp_from`；Sub2API 内置连接测试和测试邮件投递均已验证成功。
- 创建并启用 Cloudflare Turnstile（Managed 模式），用于注册反滥用校验。
- 将 Xray 的 TCP 443 监听地址收窄到公网 IP，解除其与 Tailscale Funnel 的 443 端口冲突；VLESS 对外地址和参数保持不变。
- 在当前 Windows 电脑的系统代理绕过列表中追加 `*.ts.net` 和 `100.*`，修复浏览器访问 Tailscale 域名时的连接重置。
- 已完成健康检查、鉴权模型列表、SSE 流式调用和公网端口回归。
