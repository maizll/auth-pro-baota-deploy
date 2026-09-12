#!/usr/bin/env bash
# install.sh — auth_pro 宝塔一键部署入口
# 布局: index.html, assets/, backend/auth_pro, manifest.json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/deps.sh
source "${SCRIPT_DIR}/lib/deps.sh"

# ---------- 默认值 ----------
DEFAULT_PORT=19127
DEFAULT_VERSION="1.2.0"
SITE_ROOT=""
PORT="${PORT:-${DEFAULT_PORT}}"
PACKAGE_FILE=""
VERSION=""
PACKAGE_URL=""
DATA_DIR="${AUTO_PRO_DATA_DIR:-}"
ASSUME_YES=0
DO_UNINSTALL=0
DO_PURGE=0
SKIP_DEPS=0
SERVICE_NAME="auth-pro"
BINARY_REL="backend/auth_pro"

# ---------- 日志 ----------
log()  { printf '[install] %s\n' "$*"; }
ok()   { printf '[install] ✓ %s\n' "$*"; }
warn() { printf '[install] ⚠ %s\n' "$*" >&2; }
err()  { printf '[install] ✗ %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<'USAGE'
auth-pro 宝塔一键部署脚本

用法:
  bash install.sh [选项]

选项:
  --site-root <路径>     站点根目录（必填，除非卸载时能推断）
                         例: /www/wwwroot/auth.example.com
  --port <端口>          后端监听端口（默认 19127，可用环境变量 PORT）
  --package <文件>       本地 auth_pro-full-vX.Y.Z.tar.gz 路径
  --version <X.Y.Z>      版本号，用于拼接默认下载 URL
  --url <URL>            完整下载地址（覆盖 --version 默认 URL）
  --data-dir <路径>      数据目录（环境变量 AUTO_PRO_DATA_DIR）
  --yes, -y              自动确认依赖安装与覆盖操作
  --skip-deps            跳过依赖检测/自动安装
  --uninstall            停止并移除服务单元（保留站点文件）
  --purge                卸载并删除站点内后端与本脚本写入的配置
  --help, -h             显示帮助

环境变量:
  PORT                     后端端口（同 --port）
  AUTO_PRO_DATA_DIR        数据目录（同 --data-dir）
  SOFTWARE_SOURCE_ADMIN_KEY  软件源管理密钥（由 auth_pro 读取，部署时请自行写入
                             systemd Environment= 或 supervisor environment）

示例（宝塔 SSH 一键）:
  cd /tmp && git clone https://github.com/zxcvbnm25/auth-pro-baota-deploy.git \
    && cd auth-pro-baota-deploy \
    && sudo bash install.sh --site-root /www/wwwroot/你的站点 --version 1.2.0 --yes

默认包地址:
  https://github.com/zxcvbnm25/cloud-control-auth/releases/download/vX.Y.Z/auth_pro-full-vX.Y.Z.tar.gz
USAGE
}

# ---------- 参数解析 ----------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --site-root)
        SITE_ROOT="${2:-}"; shift 2 ;;
      --port)
        PORT="${2:-}"; shift 2 ;;
      --package)
        PACKAGE_FILE="${2:-}"; shift 2 ;;
      --version)
        VERSION="${2:-}"; shift 2 ;;
      --url)
        PACKAGE_URL="${2:-}"; shift 2 ;;
      --data-dir)
        DATA_DIR="${2:-}"; shift 2 ;;
      --yes|-y)
        ASSUME_YES=1; DEPS_YES=1; shift ;;
      --skip-deps)
        SKIP_DEPS=1; shift ;;
      --uninstall)
        DO_UNINSTALL=1; shift ;;
      --purge)
        DO_UNINSTALL=1; DO_PURGE=1; shift ;;
      --help|-h)
        usage; exit 0 ;;
      *)
        die "未知参数: $1（使用 --help 查看说明）" ;;
    esac
  done
}

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    warn "建议使用 root（sudo）运行，以便安装依赖与写入 systemd/supervisor"
  fi
}

