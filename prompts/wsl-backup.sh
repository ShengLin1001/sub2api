#!/bin/bash
# Sub2API 备份脚本
# 用法：手动运行或通过 cron 每天执行
# 放置位置：/mnt/d/software/sub2api/backups/backup.sh

set -e

BACKUP_DIR="/mnt/d/software/sub2api/backups"
DATE=$(date +%Y%m%d_%H%M%S)

mkdir -p "${BACKUP_DIR}"

echo "[$(date)] Starting backup..."

# 备份 PostgreSQL
echo "  Backing up PostgreSQL..."
docker exec sub2api-postgres pg_dump -U sub2api sub2api > \
  "${BACKUP_DIR}/db_${DATE}.sql"
echo "  Done: db_${DATE}.sql ($(du -h "${BACKUP_DIR}/db_${DATE}.sql" | cut -f1))"

# 备份配置文件
echo "  Backing up config..."
tar czf "${BACKUP_DIR}/config_${DATE}.tar.gz" \
  -C /mnt/d/software/sub2api/compose .env docker-compose.yml 2>/dev/null || true
echo "  Done: config_${DATE}.tar.gz"

# 清理 7 天前的备份
echo "  Cleaning old backups..."
find "${BACKUP_DIR}" -name "db_*.sql" -mtime +7 -delete 2>/dev/null || true
find "${BACKUP_DIR}" -name "config_*.tar.gz" -mtime +7 -delete 2>/dev/null || true

echo "[$(date)] Backup completed."
