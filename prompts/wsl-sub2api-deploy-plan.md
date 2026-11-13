# WSL 部署方案：Sub2API + Codex 订阅转 API

> 目标：在 WSL2 (Ubuntu 24.04) 中部署 Sub2API 网关，将 ChatGPT/Codex 订阅会话转为 OpenAI 兼容 API，供本机和远程服务器使用。
>
> 软件和数据全部放在 D 盘 `D:\software\sub2api\` 下，不污染 WSL 根分区。
>
> 生成时间：2026-08-05

---

## 0. 环境摘要（已探测）

| 项目 | 现状 |
|------|------|
| WSL 发行版 | Ubuntu-24.04 (24.04.4 LTS) |
| WSL 用户 | louis / home=/home/louis |
| systemd | 已启用（/etc/wsl.conf [boot] systemd=true） |
| 内存 | 7.7 GiB |
| 磁盘 / (ext4) | 1007G，已用 2.6G → 充裕 |
| 磁盘 /mnt/d | 186G，已用 87G → 99G 可用 |
| Docker | 未安装 |
| Node.js | 未安装（WSL 侧 npm shim 指向 Windows node → 不可用） |
| PostgreSQL / Redis | 未安装 |
| apt 源 | Ubuntu 默认源（apt update 可能需要代理） |
| Windows 代理 | Clash Verge 未向 WSL 开放（7890/7897 均不可达） |
| 端口 18080 | 空闲 |

### 关键约束

1. WSL 的 `/mnt/d` 是 9p/drvfs 挂载，跨文件系统 I/O 较慢，但读写正常。
   → 数据目录（PostgreSQL data、Redis data）放在 WSL ext4 原生分区以获得性能；
   → 软件安装目录、配置、备份放在 `/mnt/d/software/sub2api/` 以满足"D 盘"要求。
2. WSL 内无法直连 Windows 代理 → apt 和外网请求需要先解决网络。
3. systemd 已启用 → 可以用 systemd service 管理服务，不必依赖 Docker。

---

## 1. 整体架构

```
┌───────────────────────────────────────────────────────────────────┐
│ Windows 主机                                                      │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────────┐  │
│  │ WSL2 (Ubuntu 24.04)  systemd=true                           │  │
│  │                                                             │  │
│  │  D:\software\sub2api\  ← /mnt/d/software/sub2api/           │  │
│  │  ├─ compose/          docker-compose.yml + .env             │  │
│  │  ├─ backups/          定期备份                              │  │
│  │  └─ codex-cli/        CODEX_HOME（可选，本机 CLI）           │  │
│  │                                                             │  │
│  │  Docker Engine (systemd 管理)                               │  │
│  │  ├─ sub2api    : 127.0.0.1:18080                            │  │
│  │  ├─ postgres   : 127.0.0.1:5432                             │  │
│  │  └─ redis      : 127.0.0.1:6379                             │  │
│  │                                                             │  │
│  │  本机客户端 → http://127.0.0.1:18080/v1                     │  │
│  └─────────────────────────────────────────────────────────────┘  │
│                                                                   │
│  VS Code (Windows) ←→ WSL 终端                                    │
│  SSH RemoteForward 127.0.0.1:18080 → 127.0.0.1:18080             │
└───────────────────────────────────────────────────────────────────┘
          │ SSH 隧道（仅 loopback，加密）
          │