resolve_package_url() {
  if [[ -n "${PACKAGE_URL}" ]]; then
    return 0
  fi
  local ver="${VERSION:-${DEFAULT_VERSION}}"
  VERSION="${ver}"
  PACKAGE_URL="https://github.com/zxcvbnm25/cloud-control-auth/releases/download/v${ver}/auth_pro-full-v${ver}.tar.gz"
}

ensure_site_root() {
  if [[ -z "${SITE_ROOT}" ]]; then
    if [[ -d /www/wwwroot ]]; then
      die "请通过 --site-root 指定站点目录。可用: ls /www/wwwroot"
    fi
    die "请通过 --site-root 指定站点根目录"
  fi
  mkdir -p "${SITE_ROOT}"
  SITE_ROOT="$(cd "${SITE_ROOT}" && pwd)"
}

# ---------- 下载 / 解压 ----------
download_or_use_package() {
  local tmp
  tmp="$(mktemp -d /tmp/auth-pro-deploy.XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  local archive=""
  if [[ -n "${PACKAGE_FILE}" ]]; then
    [[ -f "${PACKAGE_FILE}" ]] || die "本地包不存在: ${PACKAGE_FILE}"
    archive="${PACKAGE_FILE}"
    log "使用本地包: ${archive}"
  else
    resolve_package_url
    archive="${tmp}/auth_pro-full.tar.gz"
    log "下载: ${PACKAGE_URL}"
    deps_download "${PACKAGE_URL}" "${archive}" \
      || die "下载失败，请检查 --url / --version 或网络（GitHub Releases）"
    ok "下载完成"
  fi

  log "解压到站点根目录: ${SITE_ROOT}"
  # 备份已有二进制
  local bin_path="${SITE_ROOT}/${BINARY_REL}"
  if [[ -f "${bin_path}" ]]; then
    local bak="${bin_path}.bak.$(date +%Y%m%d%H%M%S)"
    log "升级备份: ${bin_path} → ${bak}"
    cp -a "${bin_path}" "${bak}"
  fi

  tar -xzf "${archive}" -C "${SITE_ROOT}"
  ok "解压完成"

  if [[ ! -f "${SITE_ROOT}/${BINARY_REL}" ]]; then
    # 兼容包内带顶层目录的情况
    local nested
    nested="$(find "${SITE_ROOT}" -maxdepth 3 -type f -name 'auth_pro' -path '*/backend/*' 2>/dev/null | head -1 || true)"
    if [[ -n "${nested}" && "${nested}" != "${SITE_ROOT}/${BINARY_REL}" ]]; then
      warn "检测到嵌套路径 ${nested}，请确认包布局是否为站点根直接含 backend/"
    fi
    die "解压后未找到 ${BINARY_REL}，请检查包内容（期望: index.html, assets/, backend/auth_pro, manifest.json）"
  fi

  chmod +x "${SITE_ROOT}/${BINARY_REL}"
  ok "已 chmod +x ${BINARY_REL}"

  if [[ -f "${SITE_ROOT}/manifest.json" ]]; then
    ok "发现 manifest.json"
  else
    warn "未发现 manifest.json（非致命）"
  fi
}

# ---------- 数据目录 ----------
prepare_data_dir() {
  if [[ -z "${DATA_DIR}" ]]; then
    DATA_DIR="${SITE_ROOT}/data"
  fi
  mkdir -p "${DATA_DIR}"
  ok "数据目录: ${DATA_DIR}"
  export AUTO_PRO_DATA_DIR="${DATA_DIR}"
  export PORT="${PORT}"
}

