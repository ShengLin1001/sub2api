# Sub2API WSL 部署方案 — 快速参考卡

## 一句话方案

在 WSL2 (Ubuntu 24.04) 中安装 Docker Engine，用 Docker Compose 启动 Sub2API + PostgreSQL + Redis，
绑定 127.0.0.1:18080，通过 SSH RemoteForward 让远程服务器访问。

## 文件清单

| 文件 | 用途 |
|------|------|
| prompts/wsl-sub2api-deploy-plan.md | 完整详细方案文档 |
| prompts/wsl-docker-compose.yml | 定制好的 compose 文件（直接用） |
| prompts/wsl-init.sh | 一键初始化脚本 |
| prompts/wsl-backup.sh | 备份脚本 |

## 快速执行

```bash
# 1. 在 WSL 中运行一键初始化
bash /mnt/f/BaiduSyncdisk/version20240608/main_code_space/other/sub2api/prompts/wsl-init.sh

# 2. 记录输出的密码

# 3. 浏览器打开 http://127.0.0.1:18080 登录管理后台

# 4. 导入 Codex 会话 → 创建 API Key

# 5. 配置客户端环境变量
export OPENAI_BASE_URL="http://127.0.0.1:18080/v1"
export OPENAI_API_KEY="<你的 Key>"
```

## 关键端口

| 端口 | 用途 | 绑定 |
|------|------|------|
| 18080 | Sub2API | 127.0.0.1 only |
| 5432 | PostgreSQL | 容器内 only |
| 6379 | Redis | 容器内 only |

## 关键目录

| 路径（WSL） | 路径（Windows） | 用途 |
|---|---|---|
| /mnt/d/software/sub2api/compose/ | D:\software\sub2api\compose\ | compose + .env |
| /mnt/d/software/sub2api/backups/ | D:\software\sub2api\backups\ | 备份 |
| /mnt/d/software/sub2api/codex-cli/ | D:\software\sub2api\codex-cli\ | Codex CLI（可选） |
| /home/louis/sub2api-data/ | — | 数据库+Redis 数据（ext4 性能） |

## SSH 隧道配置

在 Windows 的 C:\Users\louis\.ssh\config 中：

```
Host your-linux-server
    HostName <IP>
    User <用户名>
    RemoteForward 127.0.0.1:18080 127.0.0.1:18080
    ExitOnForwardFailure yes
    ServerAliveInterval 30
```

## 常用运维命令

```bash
cd /mnt/d/software/sub2api/compose

docker compose ps          # 查看状态
docker compose logs -f sub2api  # 查看日志
docker compose restart sub2api # 重启应用
docker compose down        # 停止全部
docker compose up -d       # 启动全部
docker compose pull        # 拉取新版本
```