┌─────────▼────────────────────────────────────────────────────────┐
│ 远程 Linux 服务器                                                 │
│                                                                   │
│  127.0.0.1:18080 → SSH tunnel → Windows WSL 127.0.0.1:18080       │
│                                                                   │
│  Codex CLI / VS Code Remote-SSH                                   │
│  OPENAI_BASE_URL=http://127.0.0.1:18080/v1                       │
│  OPENAI_API_KEY=<Sub2API 下游 Key>                               │
└───────────────────────────────────────────────────────────────────┘
```

### 为什么选 Docker（而不是原生二进制 + 原生 PG/Redis）

1. 原生安装需要分别编译/安装 PostgreSQL 16、Redis 7、Sub2API Go 二进制，
   且 Sub2API 的 install.sh 默认装到 `/opt/sub2api`（不在 D 盘），需要 hack。
2. Docker 方案把三个服务打包成一组容器，数据目录可以映射到 `/mnt/d`。
3. Docker Desktop 不需要装在 Windows 侧——WSL2 内可以直接安装 Docker Engine（不依赖 Docker Desktop），
   这样完全在 WSL 内闭环，不需要 Windows 侧配合。
4. 项目自带完善的 `docker-compose.local.yml`，是官方推荐路径。

---

## 2. 网络方案

### 2.1 WSL 内 apt 代理

WSL 默认无法访问 Windows Clash Verge。有两种解决方式：

**方案 A（推荐）：给 WSL 配置独立代理出口**

在 Windows 的 Clash Verge 中开启"允许局域网连接"（Allow LAN），
并记下 Windows 在 WSL 网段中的网关 IP（通常为 `172.21.240.1`）。
然后在 WSL 中：

```bash
# /etc/profile.d/proxy.sh
export http_proxy="http://172.21.240.1:7897"
export https_proxy="http://172.21.240.1:7897"
export no_proxy="localhost,127.0.0.1,::1,172.21.0.0/16"
```

> 注意：Clash Verge 的混合端口默认 7897，但你之前探测时所有端口均不可达。
> 需要先在 Clash Verge 设置中确认"Allow LAN"已打开，端口正确。
> 如果 Clash Verge 没开，也可以直接用国内镜像源安装软件（方案 B）。

**方案 B（备选）：使用国内镜像源，不依赖代理**

```bash
# 替换 Ubuntu apt 源为阿里云镜像
sudo sed -i 's|http://archive.ubuntu.com|https://mirrors.aliyun.com|g' /etc/apt/sources.list.d/ubuntu.sources
sudo sed -i 's|http://security.ubuntu.com|https://mirrors.aliyun.com|g' /etc/apt/sources.list.d/ubuntu.sources
sudo apt-get update
```

Docker 安装也用国内源（见 3.1）。

### 2.2 Sub2API 监听地址

绑定 `127.0.0.1:18080`。不监听 `0.0.0.0`。
WSL2 的 127.0.0.1 会被 Windows 侧自动转发（WSL2 localhost forwarding），
所以 Windows 上的浏览器和 VS Code 都能直接访问 `http://127.0.0.1:18080`。

### 2.3 远程服务器隧道

在 Windows 的 `C:\Users\louis\.ssh\config` 中添加：

```sshconfig
Host your-linux-server
    HostName <服务器IP>
    User <用户名>
    RemoteForward 127.0.0.1:18080 127.0.0.1:18080
    ExitOnForwardFailure yes
    ServerAliveInterval 30
    ServerAliveCountMax 3
```

VS Code Remote-SSH 使用同一配置，连接远程时自动建立隧道。
远程服务器上只需设置环境变量指向 `127.0.0.1:18080`。

---

## 3. 详细安装步骤

### 3.1 安装 Docker Engine（WSL 内，不依赖 Docker Desktop）

```bash
# 1. 清理旧版本（如有）
sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null

# 2. 安装依赖
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg lsb-release jq

# 3. 添加 Docker 官方 GPG key（用国内镜像）
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# 4. 添加 Docker apt 源（阿里云镜像）
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://mirrors.aliyun.com/docker-ce/linux/ubuntu $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# 5. 安装 Docker Engine + Compose plugin
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 6. 将 louis 用户加入 docker 组（免 sudo）
sudo usermod -aG docker louis

# 7. 启动 Docker（systemd）
sudo systemctl enable docker
sudo systemctl start docker

# 8. 验证（需要重新登录或 newgrp docker 后免 sudo）
docker run --rm hello-world
docker compose version
```

### 3.2 配置 Docker 数据目录到 D 盘（可选但推荐）

Docker 默认把镜像和容器层存储在 `/var/lib/docker`（WSL ext4 分区）。
如果担心 C 盘/WSL 磁盘占用，可以迁移到 `/mnt/d/software/sub2api/docker-data/`：

> 注意：/mnt/d 是 9p 挂载，I/O 性能不如 ext4。
> 如果不确定，保持默认（/var/lib/docker 在 ext4 上）即可。
> 此处仅给出选项，不强制。

