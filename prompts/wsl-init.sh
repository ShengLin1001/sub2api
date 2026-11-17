#!/bin/bash
# Sub2API WSL 部署一键初始化脚本
# 用法：在 WSL 中执行
#   bash /mnt/d/software/sub2api/prompts/wsl-init.sh
#
# 本脚本完成：
# 1. 安装 Docker Engine（用阿里云镜像源）
# 2. 创建部署目录
# 3. 生成 .env（含随机密钥）
# 4. 复制定制 compose 文件
# 5. 启动服务
# 6. 验证健康

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}=== Sub2API WSL 部署初始化 ===${NC}"

# ============================================================
# Step 0: 检查前置条件
# ============================================================
echo -e "${YELLOW}[0/6] 检查前置条件...${NC}"

if [ "$(id -un)" != "louis" ]; then
  echo -e "${RED}错误：请以 louis 用户运行此脚本${NC}"
  exit 1
fi

if ! grep -q systemd /etc/wsl.conf 2>/dev/null; then
  echo -e "${RED}错误：WSL systemd 未启用。请在 /etc/wsl.conf 中设置 [boot] systemd=true${NC}"
  exit 1
fi

echo -e "${GREEN}  WSL 用户: $(id -un) | systemd: 已启用${NC}"

# ============================================================
# Step 1: 安装 Docker Engine
# ============================================================
echo -e "${YELLOW}[1/6] 安装 Docker Engine...${NC}"

if command -v docker &>/dev/null; then
  echo -e "${GREEN}  Docker 已安装: $(docker --version)${NC}"
else
  echo "  安装依赖..."
  sudo apt-get update -qq
  sudo apt-get install -y ca-certificates curl gnupg lsb-release jq >/dev/null 2>&1

  echo "  添加 Docker GPG key（阿里云镜像）..."
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg | \
    sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  echo "  添加 Docker apt 源..."
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://mirrors.aliyun.com/docker-ce/linux/ubuntu $(lsb_release -cs) stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  echo "  安装 Docker..."
  sudo apt-get update -qq
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1

  echo "  添加 louis 到 docker 组..."
  sudo usermod -aG docker louis

  echo "  启动 Docker 服务..."
  sudo systemctl enable docker >/dev/null 2>&1
  sudo systemctl start docker

  echo -e "${GREEN}  Docker 安装完成: $(docker --version 2>/dev/null || echo '请重新登录后验证')${NC}"
  echo -e "${YELLOW}  注意：请重新登录 WSL（或运行 newgrp docker）以使 docker 组生效${NC}"
fi

# ============================================================
# Step 2: 创建部署目录
# ============================================================
echo -e "${YELLOW}[2/6] 创建部署目录...${NC}"

# D 盘目录（配置、备份）
mkdir -p /mnt/d/software/sub2api/compose
mkdir -p /mnt/d/software/sub2api/backups

# WSL ext4 目录（数据，高性能）
mkdir -p /home/louis/sub2api-data/postgres
mkdir -p /home/louis/sub2api-data/redis
mkdir -p /home/louis/sub2api-data/app

echo -e "${GREEN}  部署目录: /mnt/d/software/sub2api/compose/${NC}"
echo -e "${GREEN}  数据目录: /home/louis/sub2api-data/${NC}"

# ============================================================
# Step 3: 生成 .env
# ============================================================
echo -e "${YELLOW}[3/6] 生成 .env...${NC}"

COMPOSE_DIR="/mnt/d/software/sub2api/compose"

if [ -f "${COMPOSE_DIR}/.env" ]; then
  echo -e "${YELLOW}  .env 已存在，跳过生成。如需重新生成请先删除。${NC}"
else
  PG_PASS=$(openssl rand -hex 16)
  JWT=$(openssl rand -hex 32)
  TOTP=$(openssl rand -hex 32)
  ADMIN_PW=$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)

  cat > "${COMPOSE_DIR}/.env" << EOF
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
ADMIN_PASSWORD=${ADMIN_PW}

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

  chmod 600 "${COMPOSE_DIR}/.env"

  echo -e "${GREEN}  .env 已生成${NC}"
  echo -e "${CYAN}  === 请记录以下密码 ===${NC}"
  grep -E 'POSTGRES_PASSWORD|ADMIN_PASSWORD|JWT_SECRET|TOTP_ENCRYPTION_KEY' "${COMPOSE_DIR}/.env"
  echo ""
fi

# ============================================================
# Step 4: 复制定制 compose 文件
# ============================================================
echo -e "${YELLOW}[4/6] 复制 compose 文件...${NC}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_COMPOSE="${SCRIPT_DIR}/wsl-docker-compose.yml"

if [ ! -f "${SOURCE_COMPOSE}" ]; then
  echo -e "${YELLOW}  未找到 wsl-docker-compose.yml，从仓库复制默认版本...${NC}"
  SOURCE_COMPOSE="/mnt/f/BaiduSyncdisk/version20240608/main_code_space/other/sub2api/deploy/docker-compose.local.yml"
fi

cp "${SOURCE_COMPOSE}" "${COMPOSE_DIR}/docker-compose.yml"
echo -e "${GREEN}  compose 文件: ${COMPOSE_DIR}/docker-compose.yml${NC}"

# ============================================================
# Step 5: 启动服务
# ============================================================
echo -e "${YELLOW}[5/6] 启动服务...${NC}"

cd "${COMPOSE_DIR}"

# 如果 docker 组还没生效，用 sudo
if ! docker info &>/dev/null; then
  echo -e "${YELLOW}  docker 命令需要 sudo（请重新登录后免 sudo）...${NC}"
  SUDO=sudo
else
  SUDO=""
fi

${SUDO} docker compose pull
${SUDO} docker compose up -d

echo -e "${GREEN}  服务已启动${NC}"

# ============================================================
# Step 6: 验证
# ============================================================
echo -e "${YELLOW}[6/6] 验证服务健康...${NC}"

echo "  等待容器就绪（最多 60 秒）..."
for i in $(seq 1 12); do
  sleep 5
  HEALTHY=$(${SUDO} docker compose ps --format json 2>/dev/null | jq -r '.Health' 2>/dev/null | head -1 || echo "unknown")
  echo "  [$i/12] 状态: ${HEALTHY}"
  if [ "${HEALTHY}" = "healthy" ] || curl -sf http://127.0.0.1:18080/health >/dev/null 2>&1; then
    echo -e "${GREEN}  服务已就绪！${NC}"
    break
  fi
done

echo ""
echo "  健康检查："
curl -s http://127.0.0.1:18080/health || echo -e "${RED}  健康检查失败${NC}"

echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${GREEN}部署完成！${NC}"
echo ""
echo "  管理后台: http://127.0.0.1:18080"
echo "  配置文件: ${COMPOSE_DIR}/.env"
echo "  compose:  ${COMPOSE_DIR}/docker-compose.yml"
echo ""
echo "  下一步："
echo "  1. 在浏览器中打开 http://127.0.0.1:18080"
echo "  2. 用 .env 中的 ADMIN_EMAIL 和 ADMIN_PASSWORD 登录"
echo "  3. 导入 Codex 订阅会话"
echo "  4. 创建下游 API Key"
echo ""
echo -e "${CYAN}========================================${NC}"
