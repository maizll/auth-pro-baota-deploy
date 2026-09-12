#!/usr/bin/env bash
# install.sh — auth_pro 宝塔「真·全自动一键」部署入口
# 布局: index.html, assets/, backend/auth_pro, manifest.json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/deps.sh
source "${SCRIPT_DIR}/lib/deps.sh"
# shellcheck source=lib/probe.sh
source "${SCRIPT_DIR}/lib/probe.sh"
# shellcheck source=lib/baota.sh
source "${SCRIPT_DIR}/lib/baota.sh"
# shellcheck source=lib/nginx_write.sh
source "${SCRIPT_DIR}/lib/nginx_write.sh"
# shellcheck source=lib/seed.sh
source "${SCRIPT_DIR}/lib/seed.sh"

# ---------- 默认值 ----------
DEFAULT_PORT=19127
DEFAULT_VERSION="1.2.0"
SITE_ROOT=""
PORT="${PORT:-${DEFAULT_PORT}}"
PACKAGE_FILE=""
PACKAGE_VERSION=""
PACKAGE_URL=""
DATA_DIR="${AUTO_PRO_DATA_DIR:-}"
ASSUME_YES=0
DO_UNINSTALL=0
DO_PURGE=0
DO_FRESH=0
SKIP_DEPS=0
SKIP_FIREWALL=0
SKIP_NGINX_WRITE=0
SKIP_PROBE=0
SEED_SOFTWARE_SOURCE=-1   # -1=随 --yes 默认开; 0=关; 1=开
SOFTWARE_SOURCE_ADMIN_KEY_FLAG="${SOFTWARE_SOURCE_ADMIN_KEY:-}"
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
auth-pro 宝塔「真·全自动一键」部署脚本

用法:
  bash install.sh --site-root <路径> --package <包> --yes
  bash install.sh --site-root <路径> --version 1.2.0 --yes

选项:
  --site-root <路径>     站点根目录（必填，除非卸载时能推断）
                         例: /www/wwwroot/auth.example.com
  --port <端口>          后端监听端口（默认 19127，可用环境变量 PORT）
  --package <文件>       本地 auth_pro-full-vX.Y.Z.tar.gz 路径（推荐：GitHub 可能被墙）
  --version <X.Y.Z>      版本号，用于拼接默认下载 URL（默认 1.2.0）
  --url <URL>            完整下载地址（覆盖 --version 默认 URL）
  --data-dir <路径>      数据目录（默认 <site-root>/backend/data）
  --yes, -y              全自动非交互（依赖安装、Nginx 写入、软件源种子等）
  --skip-deps            跳过依赖检测/自动安装
  --skip-firewall        跳过防火墙放行
  --skip-nginx-write     跳过自动写入 Nginx（仅打印片段）
  --skip-probe           跳过环境探测报告
  --seed-software-source 强制启用软件源/模板演示种子（--yes 时默认开启）
  --no-seed-software-source  禁用软件源种子
  --software-source-admin-key <密钥>  软件源管理密钥（同时写入服务环境变量）
  --uninstall            停止并移除服务单元（保留站点文件）
  --purge                卸载并删除站点内后端与本脚本写入的配置
  --fresh                强制全新安装：清除 install.lock / db.json 等安装标记，
                         并清空数据目录内容，确保浏览器进入「系统安装向导」
                         （不会删 Nginx/站点静态文件；MySQL 库请在宝塔自行重建）
  --help, -h             显示帮助

环境变量:
  PORT                     后端端口（同 --port）
  AUTO_PRO_DATA_DIR        数据目录（同 --data-dir）
  SOFTWARE_SOURCE_ADMIN_KEY  软件源管理密钥

示例（宝塔 SSH 一键）:
  sudo bash install.sh --site-root /www/wwwroot/你的站点 \
    --package /root/auth_pro-full-v1.2.0.tar.gz --yes

  sudo bash install.sh --site-root /www/wwwroot/你的站点 --version 1.2.0 --yes