```bash
# 如需迁移（可选）：
sudo mkdir -p /mnt/d/software/sub2api/docker-data
sudo systemctl stop docker
sudo mv /var/lib/docker /mnt/d/software/sub2api/docker-data
# 在 /etc/docker/daemon.json 中设置 data-root
sudo tee /etc/docker/daemon.json << 'EOF'
{
  "data-root": "/mnt/d/software/sub2api/docker-data",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
sudo systemctl start docker
docker info | grep "Docker Root Dir"
```

### 3.3 创建 Sub2API 部署目录

```bash
# 主部署目录（D 盘）
mkdir -p /mnt/d/software/sub2api/compose
cd /mnt/d/software/sub2api/compose

# 数据目录（用 Docker named volume 或本地目录）
# 推荐：数据放 WSL ext4 原生分区（性能好），配置/备份放 D 盘
mkdir -p /home/louis/sub2api-data/postgres
mkdir -p /home/louis/sub2api-data/redis
mkdir -p /home/louis/sub2api-data/app

# 备份目录放 D 盘
mkdir -p /mnt/d/software/sub2api/backups
```

### 3.4 从仓库复制 compose 文件并定制

```bash
cd /mnt/d/software/sub2api/compose

# 从当前仓库复制 docker-compose.local.yml
cp /mnt/f/BaiduSyncdisk/version20240608/main_code_space/other/sub2api/deploy/docker-compose.local.yml ./docker-compose.yml

# 从仓库复制 .env.example
cp /mnt/f/BaiduSyncdisk/version20240608/main_code_space/other/sub2api/deploy/.env.example ./.env.example
```

### 3.5 生成 .env 文件

```bash
cd /mnt/d/software/sub2api/compose

# 生成安全密钥
PG_PASS=$(openssl rand -hex 16)
JWT=$(openssl rand -hex 32)
TOTP=$(openssl rand -hex 32)

cat > .env << EOF
# === 安全绑定 ===
BIND_HOST=127.0.0.1
SERVER_PORT=18080

# === 运行模式 ===
RUN_MODE=simple
SERVER_MODE=release
TZ=Asia/Shanghai

# === PostgreSQL ===
POSTGRES_USER=sub2api
POSTGRES_PASSWORD=${PG_PASS}
POSTGRES_DB=sub2api

# === Admin ===
ADMIN_EMAIL=admin@sub2api.local
ADMIN_PASSWORD=$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)

# === JWT / TOTP ===
JWT_SECRET=${JWT}
JWT_EXPIRE_HOUR=168
TOTP_ENCRYPTION_KEY=${TOTP}

# === Auto Setup ===
AUTO_SETUP=true
SETUP_MIGRATION_TIMEOUT_SECONDS=120

# === 日志 ===
LOG_LEVEL=info
LOG_FORMAT=console
LOG_OUTPUT_TO_STDOUT=true
LOG_OUTPUT_TO_FILE=false
EOF

chmod 600 .env
echo "=== 请记录以下密码 ==="
grep -E 'POSTGRES_PASSWORD|ADMIN_PASSWORD|JWT_SECRET|TOTP_ENCRYPTION_KEY' .env
```

### 3.6 修改 docker-compose.yml（关键修改）

对从仓库复制的 `docker-compose.yml` 做以下修改：

1. **端口绑定**：确保端口映射是 `127.0.0.1:18080:8080`（不是 `0.0.0.0`）
2. **数据卷路径**：把 `./data`、`./postgres_data`、`./redis_data` 改为 WSL ext4 路径
3. **固定镜像版本**：把 `weishaw/sub2api:latest` 改为具体版本（可选，稳定性优先）

最终 docker-compose.yml 的关键部分应该是：

