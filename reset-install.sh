#!/usr/bin/env bash
# 强制未安装：清锁、杀残留、重启，并打印诊断
set -euo pipefail
SITE="${1:-/www/wwwroot/auth.maizll.com}"
PORT="${PORT:-19127}"
SERVICE="${SERVICE:-auth-pro}"
BIN="$SITE/backend/auth_pro"
DATA_DIR="${AUTO_PRO_DATA_DIR:-$SITE/backend/data}"

echo "[reset] site=$SITE"
echo "[reset] bin=$BIN data=$DATA_DIR"

systemctl stop "$SERVICE" 2>/dev/null || true
pkill -f "$BIN" 2>/dev/null || true
sleep 1
if command -v fuser >/dev/null 2>&1; then
  fuser -k "${PORT}/tcp" 2>/dev/null || true
fi

echo "[reset] 扫描 install.lock / db.json："
find "$SITE" \( -name 'install.lock' -o -name 'db.json' \) -type f -print 2>/dev/null || true
find "$SITE" \( -name 'install.lock' -o -name 'db.json' \) -type f -delete 2>/dev/null || true
rm -f "$SITE/backend/install.lock" "$SITE/backend/db.json" \
      "$SITE/backend/data/install.lock" "$SITE/backend/data/db.json" \
      "$SITE/install.lock" "$SITE/db.json"

if [[ "${RESET_DATA:-1}" == "1" ]]; then
  mkdir -p "$SITE/backend/data"
  find "$SITE/backend/data" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
  mkdir -p "$SITE/backend/data"
fi

if [[ ! -x "$BIN" ]]; then
  echo "[reset] ✗ 二进制不存在或不可执行: $BIN"
  ls -la "$SITE/backend" || true
  exit 1
fi
chmod +x "$BIN"

# 确保 systemd 单元存在且 DATA_DIR 正确
UNIT="/etc/systemd/system/${SERVICE}.service"
if [[ ! -f "$UNIT" ]]; then
  echo "[reset] 写入缺失的 systemd 单元"
  cat > "$UNIT" <<EOF
[Unit]
Description=Auth Pro Backend (cloud-control-auth)
After=network.target

[Service]
Type=simple
WorkingDirectory=$SITE/backend
ExecStart=$BIN
Restart=on-failure
RestartSec=5
Environment=PORT=$PORT
Environment=AUTO_PRO_DATA_DIR=$DATA_DIR
Environment=SOFTWARE_SOURCE_DATA_DIR=$SITE/backend/software-source/data

[Install]
WantedBy=multi-user.target
EOF
else
  # 纠正 WorkingDirectory / DATA_DIR
  sed -i "s|^WorkingDirectory=.*|WorkingDirectory=$SITE/backend|" "$UNIT" || true
  if grep -q '^Environment=AUTO_PRO_DATA_DIR=' "$UNIT"; then
    sed -i "s|^Environment=AUTO_PRO_DATA_DIR=.*|Environment=AUTO_PRO_DATA_DIR=$DATA_DIR|" "$UNIT"
  else
    echo "Environment=AUTO_PRO_DATA_DIR=$DATA_DIR" >> "$UNIT"
  fi
  if grep -q '^Environment=PORT=' "$UNIT"; then
    sed -i "s|^Environment=PORT=.*|Environment=PORT=$PORT|" "$UNIT"
  else
    echo "Environment=PORT=$PORT" >> "$UNIT"
  fi
  if grep -q '^Environment=SOFTWARE_SOURCE_DATA_DIR=' "$UNIT"; then
    sed -i "s|^Environment=SOFTWARE_SOURCE_DATA_DIR=.*|Environment=SOFTWARE_SOURCE_DATA_DIR=$SITE/backend/software-source/data|" "$UNIT"
  else
    echo "Environment=SOFTWARE_SOURCE_DATA_DIR=$SITE/backend/software-source/data" >> "$UNIT"
  fi
  # 去掉可能妨碍写数据的沙箱
  sed -i '/^ProtectSystem=/d;/^PrivateTmp=/d;/^NoNewPrivileges=/d' "$UNIT" || true
fi


# 缺 catalog.json 会导致 auth_pro 启动 Fatal
mkdir -p "$SITE/backend/software-source/data"
if [[ ! -f "$SITE/backend/software-source/data/catalog.json" ]]; then
  if [[ -f "$(dirname "$0")/seed/software-source-catalog/catalog.json" ]]; then
    cp -a "$(dirname "$0")/seed/software-source-catalog/catalog.json" "$SITE/backend/software-source/data/catalog.json"
  else
    cat > "$SITE/backend/software-source/data/catalog.json" <<'JSON'
{
  "revision": 1,
  "sources": [
    { "id": "local", "name": "本地软件源", "type": "json", "state": "ok" }
  ],
  "categories": [],
  "plugins": [],
  "templates": []
}
JSON
  fi
  echo "[reset] ✓ 已写入 software-source catalog.json"
fi

systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null 2>&1 || true
systemctl restart "$SERVICE" || true
sleep 2

PID=$(systemctl show -p MainPID --value "$SERVICE" 2>/dev/null || echo 0)
ACTIVE=$(systemctl is-active "$SERVICE" 2>/dev/null || echo unknown)
echo "[reset] active=$ACTIVE pid=$PID"

if [[ "$ACTIVE" != "active" || "$PID" == "0" || -z "$PID" ]]; then
  echo "[reset] ✗ 服务未运行，journal 如下："
  journalctl -u "$SERVICE" -n 80 --no-pager || true
  echo "[reset] 尝试前台启动看报错："
  (cd "$SITE/backend" && PORT="$PORT" AUTO_PRO_DATA_DIR="$DATA_DIR" timeout 3 "$BIN") || true
fi

if [[ -n "$PID" && "$PID" != 0 && -r "/proc/$PID/environ" ]]; then
  echo "[reset] environ:"
  tr '\0' '\n' < "/proc/$PID/environ" | grep -E '^(PORT|AUTO_PRO_DATA_DIR|PWD)=' || true
fi

echo "[reset] local status: $(curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/api/install/status" 2>/dev/null || echo FAIL)"
echo "[reset] public status: $(curl -fsS --max-time 5 "https://auth.maizll.com/api/install/status" 2>/dev/null || echo FAIL)"
echo "[reset] 期望 local/public 均为 {\"installed\":false} 后再打开网站"