# ---------- systemd ----------
install_systemd_unit() {
  local unit="/etc/systemd/system/${SERVICE_NAME}.service"
  local bin="${SITE_ROOT}/${BINARY_REL}"
  log "写入 systemd 单元: ${unit}"
  cat > "${unit}" <<UNIT
[Unit]
Description=Auth Pro Backend (cloud-control-auth)
After=network.target

[Service]
Type=simple
WorkingDirectory=${SITE_ROOT}
ExecStart=${bin}
Restart=on-failure
RestartSec=5
Environment=PORT=${PORT}
Environment=AUTO_PRO_DATA_DIR=${DATA_DIR}
# Environment=SOFTWARE_SOURCE_ADMIN_KEY=请替换为你的密钥

# 安全加固（可按需调整）
NoNewPrivileges=true
ProtectSystem=full
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}.service"
  systemctl restart "${SERVICE_NAME}.service"
  ok "systemd 服务已启用并启动: ${SERVICE_NAME}"
  systemctl --no-pager -l status "${SERVICE_NAME}.service" || true
}

# ---------- supervisor ----------
find_supervisor_conf_dir() {
  local candidates=(
    /etc/supervisor/conf.d
    /etc/supervisord.d
    /etc/supervisor.d
  )
  local d
  for d in "${candidates[@]}"; do
    if [[ -d "${d}" ]]; then
      echo "${d}"
      return 0
    fi
  done
  # 尝试创建常见路径
  if [[ -d /etc/supervisor ]]; then
    mkdir -p /etc/supervisor/conf.d
    echo /etc/supervisor/conf.d
    return 0
  fi
  mkdir -p /etc/supervisord.d
  echo /etc/supervisord.d
}

install_supervisor_program() {
  local conf_dir conf
  conf_dir="$(find_supervisor_conf_dir)"
  conf="${conf_dir}/${SERVICE_NAME}.conf"
  local bin="${SITE_ROOT}/${BINARY_REL}"
  log "写入 supervisor 配置: ${conf}"
  cat > "${conf}" <<SUP
[program:${SERVICE_NAME}]
command=${bin}
directory=${SITE_ROOT}
autostart=true
autorestart=true
startsecs=3
stopwaitsecs=10
redirect_stderr=true
stdout_logfile=/var/log/${SERVICE_NAME}.out.log
environment=PORT="${PORT}",AUTO_PRO_DATA_DIR="${DATA_DIR}"
;environment=PORT="${PORT}",AUTO_PRO_DATA_DIR="${DATA_DIR}",SOFTWARE_SOURCE_ADMIN_KEY="请替换"
SUP
  if command -v supervisorctl >/dev/null 2>&1; then
    supervisorctl reread || true
    supervisorctl update || true
    supervisorctl restart "${SERVICE_NAME}" || supervisorctl start "${SERVICE_NAME}" || true
    ok "supervisor 程序已更新: ${SERVICE_NAME}"
    supervisorctl status "${SERVICE_NAME}" || true
  else
    warn "无 supervisorctl，请手动 reload supervisord"
  fi
}

install_process_service() {
  case "${DEPS_PROCESS_MGR}" in
    systemd)
      install_systemd_unit
      ;;
    supervisor)
      install_supervisor_program
      ;;
    *)
      # 再次检测
      deps_detect_process_mgr
      case "${DEPS_PROCESS_MGR}" in
        systemd) install_systemd_unit ;;
        supervisor) install_supervisor_program ;;
        *)
          warn "无进程管理器，二进制已就位，请手动启动:"
          warn "  PORT=${PORT} AUTO_PRO_DATA_DIR=${DATA_DIR} ${SITE_ROOT}/${BINARY_REL} &"
          ;;
      esac
      ;;
  esac
}