```yaml
services:
  sub2api:
    image: weishaw/sub2api:latest   # 后续可固定为具体版本
    container_name: sub2api
    restart: unless-stopped
    ports:
      - "127.0.0.1:18080:8080"      # ← 只绑定 loopback
    volumes:
      - /home/louis/sub2api-data/app:/app/data:Z
    environment:
      - AUTO_SETUP=true
      - BIND_HOST=0.0.0.0           # 容器内仍监听全部接口，端口映射负责限制
      - SERVER_PORT=8080
      - SERVER_MODE=${SERVER_MODE:-release}
      - RUN_MODE=${RUN_MODE:-simple}
      - TZ=${TZ:-Asia/Shanghai}
      - DATABASE_HOST=postgres
      - DATABASE_PORT=5432
      - DATABASE_USER=${POSTGRES_USER:-sub2api}
      - DATABASE_PASSWORD=${POSTGRES_PASSWORD:?required}
      - DATABASE_DBNAME=${POSTGRES_DB:-sub2api}
      - DATABASE_SSLMODE=disable
      - REDIS_HOST=redis
      - REDIS_PORT=6379
      - ADMIN_EMAIL=${ADMIN_EMAIL:-admin@sub2api.local}
      - ADMIN_PASSWORD=${ADMIN_PASSWORD:-}
      - JWT_SECRET=${JWT_SECRET:-}
      - JWT_EXPIRE_HOUR=${JWT_EXPIRE_HOUR:-24}
      - TOTP_ENCRYPTION_KEY=${TOTP_ENCRYPTION_KEY:-}
      - SETUP_MIGRATION_TIMEOUT_SECONDS=${SETUP_MIGRATION_TIMEOUT_SECONDS:-0}
      - LOG_LEVEL=${LOG_LEVEL:-info}
      - LOG_FORMAT=${LOG_FORMAT:-json}
      - LOG_OUTPUT_TO_STDOUT=${LOG_OUTPUT_TO_STDOUT:-true}
      - LOG_OUTPUT_TO_FILE=${LOG_OUTPUT_TO_FILE:-false}
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy

  postgres:
    image: postgres:16-alpine
    container_name: sub2api-postgres
    restart: unless-stopped
    environment:
      - POSTGRES_USER=${POSTGRES_USER:-sub2api}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD:?required}
      - POSTGRES_DB=${POSTGRES_DB:-sub2api}
    volumes:
      - /home/louis/sub2api-data/postgres:/var/lib/postgresql/data:Z
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-sub2api}"]
      interval: 5s
      timeout: 5s
      retries: 5

  redis:
    image: redis:8-alpine
    container_name: sub2api-redis
    restart: unless-stopped
    command: redis-server --save 60 1 --loglevel warning
    volumes:
      - /home/louis/sub2api-data/redis:/data:Z
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 5
```

### 3.7 启动服务

```bash
cd /mnt/d/software/sub2api/compose

# 拉取镜像并启动
docker compose up -d

# 查看启动日志
docker compose logs -f sub2api

# 等待出现 "server started" 或类似就绪信息
# 然后检查健康状态
docker compose ps

# 验证服务
curl -s http://127.0.0.1:18080/health
```

### 3.8 首次登录管理后台

1. 在 Windows 浏览器中打开 `http://127.0.0.1:18080`
2. 使用 .env 中的 `ADMIN_EMAIL` 和 `ADMIN_PASSWORD` 登录
3. 完成初始设置向导（如仍需要）

### 3.9 配置 Docker 自启动（WSL 重启后自动恢复）

WSL 的 systemd 会自动启动 docker.service。
但需要确保 WSL 本身在 Windows 开机后自动启动：

```bash
# 方法 1：在 Windows 任务计划程序中添加开机启动
#   程序：wsl.exe -d Ubuntu-24.04 --exec /bin/bash -c "sudo systemctl start docker"
#   触发器：用户登录时

# 方法 2（更简单）：在 Windows 终端中设置 WSL 为开机自启
#   在 Windows 注册表 HKCU\Software\Microsoft\Windows\CurrentVersion\Run
#   添加字符串值 "WSL" = "wsl.exe -d Ubuntu-24.04 --exec /bin/bash -c 'sudo systemctl start docker; sleep 5; cd /mnt/d/software/sub2api/compose && docker compose up -d'"
```

或者更优雅地用 Windows 任务计划程序：

```powershell
# 在 PowerShell 中执行（需要管理员权限）
$action = New-ScheduledTaskAction -Execute "wsl.exe" -Argument "-d Ubuntu-24.04 -- /bin/bash -c 'sudo systemctl start docker && sleep 3 && cd /mnt/d/software/sub2api/compose && docker compose up -d'"
$trigger = New-ScheduledTaskTrigger -AtLogOn
Register-ScheduledTask -TaskName "StartSub2API" -Action $action -Trigger $trigger
```

