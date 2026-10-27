# VPS Sub2API 部署文档

> 部署时间：2026-08-05
> VPS：107.172.161.141 (美国，RackNerd，Ubuntu 24.04，961MB RAM)

---

## 一、部署信息

### 1.1 服务器信息

| 项目 | 值 |
|------|-----|
| IP | 107.172.161.141 |
| SSH | `ssh root@107.172.161.141` |
| 系统 | Ubuntu 24.04 LTS |
| 内存 | 961 MiB |
| 磁盘 | 19G（可用 13G） |
| 已有服务 | xray (端口 443) |

### 1.2 Sub2API 凭据

| 项目 | 值 |
|------|-----|
| 管理后台 | http://107.172.161.141:18080 |
| 管理员邮箱 | admin@sub2api.local |
| 管理员密码 | dH2ytzNLGj6OQqzOqgPr |
| 下游 API Key | 见 VPS 文件 `/root/software/sub2api/compose/.api_key` |
| Base URL | http://107.172.161.141:18080/v1 |

### 1.3 目录结构

```
/root/software/sub2api/
├── compose/
│   ├── docker-compose.yml        # Compose 配置
│   ├── .env                      # 机密配置（chmod 600）
│   └── .api_key                  # 下游 API Key
├── backups/                      # 备份目录

/root/sub2api-data/
├── postgres/                     # PostgreSQL 数据
├── redis/                        # Redis 持久化
└── app/                          # Sub2API 应用数据
```

### 1.4 容器配置

| 容器 | 镜像 | 内存限制 | 实际占用 | 端口 |
|------|------|---------|---------|------|
| sub2api | weishaw/sub2api:latest | 384 MiB | ~82 MiB (21%) | 0.0.0.0:18080→8080 |
| sub2api-postgres | postgres:16-alpine | 256 MiB | ~83 MiB (32%) | 内部 5432 |
| sub2api-redis | redis:8-alpine | 96 MiB | ~8 MiB (8%) | 内部 6379 |

- 系统总内存 961 MiB，已用 580 MiB，可用 380 MiB
- Swap 1 GiB（已用 72 MiB）
- Redis 配置了 `--maxmemory 64mb --maxmemory-policy allkeys-lru`

### 1.5 Codex 账号

| 项目 | 值 |
|------|-----|
| 账号 ID | 1 |
| 名称 | codex-main |
| 平台 | openai |
| 类型 | oauth |
| 状态 | active |
| 所属 Group | id=2 (openai-default) |
| API Key ID | 2 (名称: vps-primary) |

---

## 二、连接方法

### 2.1 本地客户端配置（无需梯子）

本地到 VPS 是普通 HTTP 请求到公网 IP，不经过 GFW 敏感域名，不需要梯子。VPS 在美国直连上游 API。

```bash
# 在本地终端（~/.bashrc 或 ~/.zshrc）
export OPENAI_BASE_URL="http://107.172.161.141:18080/v1"
export OPENAI_API_KEY="<你的完整 API Key>"
```

> API Key 完整值在 VPS 上查看：`cat /root/software/sub2api/compose/.api_key`

### 2.2 Claude Code 使用

```bash
# 设置环境变量后直接使用
export OPENAI_BASE_URL="http://107.172.161.141:18080/v1"
export OPENAI_API_KEY="sk-xxxx"

# Claude Code 会自动读取这两个环境变量
```

### 2.3 Codex CLI 使用

```bash
export OPENAI_BASE_URL="http://107.172.161.141:18080/v1"
export OPENAI_API_KEY="sk-xxxx"
codex "你的指令"
```

### 2.4 curl 测试

```bash
# 健康检查
curl http://107.172.161.141:18080/health
# 返回: {"status":"ok"}

# 模型列表
curl http://107.172.161.141:18080/v1/models \
  -H "Authorization: Bearer sk-xxxx"

# Chat 对话
curl http://107.172.161.141:18080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer sk-xxxx" \
  -d '{
    "model": "gpt-5.5",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 10
  }'
```

### 2.5 浏览器访问管理后台

直接在浏览器打开 http://107.172.161.141:18080 ，用管理员邮箱密码登录。

### 2.6 可用模型（13 个）

```
gpt-5.6-sol
gpt-5.6
gpt-5.6-terra
gpt-5.6-luna
gpt-5.5
grok-4.5
grok-4.3
grok-build-0.1
grok-composer-2.5-fast
grok-4.20-0309-reasoning
... 等
```

---

## 三、请求链路

```
本地客户端 (中国，无需梯子)
    |
    | HTTP 请求到公网 IP
    v
VPS Sub2API (107.172.161.141:18080, 美国)
    |
    | 用 Codex OAuth token 从美国直连上游
    v
api.openai.com / api.anthropic.com
    看到的来源 IP = 107.172.161.141 (美国)
    看不到本地真实 IP
```

---

## 四、内存限制分析

### 4.1 当前内存状态（部署时输出）

```
系统总内存:
              total        used        free      shared  buff/cache   available
Mem:           961Mi       580Mi        86Mi        27Mi       479Mi       380Mi
Swap:          1.0Gi        71Mi       952Mi

容器内存使用:
NAME               MEM USAGE / LIMIT   MEM %
sub2api            81.76MiB / 384MiB   21.29%
sub2api-postgres   83.16MiB / 256MiB   32.48%
sub2api-redis      7.828MiB / 96MiB    8.15%
```

