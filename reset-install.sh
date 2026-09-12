#!/usr/bin/env bash
# 强制未安装：清锁、杀残留、重启，并打印诊断
set -euo pipefail
SITE="${1:-/www/wwwroot/auth.maizll.com}"
PORT="${PORT:-19127}"
SERVICE="${SERVICE:-auth-pro}"

echo "[reset] site=$SITE"
systemctl stop "$SERVICE" 2>/dev/null || true
pkill -f "$SITE/backend/auth_pro" 2>/dev/null || true
if command -v fuser >/dev/null 2>&1; then
  fuser -k "${PORT}/tcp" 2>/dev/null || true
fi

echo "[reset] 扫描 install.lock / db.json："
find "$SITE" \( -name 'install.lock' -o -name 'db.json' \) -type f -print 2>/dev/null || true
find "$SITE" \( -name 'install.lock' -o -name 'db.json' \) -type f -delete 2>/dev/null || true

# 兼容旧布局：锁在 backend/ 下
rm -f "$SITE/backend/install.lock" "$SITE/backend/db.json" \
      "$SITE/backend/data/install.lock" "$SITE/backend/data/db.json" \
      "$SITE/install.lock" "$SITE/db.json"

# 可选清空 data（保留目录）
if [[ "${RESET_DATA:-1}" == "1" ]]; then
  rm -rf "$SITE/backend/data"/*
  mkdir -p "$SITE/backend/data"
fi

systemctl daemon-reload 2>/dev/null || true
systemctl start "$SERVICE" 2>/dev/null || true
sleep 1
PID=$(systemctl show -p MainPID --value "$SERVICE" 2>/dev/null || echo 0)
echo "[reset] pid=$PID"
if [[ -n "$PID" && "$PID" != 0 && -r /proc/$PID/environ ]]; then
  echo "[reset] environ:"
  tr '\0' '\n' < /proc/$PID/environ | grep -E '^(PORT|AUTO_PRO_DATA_DIR|PWD)=' || true
fi
echo "[reset] local status: $(curl -fsS --max-time 3 http://127.0.0.1:${PORT}/api/install/status || echo FAIL)"
echo "[reset] public status: $(curl -fsS --max-time 5 https://auth.maizll.com/api/install/status || echo FAIL)"
echo "[reset] 若仍为 installed:true，把上面 environ 与 find 结果发给维护者"