默认包地址:
  https://github.com/zxcvbnm25/auth-pro-baota-deploy/releases/download/vX.Y.Z/auth_pro-full-vX.Y.Z.tar.gz
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
        PACKAGE_VERSION="${2:-}"; shift 2 ;;
      --url)
        PACKAGE_URL="${2:-}"; shift 2 ;;
      --data-dir)
        DATA_DIR="${2:-}"; shift 2 ;;
      --yes|-y)
        ASSUME_YES=1; DEPS_YES=1; shift ;;
      --skip-deps)
        SKIP_DEPS=1; shift ;;
      --skip-firewall)
        SKIP_FIREWALL=1; shift ;;
      --skip-nginx-write)
        SKIP_NGINX_WRITE=1; shift ;;
      --skip-probe)
        SKIP_PROBE=1; shift ;;
      --seed-software-source)
        SEED_SOFTWARE_SOURCE=1; shift ;;
      --no-seed-software-source)
        SEED_SOFTWARE_SOURCE=0; shift ;;
      --software-source-admin-key)
        SOFTWARE_SOURCE_ADMIN_KEY_FLAG="${2:-}"; shift 2 ;;
      --uninstall)
        DO_UNINSTALL=1; shift ;;
      --purge)
        DO_UNINSTALL=1; DO_PURGE=1; shift ;;
      --fresh)
        DO_FRESH=1; shift ;;
      --help|-h)
        usage; exit 0 ;;
      *)
        die "未知参数: $1（使用 --help 查看说明）" ;;
    esac
  done

  # --yes 默认开启软件源种子
  if [[ "${SEED_SOFTWARE_SOURCE}" -eq -1 ]]; then
    if [[ "${ASSUME_YES}" -eq 1 ]]; then
      SEED_SOFTWARE_SOURCE=1
    else
      SEED_SOFTWARE_SOURCE=1
    fi
  fi
}

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    warn "建议使用 root（sudo）运行，以便安装依赖、写 Nginx、systemd/supervisor"
  fi
}