### 4.2 限制在哪里

三个容器的内存限制在 `docker-compose.yml` 的 `deploy.resources.limits.memory` 中配置：

| 容器 | 限制 | 实际 | 余量 |
|------|------|------|------|
| sub2api | 384 MiB | 82 MiB | 302 MiB（充裕） |
| postgres | 256 MiB | 83 MiB | 173 MiB（够用） |
| redis | 96 MiB | 8 MiB | 88 MiB（充裕） |
| **合计** | **736 MiB** | **173 MiB** | — |
| **系统可用** | **380 MiB** | — | — |

Redis 额外配置了 `--maxmemory 64mb --maxmemory-policy allkeys-lru`，超过 64MB 自动淘汰旧数据。

### 4.3 主要影响

**当前状态：正常运行，内存充裕**

实际三个容器加起来只用 173 MiB，系统还有 380 MiB 可用，不会 OOM。但有限制场景：

1. **高并发请求**：Sub2API 处理大量并发流式请求时内存会上升，384 MiB 限制下大约能支撑 10-20 个并发流式请求。超过限制会被 Docker OOM kill 然后自动重启。

2. **PostgreSQL 大查询**：后台仪表盘统计、用量日志聚合等大查询可能触发 256 MiB 限制。日志数据量大时可能需要定期清理。

3. **Redis 缓存淘汰**：64MB 上限意味着高频请求的缓存会频繁淘汰，命中率下降，更多请求打到数据库。

4. **图片/视频生成**：Sub2API 支持图片和视频生成代理，这类请求内存占用大，961MB 的 VPS 不适合跑。

5. **多账号导入**：如果导入大量 Codex/ChatGPT 账号，token 刷新和调度会占用更多内存。

### 4.4 如果内存不够

```bash
# 方案 1：增加 Swap（最简单）
ssh root@107.172.161.141
fallocate -l 2G /swapfile2
chmod 600 /swapfile2
mkswap /swapfile2
swapon /swapfile2
echo '/swapfile2 none swap sw 0 0' >> /etc/fstab

# 方案 2：调大容器内存限制（如果加了 swap）
# 编辑 /root/software/sub2api/compose/docker-compose.yml
# 把 sub2api 的 memory: 384M 改为 512M
# docker compose up -d

# 方案 3：限制功能
# 在 .env 中关闭不需要的功能：
# DASHBOARD_AGGREGATION_ENABLED=false  # 关闭仪表盘聚合
# LOG_OUTPUT_TO_FILE=false              # 减少日志内存
```

---

## 五、运维命令

### 5.1 SSH 连接

```bash
ssh root@107.172.161.141
# 密码: 2QHWUav1450r6tfyPS
```

### 5.2 容器管理

```bash
cd /root/software/sub2api/compose

docker compose ps              # 查看状态
docker compose logs -f sub2api # 查看日志
docker compose restart sub2api # 重启应用
docker compose down            # 停止全部
docker compose up -d           # 启动全部
docker compose pull            # 拉取新版本
```

### 5.3 查看 API Key

```bash
cat /root/software/sub2api/compose/.api_key
```

### 5.4 备份

```bash
# 手动备份
docker exec sub2api-postgres pg_dump -U sub2api sub2api > /root/software/sub2api/backups/db_$(date +%Y%m%d).sql

# 备份配置
tar czf /root/software/sub2api/backups/config_$(date +%Y%m%d).tar.gz \
  -C /root/software/sub2api/compose .env docker-compose.yml .api_key
```

### 5.5 更新 Sub2API

```bash
cd /root/software/sub2api/compose
docker compose pull
docker compose up -d
```

---

## 六、安全注意事项

1. **端口 18080 当前是 HTTP 明文**，API Key 在传输中不加密。如果 VPS 被扫描到，可能被中间人截获。
2. **管理后台无 IP 限制**，任何人知道地址都能尝试登录。建议后续：
   - 改非常规端口（如 38080）
   - 或用 nginx 反代加 HTTPS
   - 或用 iptables 限制来源 IP
3. **SSH 密码较弱**，建议换密钥认证：
   ```bash
   # 本地生成密钥后
   ssh-copy-id root@107.172.161.141
   # 然后禁用密码登录
   sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
   systemctl restart sshd
   ```
4. **Codex token 存储在 VPS 数据库中**，确保 VPS 不被入侵，否则 token 泄露。

---

## 七、与 WSL 本地部署的对比

| 项目 | WSL 本地部署 | VPS 部署 |
|------|-------------|---------|
| 地址 | http://127.0.0.1:18080 | http://107.172.161.141:18080 |
| 需要梯子 | 是（sing-box TUN 代理） | 否（VPS 直连上游） |
| 上游看到的 IP | 本地中国 IP（经代理后为代理节点 IP） | VPS 美国 IP |
| localhost 转发 | 被 sing-box TUN 干扰 | 无此问题 |
| 内存 | 充裕（WSL 7.7 GiB） | 紧张（961 MiB） |
| 延迟 | 本地，低延迟 | 跨太平洋，~200ms |
| 稳定性 | 依赖 v2rayN 持续运行 | VPS 独立运行 |
| 适用场景 | 本机开发调试 | 生产使用、远程调用 |