### 3.10 设置 sudo 免密码（Docker 需要 systemd 启动）

```bash
# 在 WSL 中
sudo visudo -f /etc/sudoers.d/louis-docker
# 添加：
# louis ALL=(ALL) NOPASSWD: /usr/bin/systemctl start docker
# louis ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop docker
# louis ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart docker
```

---

## 4. 导入 Codex 订阅会话

### 4.1 在本机浏览器中登录 ChatGPT

在 Windows 浏览器中访问 `http://127.0.0.1:18080`，
进入管理后台 → 账号管理 → 导入 Codex Session。

### 4.2 获取 Codex 会话凭据

方式 A：从本机 Codex CLI 的 `~/.codex/auth.json` 获取
（如果本机已安装 Codex CLI 并登录过）

方式 B：从浏览器 ChatGPT 登录后的 cookie/token 提取
（Sub2API 后台支持直接粘贴 accessToken 或完整 session JSON）

方式 C：使用 Sub2API admin CLI

```bash
cd /mnt/f/BaiduSyncdisk/version20240608/main_code_space/other/sub2api

# 设置环境变量
export SUB2API_BASE_URL='http://127.0.0.1:18080'
export SUB2API_ADMIN_API_KEY='<在后台设置页面生成>'

# 导入 Codex session
node scripts/sub2api-admin.js accounts import-codex-session --file payload.json
```

> payload.json 格式参考：
> `backend/internal/handler/admin/account_codex_import.go` 中的 `CodexSessionImportRequest`

### 4.3 创建下游 API Key

在管理后台创建一个或多个 API Key，供本机和远程服务器使用。

建议：
- 为本机创建一个 Key
- 为远程服务器单独创建一个 Key（可随时废止）
- 为不同用途创建不同 Key（便于追踪用量）

---

## 5. 本机客户端配置

### 5.1 Codex CLI（可选——如果需要本机 CLI）

由于 Windows npm 的 Codex 在 WSL 中不可用（node not found），
有两种选择：

**选择 A：不装本机 CLI，只用 API**

如果只需要通过 API 调用（curl、VS Code 扩展、其他 OpenAI 兼容客户端），
则不需要安装 Codex CLI。直接设置：

```bash
# 在 WSL 中（~/.bashrc）
export OPENAI_BASE_URL="http://127.0.0.1:18080/v1"
export OPENAI_API_KEY="<你的 Sub2API 下游 Key>"
```

**选择 B：在 WSL 中安装原生 Linux Codex CLI**

```bash
# 1. 安装 Node.js 22 (LTS) —— 用 nvm 管理版本
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.0/install.sh | bash
source ~/.bashrc

# 2. 安装 Node.js 22
nvm install 22
nvm use 22
nvm alias default 22

# 3. 设置 npm 全局安装目录到 D 盘
mkdir -p /mnt/d/software/sub2api/codex-cli/npm-global
npm config set prefix /mnt/d/software/sub2api/codex-cli/npm-global

# 4. 安装 Codex CLI
npm install -g @openai/codex

# 5. 配置环境变量
cat >> ~/.bashrc << 'EOF'
export PATH="/mnt/d/software/sub2api/codex-cli/npm-global/bin:$PATH"
export CODEX_HOME="/mnt/d/software/sub2api/codex-cli/home"
export OPENAI_BASE_URL="http://127.0.0.1:18080/v1"
export OPENAI_API_KEY="<你的 Sub2API 下游 Key>"
EOF
source ~/.bashrc

# 6. 验证
codex --version
```

### 5.2 Windows 侧客户端

在 Windows 终端（PowerShell 或 Git Bash）中：

```powershell
# PowerShell
$env:OPENAI_BASE_URL = "http://127.0.0.1:18080/v1"
$env:OPENAI_API_KEY = "<你的 Sub2API 下游 Key>"

# 或在 Windows 系统环境变量中永久设置
# 设置 → 系统 → 关于 → 高级系统设置 → 环境变量
```