resolve_package_url() {
  if [[ -n "${PACKAGE_URL}" ]]; then
    return 0
  fi
  local ver="${PACKAGE_VERSION:-${DEFAULT_VERSION}}"
  if [[ ! "${ver}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "软件版本无效: '${ver}'（需要 X.Y.Z）。请使用 --version 1.2.0，勿与系统 VERSION 环境变量混淆"
  fi
  PACKAGE_VERSION="${ver}"
  PACKAGE_URL="https://github.com/zxcvbnm25/auth-pro-baota-deploy/releases/download/v${ver}/auth_pro-full-v${ver}.tar.gz"
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
    warn "若 GitHub 不可达，请改用 --package /路径/auth_pro-full-v*.tar.gz"
    deps_download "${PACKAGE_URL}" "${archive}" \
      || die "下载失败，请使用 --package 指定本地包，或检查 --url / --version / 网络"
    ok "下载完成"
  fi

  log "解压到站点根目录: ${SITE_ROOT}"
  local bin_path="${SITE_ROOT}/${BINARY_REL}"
  if [[ -f "${bin_path}" ]]; then
    local bak="${bin_path}.bak.$(date +%Y%m%d%H%M%S)"
    log "升级备份: ${bin_path} → ${bak}"
    cp -a "${bin_path}" "${bak}"
  fi

  tar -xzf "${archive}" -C "${SITE_ROOT}"
  ok "解压完成"

  if [[ ! -f "${SITE_ROOT}/${BINARY_REL}" ]]; then
    local nested
    nested="$(find "${SITE_ROOT}" -maxdepth 3 -type f -name 'auth_pro' -path '*/backend/*' 2>/dev/null | head -1 || true)"
    if [[ -n "${nested}" && "${nested}" != "${SITE_ROOT}/${BINARY_REL}" ]]; then
      warn "检测到嵌套路径 ${nested}，请确认包布局是否为站点根直接含 backend/"
    fi
    die "解压后未找到 ${BINARY_REL}，请检查包内容（期望: index.html, assets/, backend/auth_pro, manifest.json）"
  fi

  chmod +x "${SITE_ROOT}/${BINARY_REL}"
  ok "已 chmod +x ${BINARY_REL}"

  # 包内不应携带安装锁；若误带则去掉，避免跳过向导
  clear_install_markers "${SITE_ROOT}" "${SITE_ROOT}/backend" "${SITE_ROOT}/backend/data"


  if [[ -f "${SITE_ROOT}/manifest.json" ]]; then
    ok "发现 manifest.json"
  else
    warn "未发现 manifest.json（非致命）"
  fi
}


# ---------- 强制走安装向导 ----------
# 一键部署不应静默留下「已安装」状态却没有用户记得的管理员密码。
clear_install_markers() {
  local roots=("$@")
  local f
  for f in \
      install.lock \
      db.json
  do
    local p
    for rootp in "${roots[@]}"; do
      [[ -n "${rootp}" ]] || continue
      p="${rootp%/}/${f}"
      if [[ -e "${p}" ]]; then
        log "清除安装标记: ${p}"
        rm -f "${p}"
      fi
    done
  done
  # 常见误放位置
  for p in \
      "${SITE_ROOT}/install.lock" \
      "${SITE_ROOT}/backend/install.lock" \
      "${SITE_ROOT}/backend/data/install.lock" \
      "${SITE_ROOT}/db.json" \
      "${SITE_ROOT}/backend/db.json" \
      "${SITE_ROOT}/backend/data/db.json"
  do
    if [[ -e "${p}" ]]; then
      log "清除安装标记: ${p}"
      rm -f "${p}"
    fi
  done
}

ensure_fresh_install() {
  if [[ -z "${DATA_DIR}" ]]; then
    DATA_DIR="${SITE_ROOT}/backend/data"
  fi
  mkdir -p "${DATA_DIR}"

  local lock="${DATA_DIR}/install.lock"
  if [[ "${DO_FRESH}" -eq 1 ]]; then
    log "已指定 --fresh：重置安装状态，强制进入系统安装向导"
    # 停服务避免占用文件
    if command -v systemctl >/dev/null 2>&1; then
      systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    fi
    if command -v supervisorctl >/dev/null 2>&1; then
      supervisorctl stop "${SERVICE_NAME}" 2>/dev/null || true
    fi
    clear_install_markers "${DATA_DIR}" "${SITE_ROOT}" "${SITE_ROOT}/backend" "${SITE_ROOT}/backend/data"
    # 清空数据目录（保留目录本身）
    if [[ -d "${DATA_DIR}" ]]; then
      log "清空数据目录内容: ${DATA_DIR}"
      find "${DATA_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    fi
    mkdir -p "${DATA_DIR}"
    ok "已重置为未安装状态（请随后在浏览器完成安装向导并牢记管理员密码）"
    warn "请在宝塔删除/重建对应 MySQL 库，避免向导连到旧库仍显示已有账号"
    return 0
  fi

  # 未指定 --fresh：若已安装，明确警告
  if [[ -f "${lock}" ]]; then
    warn "检测到已安装标记: ${lock}"
    warn "浏览器将跳过安装向导。若忘记管理员密码，请加 --fresh 重跑，例如："
    warn "  sudo bash install.sh --site-root ${SITE_ROOT} --yes --fresh"
    if [[ "${ASSUME_YES}" -eq 1 ]]; then
      warn "当前为 --yes 但未加 --fresh，保留已有安装状态（不会重置密码）"
    fi
  fi
}

# ---------- 数据目录 ----------
prepare_data_dir() {
  if [[ -z "${DATA_DIR}" ]]; then
    DATA_DIR="${SITE_ROOT}/backend/data"
  fi
  mkdir -p "${DATA_DIR}"
  ok "数据目录: ${DATA_DIR}"
  export AUTO_PRO_DATA_DIR="${DATA_DIR}"
  export PORT="${PORT}"
  if [[ -n "${SOFTWARE_SOURCE_ADMIN_KEY_FLAG}" ]]; then
    export SOFTWARE_SOURCE_ADMIN_KEY="${SOFTWARE_SOURCE_ADMIN_KEY_FLAG}"
  fi
}

env_file_line() {
  # 生成 Environment= 行（密钥仅写入服务单元，不进仓库）
  if [[ -n "${SOFTWARE_SOURCE_ADMIN_KEY_FLAG}" ]]; then
    echo "Environment=SOFTWARE_SOURCE_ADMIN_KEY=${SOFTWARE_SOURCE_ADMIN_KEY_FLAG}"
  else
    echo "# Environment=SOFTWARE_SOURCE_ADMIN_KEY=请替换为你的密钥"
  fi
}

# ---------- systemd ----------
install_systemd_unit() {
  local unit="/etc/systemd/system/${SERVICE_NAME}.service"
  local bin="${SITE_ROOT}/${BINARY_REL}"
  local key_line
  key_line="$(env_file_line)"
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
${key_line}

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
  local env_line="PORT=\"${PORT}\",AUTO_PRO_DATA_DIR=\"${DATA_DIR}\""
  if [[ -n "${SOFTWARE_SOURCE_ADMIN_KEY_FLAG}" ]]; then
    env_line="${env_line},SOFTWARE_SOURCE_ADMIN_KEY=\"${SOFTWARE_SOURCE_ADMIN_KEY_FLAG}\""
  fi
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
environment=${env_line}
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
      deps_detect_process_mgr || true
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
    log "清理站点内后端相关文件..."
    if [[ -f "${SITE_ROOT}/${BINARY_REL}" ]]; then
      rm -f "${SITE_ROOT}/${BINARY_REL}"
      rm -f "${SITE_ROOT}/${BINARY_REL}".bak.* 2>/dev/null || true
      ok "已删除 ${BINARY_REL} 及备份"
    fi
    # 移除 nginx 标记块 / extension（尽力而为，不删整个站点 conf）
    local site_name vhost ext
    site_name="$(basename "${SITE_ROOT}")"
    ext="/www/server/panel/vhost/nginx/extension/${site_name}/auth_pro.conf"
    if [[ -f "${ext}" ]]; then
      rm -f "${ext}"
      ok "已删除 nginx extension: ${ext}"
    fi
    if vhost="$(ngx_find_vhost_for_site "${SITE_ROOT}" 2>/dev/null || true)"; then
      if [[ -n "${vhost}" && -f "${vhost}" ]] && grep -q "#AUTH_PRO_BEGIN" "${vhost}" 2>/dev/null; then
        local tmp
        tmp="$(mktemp)"
        awk '/#AUTH_PRO_BEGIN/{skip=1;next} /#AUTH_PRO_END/{skip=0;next} !skip{print}' "${vhost}" > "${tmp}"
        cat "${tmp}" > "${vhost}"
        rm -f "${tmp}"
        ok "已从 vhost 移除 AUTH_PRO 标记块"
        ngx_test_and_reload || true
      fi
    fi
    local default_data="${SITE_ROOT}/backend/data"
    if [[ -z "${DATA_DIR}" ]]; then
      DATA_DIR="${default_data}"
    fi
    if [[ -d "${DATA_DIR}" ]] && [[ "${DATA_DIR}" == "${default_data}" || "${DATA_DIR}" == "${SITE_ROOT}/data" ]]; then
      if [[ "${ASSUME_YES}" -eq 1 ]]; then
        rm -rf "${DATA_DIR}"
        ok "已删除数据目录 ${DATA_DIR}"
      else
        warn "数据目录 ${DATA_DIR} 未删除（使用 --yes --purge 可删除默认 data）"
      fi
    fi
  fi
  ok "卸载完成"
}

# ---------- 收尾清单 ----------
print_checklist() {
  local site_name domain hint_url
  site_name="$(basename "${SITE_ROOT}")"
  domain="${site_name}"
  hint_url="https://${domain}"

  cat <<SUM

======== 部署完成 · 后续清单 ========
站点根目录:     ${SITE_ROOT}
站点名:         ${site_name}
后端二进制:     ${SITE_ROOT}/${BINARY_REL}
监听端口:       ${PORT}（建议仅本机，经 Nginx 反代）
数据目录:       ${DATA_DIR}
进程管理:       ${DEPS_PROCESS_MGR:-未知}
Nginx 写入:     ${NGX_LAST_MODE:-未写/跳过} ${NGX_LAST_TARGET:+→ ${NGX_LAST_TARGET}}

【请逐项确认】
  □ 1. 浏览器访问站点: ${hint_url}/  （或 http://${domain}/ ）
  □ 2. 在宝塔「数据库」创建 MySQL 库与用户，并在安装向导中填写连接
  □ 3. 打开站点应进入「系统安装向导」，创建管理员并牢记密码
         （若直接进登录页，用 --fresh 重装：sudo bash install.sh --site-root … --yes --fresh）
  □ 4. 软件源索引 URL:
         ${hint_url}/api/software-source/index.json
  □ 5. 健康检查: curl -sS ${hint_url}/healthz  或  http://127.0.0.1:${PORT}/healthz
  □ 6. 如需管理密钥，确认服务环境已含 SOFTWARE_SOURCE_ADMIN_KEY 后重启:
         systemctl restart ${SERVICE_NAME}
         # 或: supervisorctl restart ${SERVICE_NAME}

安全建议:
  - 不要把 SOFTWARE_SOURCE_ADMIN_KEY 写进可被 Web 访问的目录
  - 对外只开 80/443；勿直接暴露 ${PORT}
  - 站点目录避免 777；优先宝塔申请 HTTPS
  - 本脚本不会删除无关宝塔插件/数据库/其他站点
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

  # A. 环境探测
  if [[ "${SKIP_PROBE}" -eq 0 ]]; then
    probe_run_report || die "架构不支持，中止"
  else
    warn "已跳过环境探测 (--skip-probe)"
    deps_check_arch || die "架构不支持"
  fi

  # B. 依赖
  if [[ "${SKIP_DEPS}" -eq 1 ]]; then
    warn "已跳过依赖检测 (--skip-deps)"
    deps_detect_process_mgr || true
    deps_detect_nginx || true
  else
    local dep_args=(--port "${PORT}")
    [[ "${ASSUME_YES}" -eq 1 ]] && dep_args+=(--yes)
    [[ "${SKIP_FIREWALL}" -eq 1 ]] && dep_args+=(--skip-firewall)
    deps_run_all "${dep_args[@]}" || die "依赖检测/安装失败"
  fi

  # C. 宝塔组件
  local bt_args=()
  [[ "${ASSUME_YES}" -eq 1 ]] && bt_args+=(--yes)
  bt_ensure_stack "${bt_args[@]+"${bt_args[@]}"}"

  # E. 包 + 进程
  download_or_use_package
  # 先定数据目录并处理 --fresh / 已安装警告（必须在起服务前）
  if [[ -z "${DATA_DIR}" ]]; then
    DATA_DIR="${SITE_ROOT}/backend/data"
  fi
  ensure_fresh_install
  prepare_data_dir
  install_process_service

  # D. Nginx 自动写入
  if [[ "${SKIP_NGINX_WRITE}" -eq 1 ]]; then
    warn "已跳过 Nginx 自动写入 (--skip-nginx-write)"
    local snippet="${SCRIPT_DIR}/examples/nginx.conf.snippet"
    if [[ -f "${snippet}" ]]; then
      log "参考片段:"
      sed "s/__PORT__/${PORT}/g; s|__SITE_ROOT__|${SITE_ROOT}|g" "${snippet}"
    fi
  else
    ngx_auto_configure "${SITE_ROOT}" "${PORT}"
  fi

  # F. 软件源种子
  local seed_args=()
  if [[ "${SEED_SOFTWARE_SOURCE}" -eq 1 ]]; then
    seed_args+=(--seed)
  else
    seed_args+=(--no-seed)
  fi
  [[ "${ASSUME_YES}" -eq 1 ]] && seed_args+=(--yes)
  if [[ -n "${SOFTWARE_SOURCE_ADMIN_KEY_FLAG}" ]]; then
    seed_args+=(--admin-key "${SOFTWARE_SOURCE_ADMIN_KEY_FLAG}")
  fi
  seed_run "${SCRIPT_DIR}" "${SITE_ROOT}" "${DATA_DIR}" "${PORT}" "${seed_args[@]}"

  # G. 清单
  print_checklist
}

main "$@"