# ---------- Nginx 提示 ----------
print_nginx_hint() {
  local snippet="${SCRIPT_DIR}/examples/nginx.conf.snippet"
  echo
  log "======== Nginx 反向代理提示 ========"
  if [[ "${DEPS_HAS_NGINX}" != "1" ]]; then
    warn "未检测到 Nginx：请在宝塔「软件商店」安装 Nginx，再在站点配置中加入反代"
  fi
  log "请在宝塔站点「配置文件」中加入类似片段（端口 ${PORT}）:"
  if [[ -f "${snippet}" ]]; then
    sed "s/__PORT__/${PORT}/g; s|__SITE_ROOT__|${SITE_ROOT}|g" "${snippet}"
  else
    cat <<NGX
    location /api/ {
        proxy_pass http://127.0.0.1:${PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
NGX
  fi
  log "静态资源由站点根目录直接提供（index.html / assets/）"
  echo
}

# ---------- 卸载 ----------
uninstall_service() {
  log "卸载服务: ${SERVICE_NAME}"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload 2>/dev/null || true
    ok "已移除 systemd 单元"
  fi
  local d conf
  for d in /etc/supervisor/conf.d /etc/supervisord.d /etc/supervisor.d; do
    conf="${d}/${SERVICE_NAME}.conf"
    if [[ -f "${conf}" ]]; then
      rm -f "${conf}"
      ok "已删除 ${conf}"
      supervisorctl reread 2>/dev/null || true
      supervisorctl update 2>/dev/null || true
    fi
  done

  if [[ "${DO_PURGE}" -eq 1 ]]; then
    if [[ -z "${SITE_ROOT}" ]]; then
      die "--purge 需要 --site-root"
    fi
    ensure_site_root
    log "清理站点内后端相关文件（保留前端静态资源需自行确认）..."
    if [[ -f "${SITE_ROOT}/${BINARY_REL}" ]]; then
      rm -f "${SITE_ROOT}/${BINARY_REL}"
      rm -f "${SITE_ROOT}/${BINARY_REL}".bak.* 2>/dev/null || true
      ok "已删除 ${BINARY_REL} 及备份"
    fi
    if [[ -n "${DATA_DIR}" && -d "${DATA_DIR}" && "${DATA_DIR}" == "${SITE_ROOT}/data" ]]; then
      if [[ "${ASSUME_YES}" -eq 1 ]]; then
        rm -rf "${DATA_DIR}"
        ok "已删除数据目录 ${DATA_DIR}"
      else
        warn "数据目录 ${DATA_DIR} 未删除（使用 --yes --purge 可删除默认 data/）"
      fi
    fi
  fi
  ok "卸载完成"
}

# ---------- 收尾摘要 ----------
print_summary() {
  cat <<SUM

======== 部署完成 ========
站点根目录:  ${SITE_ROOT}
后端二进制:  ${SITE_ROOT}/${BINARY_REL}
监听端口:    ${PORT}
数据目录:    ${DATA_DIR}
进程管理:    ${DEPS_PROCESS_MGR}

后续步骤:
  1. 在宝塔面板为该站点配置 Nginx 反代（见上方片段）
  2. 在宝塔「数据库」中创建 MySQL，并按 auth_pro 文档配置连接
  3. 如需管理密钥，设置 SOFTWARE_SOURCE_ADMIN_KEY 后重启服务:
       systemctl restart ${SERVICE_NAME}
       # 或: supervisorctl restart ${SERVICE_NAME}
  4. 放行防火墙/安全组端口（若直连后端）或仅内网反代

安全建议:
  - 不要将 SOFTWARE_SOURCE_ADMIN_KEY 写入可公开访问的文件
  - 站点目录权限避免 777；后端仅需执行权限
  - 优先通过 Nginx HTTPS 对外，勿直接暴露 ${PORT}
SUM
}

# ---------- main ----------
main() {
  parse_args "$@"
  need_root

  if [[ "${DO_UNINSTALL}" -eq 1 ]]; then
    if [[ "${SKIP_DEPS}" -eq 0 ]]; then
      deps_detect_process_mgr || true
    fi
    uninstall_service
    exit 0
  fi

  ensure_site_root

  if [[ "${SKIP_DEPS}" -eq 1 ]]; then
    warn "已跳过依赖检测 (--skip-deps)"
    deps_detect_process_mgr || true
    deps_detect_nginx || true
  else
    local dep_args=()
    [[ "${ASSUME_YES}" -eq 1 ]] && dep_args+=(--yes)
    deps_run_all "${dep_args[@]+"${dep_args[@]}"}" || die "依赖检测/安装失败"
  fi

  download_or_use_package
  prepare_data_dir
  install_process_service
  print_nginx_hint
  print_summary
}

main "$@"