Windows 侧的 Codex CLI（如果已在 Windows 上用 npm 装了）可以直接用：
因为 WSL 的 127.0.0.1 会自动转发到 Windows 的 127.0.0.1。

---

## 6. 远程服务器配置

### 6.1 SSH 隧道

在 Windows 的 `C:\Users\louis\.ssh\config` 中：

```sshconfig
Host your-linux-server
    HostName <服务器IP>
    User <用户名>
    RemoteForward 127.0.0.1:18080 127.0.0.1:18080
    ExitOnForwardFailure yes
    ServerAliveInterval 30
    ServerAliveCountMax 3
```

VS Code Remote-SSH 使用此配置，连接远程时自动建立隧道。

### 6.2 远程服务器上的 Codex CLI

```bash
# 在远程 Linux 服务器上安装 Codex CLI（如果需要）
# 使用官方安装脚本或 nvm + npm
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.0/install.sh | bash
source ~/.bashrc
nvm install 22

npm install -g @openai/codex

# 配置环境变量（~/.bashrc）
export OPENAI_BASE_URL="http://127.0.0.1:18080/v1"
export OPENAI_API_KEY="<为远程服务器单独创建的 Sub2API Key>"
```

### 6.3 验证隧道

```bash
# 在远程服务器上
curl -s http://127.0.0.1:18080/health
# 应返回 {"status":"ok"} 或类似
```

---

## 7. 安全清单

- [x] Sub2API 绑定 `127.0.0.1:18080`，不监听公网
- [x] `.env` 文件权限 `chmod 600`
- [x] `ADMIN_PASSWORD` 使用随机生成的强密码
- [x] JWT_SECRET 和 TOTP_ENCRYPTION_KEY 使用固定随机值
- [x] 为远程服务器单独创建 API Key（可随时废止）
- [x] SSH 使用密钥认证，禁用密码登录
- [x] SSH `RemoteForward` 只绑定 `127.0.0.1`
- [x] 不将 `.env`、auth.json、token 同步到百度网盘/Git
- [x] `RUN_MODE=simple`，跳过 SaaS 计费
- [x] 不对公网/局域网共享上游订阅凭据

---

## 8. 备份策略

```bash
# 定期备份脚本
# /mnt/d/software/sub2api/backups/backup.sh
#!/bin/bash
set -e
BACKUP_DIR="/mnt/d/software/sub2api/backups"
DATE=$(date +%Y%m%d_%H%M%S)

# 备份 PostgreSQL
docker exec sub2api-postgres pg_dump -U sub2api sub2api > \
  "${BACKUP_DIR}/db_${DATE}.sql"

# 备份 .env 和 compose 文件
tar czf "${BACKUP_DIR}/config_${DATE}.tar.gz" \
  -C /mnt/d/software/sub2api/compose .env docker-compose.yml

# 保留最近 7 天
find "${BACKUP_DIR}" -name "*.sql" -mtime +7 -delete
find "${BACKUP_DIR}" -name "*.tar.gz" -mtime +7 -delete

echo "Backup completed: ${DATE}"
```

```bash
# 添加 cron 定时备份（每天凌晨 3 点）
crontab -e
# 添加：
0 3 * * * /mnt/d/software/sub2api/backups/backup.sh >> /mnt/d/software/sub2api/backups/backup.log 2>&1
```

---

## 9. 验收检查清单

| # | 检查项 | 命令 | 预期 |
|---|--------|------|------|
| 1 | Docker 运行 | `docker info` | 无错误 |
| 2 | 三个容器健康 | `docker compose ps` | 全部 healthy |
| 3 | Sub2API 响应 | `curl http://127.0.0.1:18080/health` | 200 OK |
| 4 | 管理后台可访问 | Windows 浏览器 `http://127.0.0.1:18080` | 登录页 |
| 5 | Codex 会话已导入 | 后台 → 账号管理 | 账号状态正常 |
| 6 | 下游 API Key 可用 | `curl -H "Authorization: Bearer <key>" http://127.0.0.1:18080/v1/models` | 模型列表 |
| 7 | API 调用成功 | `curl -X POST .../v1/responses -d '...'` | 正常响应 |
| 8 | WSL 重启后自恢复 | `wsl --shutdown && wsl -d Ubuntu-24.04` → `docker compose ps` | 容器自动启动 |
| 9 | SSH 隧道工作 | 远程 `curl http://127.0.0.1:18080/health` | 200 OK |
| 10 | 远程 API 调用 | 远程 `curl -H "Authorization: Bearer <key>" .../v1/models` | 模型列表 |

---

## 10. 故障排查

### 10.1 apt update 超时/失败

```bash
# 检查网络
ping -c 3 mirrors.aliyun.com
# 如果不通，配置代理（见 2.1 方案 A）
# 或确保 Clash Verge 允许局域网连接

# 如果 DNS 问题
sudo tee /etc/resolv.conf << 'EOF'
nameserver 223.5.5.5
nameserver 8.8.8.8
EOF
```

### 10.2 Docker 容器启动失败

```bash
# 查看日志
docker compose logs sub2api
docker compose logs postgres
docker compose logs redis

# 常见问题：
# - 端口冲突：检查 18080/5432/6379 是否被占用
# - 数据目录权限：sudo chown -R 999:999 /home/louis/sub2api-data/postgres
# - .env 中 POSTGRES_PASSWORD 为空
```

### 10.3 WSL 重启后 Docker 未启动

```bash
# 检查 systemd
systemctl status docker
# 如果未启动
sudo systemctl start docker

# 确保开机自启
sudo systemctl enable docker
```

### 10.4 SSH 隧道断开

```bash
# 检查 RemoteForward 是否生效
# 在远程服务器上
ss -tlnp | grep 18080
# 应看到 127.0.0.1:18080 LISTEN

# 如果没有，重新连接 SSH
# 或在 VS Code 中重新连接 Remote-SSH
```

### 10.5 Codex 订阅 token 过期

- 在管理后台 → 账号管理 → 对应账号 → 刷新/重新导入
- 重新获取 accessToken 或 session JSON
- 使用 admin CLI 批量刷新

### 10.6 /mnt/d 上的 npm/node 性能问题

如果 Codex CLI 安装在 `/mnt/d` 且有明显延迟：
- 方案 1：把 npm-global 移到 WSL ext4 分区（`~/.npm-global`）
- 方案 2：用 nvm 安装的 node 本身已在 ext4 上（`~/.nvm`），只有全局包在 /mnt/d
- 方案 3：放弃 WSL CLI，只通过 API 使用

---

## 11. 目录结构总览

```
D:\software\sub2api\                     ← /mnt/d/software/sub2api/
├── compose\
│   ├── docker-compose.yml               ← 定制后的 compose 文件
│   ├── .env                              ← 机密配置（chmod 600）
│   └── .env.example
├── backups\
│   ├── backup.sh
│   ├── db_20260805_030000.sql
│   └── config_20260805_030000.tar.gz
├── codex-cli\                           ← 可选：本机 Codex CLI 状态
│   ├── npm-global\
│   └── home\                            ← CODEX_HOME
└── docker-data\                         ← 可选：Docker data-root

WSL ext4 分区（~ 即 /home/louis/）：
├── sub2api-data\
│   ├── postgres\                         ← PostgreSQL 数据（高性能）
│   ├── redis\                           ← Redis 持久化
│   └── app\                             ← Sub2API 应用数据
└── .nvm\
    └── versions\node\v22...\           ← Node.js（如安装 CLI）
```

---

## 12. 执行顺序总结

1. [ ] 解决 WSL 网络（镜像源或代理）→ 3.1 前
2. [ ] 安装 Docker Engine → 3.1
3. [ ] 创建部署目录 → 3.3
4. [ ] 复制并定制 compose 文件 → 3.4-3.6
5. [ ] 启动服务 → 3.7
6. [ ] 验证健康 → 3.7 末尾
7. [ ] 登录管理后台 → 3.8
8. [ ] 导入 Codex 会话 → 4
9. [ ] 创建下游 API Key → 4.3
10. [ ] 配置本机客户端 → 5
11. [ ] 配置 SSH 隧道 → 6.1
12. [ ] 配置远程客户端 → 6.2-6.3
13. [ ] 配置自启动 → 3.9-3.10
14. [ ] 配置备份 → 8
15. [ ] 验收 → 9
