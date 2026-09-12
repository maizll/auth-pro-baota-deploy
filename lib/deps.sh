#!/usr/bin/env bash
# lib/deps.sh — 依赖检测与自动安装（宝塔一键部署）
# 由 install.sh source；勿单独执行。

# shellcheck disable=SC2034

DEPS_YES="${DEPS_YES:-0}"
DEPS_PKG_MGR=""
DEPS_HAS_SYSTEMD=0
DEPS_HAS_SUPERVISOR=0
DEPS_HAS_NGINX=0
DEPS_PROCESS_MGR=""   # systemd | supervisor | none
DEPS_FIREWALL=""      # firewalld | ufw | iptables | none
DEPS_SKIP_FIREWALL=0

# ---------- 日志 ----------
deps_log()  { printf '[deps] %s\n' "$*"; }
deps_ok()   { printf '[deps] ✓ %s\n' "$*"; }
deps_warn() { printf '[deps] ⚠ %s\n' "$*" >&2; }
deps_err()  { printf '[deps] ✗ %s\n' "$*" >&2; }
deps_step() { printf '[deps] 检测 → %s\n' "$*"; }
deps_miss() { printf '[deps] 缺失 → %s\n' "$*"; }
deps_do()   { printf '[deps] 安装/写入 → %s\n' "$*"; }

# ---------- 架构 ----------
deps_check_arch() {
  local arch
  arch="$(uname -m 2>/dev/null || echo unknown)"
  deps_step "CPU 架构 → ${arch}"
  case "${arch}" in
    x86_64|amd64)
      deps_ok "架构为 Linux amd64，符合要求"
      return 0
      ;;
    *)
      deps_err "当前架构为 ${arch}，本部署包仅支持 Linux amd64（x86_64）"
      deps_err "请在 amd64 服务器上运行，或联系维护者获取对应架构包"
      return 1
      ;;
  esac
}

# ---------- 宝塔路径 ----------
deps_detect_baota() {
  deps_step "宝塔面板路径..."
  local found=0
  if [[ -d /www/wwwroot ]]; then
    deps_ok "发现站点根目录: /www/wwwroot"
    found=1
  else
    deps_warn "未发现 /www/wwwroot（可能未安装宝塔，或路径自定义）"
  fi
  if [[ -d /www/server/panel ]]; then
    deps_ok "发现宝塔面板: /www/server/panel"
    found=1
  else
    deps_warn "未发现 /www/server/panel"
  fi
  if command -v bt >/dev/null 2>&1; then
    deps_ok "bt CLI: $(command -v bt)"
  fi
  if [[ "${found}" -eq 1 ]]; then
    deps_log "提示: 建议将 --site-root 设为 /www/wwwroot/<你的站点目录>"
    deps_log "提示: 数据库请在宝塔面板「数据库」中创建；本脚本不会安装第二套 MySQL 服务端"
  fi
  return 0
}

# ---------- 包管理器 ----------
deps_detect_pkg_mgr() {
  deps_step "包管理器..."
  if command -v apt-get >/dev/null 2>&1; then
    DEPS_PKG_MGR="apt-get"
  elif command -v dnf >/dev/null 2>&1; then
    DEPS_PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    DEPS_PKG_MGR="yum"
  elif command -v apk >/dev/null 2>&1; then
    DEPS_PKG_MGR="apk"
  else
    DEPS_PKG_MGR=""
    deps_warn "未检测到 apt-get / yum / dnf / apk，自动安装将不可用"
    return 1
  fi
  deps_ok "包管理器: ${DEPS_PKG_MGR}"
  return 0
}

deps_confirm_install() {
  local pkgs="$1"
  if [[ "${DEPS_YES}" == "1" ]]; then
    deps_log "已指定 --yes，自动确认安装: ${pkgs}"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    deps_err "缺少依赖 [${pkgs}]，且非交互终端。请添加 --yes 以自动安装，或手动安装后重试"
    return 1
  fi
  printf '[deps] 缺少依赖: %s\n' "${pkgs}"
  printf '[deps] 是否自动安装？[y/N] '
  local ans
  read -r ans || true
  case "${ans}" in
    y|Y|yes|YES) return 0 ;;
    *)
      deps_err "用户取消安装。请手动安装后重试，或使用 --yes"
      return 1
      ;;
  esac
}

deps_install_pkgs() {
  local pkgs=("$@")
  local joined
  joined="${pkgs[*]}"
  deps_miss "${joined}"
  deps_do "${joined}"
  deps_confirm_install "${joined}" || return 1

  if [[ -z "${DEPS_PKG_MGR}" ]]; then
    deps_detect_pkg_mgr || {
      deps_err "无法自动安装，请手动安装: ${joined}"
      return 1
    }
  fi

  case "${DEPS_PKG_MGR}" in
    apt-get)
      deps_log "执行: apt-get update && apt-get install -y ${joined}"
      apt-get update -y || true
      # shellcheck disable=SC2086
      DEBIAN_FRONTEND=noninteractive apt-get install -y ${joined}
      ;;
    dnf)
      deps_log "执行: dnf install -y ${joined}"
      # shellcheck disable=SC2086
      dnf install -y ${joined}
      ;;
    yum)
      deps_log "执行: yum install -y ${joined}"
      # shellcheck disable=SC2086
      yum install -y ${joined}
      ;;
    apk)
      deps_log "执行: apk add --no-cache ${joined}"
      # shellcheck disable=SC2086
      apk add --no-cache ${joined}
      ;;
    *)
      deps_err "未知包管理器: ${DEPS_PKG_MGR}"
      return 1
      ;;
  esac
  deps_ok "安装完成: ${joined}"
}

deps_pkg_name() {
  local logical="$1"
  case "${logical}" in
    curl|wget|tar|ca-certificates|supervisor)
      echo "${logical}"
      ;;
    mysql-client)
      case "${DEPS_PKG_MGR}" in
        apt-get) echo "default-mysql-client" ;;
        dnf|yum) echo "mysql" ;;
        apk) echo "mysql-client" ;;
        *) echo "mysql" ;;
      esac
      ;;
    *)
      echo "${logical}"
      ;;
  esac
}

# ---------- 基础工具 ----------
deps_ensure_download_tool() {
  deps_step "下载工具 (curl / wget)..."
  if command -v curl >/dev/null 2>&1; then
    deps_ok "已有 curl"
    return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    deps_ok "已有 wget"
    return 0
  fi
  deps_miss "curl 与 wget"
  deps_install_pkgs "$(deps_pkg_name curl)" || return 1
  if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
    deps_ok "下载工具安装成功"
    return 0
  fi
  deps_err "安装后仍无 curl/wget，请手动安装"
  return 1
}

deps_ensure_tar() {
  deps_step "tar..."
  if command -v tar >/dev/null 2>&1; then
    deps_ok "已有 tar"
    return 0
  fi
  deps_miss "tar"
  deps_install_pkgs "$(deps_pkg_name tar)" || return 1
  if command -v tar >/dev/null 2>&1; then
    deps_ok "tar 安装成功"
    return 0
  fi
  deps_err "安装后仍无 tar"
  return 1
}

deps_ensure_ca_certificates() {
  deps_step "ca-certificates..."
  if [[ -d /etc/ssl/certs ]] || [[ -f /etc/ssl/certs/ca-certificates.crt ]] \
    || [[ -f /etc/pki/tls/certs/ca-bundle.crt ]] \
    || [[ -f /etc/ssl/cert.pem ]]; then
    if command -v dpkg >/dev/null 2>&1; then
      if dpkg -l ca-certificates 2>/dev/null | grep -q '^ii'; then
        deps_ok "已有 ca-certificates"
        return 0
      fi
    elif command -v rpm >/dev/null 2>&1; then
      if rpm -q ca-certificates >/dev/null 2>&1; then
        deps_ok "已有 ca-certificates"
        return 0
      fi
    else
      deps_ok "检测到系统 CA 证书目录"
      return 0
    fi
  fi
  deps_miss "ca-certificates"
  deps_install_pkgs "$(deps_pkg_name ca-certificates)" || {
    deps_warn "ca-certificates 安装失败，HTTPS 下载可能失败"
    return 0
  }
  deps_ok "ca-certificates 已处理"
  return 0
}

# ---------- 进程管理 ----------
deps_detect_process_mgr() {
  deps_step "进程管理器..."
  DEPS_HAS_SYSTEMD=0
  DEPS_HAS_SUPERVISOR=0
  DEPS_PROCESS_MGR="none"

  if command -v systemctl >/dev/null 2>&1; then
    if [[ -d /run/systemd/system ]] \
      || systemctl is-system-running >/dev/null 2>&1 \
      || systemctl list-units >/dev/null 2>&1; then
      DEPS_HAS_SYSTEMD=1
      DEPS_PROCESS_MGR="systemd"
      deps_ok "优先使用 systemd"
    else
      deps_warn "发现 systemctl 但 systemd 似乎未作为 init 运行"
    fi
  else
    deps_log "未发现 systemctl"
  fi

  if command -v supervisord >/dev/null 2>&1 || command -v supervisorctl >/dev/null 2>&1; then
    DEPS_HAS_SUPERVISOR=1
    deps_ok "已安装 supervisor"
    if [[ "${DEPS_PROCESS_MGR}" == "none" ]]; then
      DEPS_PROCESS_MGR="supervisor"
    fi
  fi

  if [[ "${DEPS_PROCESS_MGR}" == "none" ]]; then
    deps_warn "当前无可用进程管理器"
  fi
  return 0
}

deps_ensure_process_mgr() {
  deps_detect_process_mgr
  if [[ "${DEPS_PROCESS_MGR}" == "systemd" || "${DEPS_PROCESS_MGR}" == "supervisor" ]]; then
    return 0
  fi
  deps_miss "systemd 不可用 → 尝试 supervisor"
  if [[ -z "${DEPS_PKG_MGR}" ]]; then
    deps_detect_pkg_mgr || true
  fi
  if [[ -z "${DEPS_PKG_MGR}" ]]; then
    deps_err "无法安装 supervisor（无包管理器）。请手动安装 systemd 或 supervisor"
    return 1
  fi
  deps_install_pkgs "$(deps_pkg_name supervisor)" || return 1
  deps_detect_process_mgr
  if [[ "${DEPS_PROCESS_MGR}" != "none" ]]; then
    deps_ok "进程管理器就绪: ${DEPS_PROCESS_MGR}"
    if [[ "${DEPS_PROCESS_MGR}" == "supervisor" ]]; then
      if command -v systemctl >/dev/null 2>&1; then
        systemctl enable supervisord 2>/dev/null || systemctl enable supervisor 2>/dev/null || true
        systemctl start supervisord 2>/dev/null || systemctl start supervisor 2>/dev/null || true
      fi
      if ! pgrep -x supervisord >/dev/null 2>&1; then
        supervisord -c /etc/supervisord.conf 2>/dev/null \
          || supervisord -c /etc/supervisor/supervisord.conf 2>/dev/null \
          || true
      fi
    fi
    return 0
  fi
  deps_err "安装 supervisor 后仍不可用"
  return 1
}

# ---------- Nginx（仅检测）----------
deps_detect_nginx() {
  deps_step "Nginx / OpenResty..."
  DEPS_HAS_NGINX=0
  if command -v nginx >/dev/null 2>&1 \
    || command -v openresty >/dev/null 2>&1 \
    || [[ -x /www/server/nginx/sbin/nginx ]] \
    || [[ -d /www/server/nginx ]]; then
    DEPS_HAS_NGINX=1
    deps_ok "检测到 Nginx/OpenResty（或宝塔 Nginx 目录）"
  else
    deps_warn "未检测到 Nginx/OpenResty（将由宝塔模块尝试友好安装）"
  fi
  return 0
}

# ---------- MySQL 客户端（可选安装；永不装第二套服务端）----------
deps_ensure_mysql_client() {
  deps_step "mysql 客户端（可选，不安装 MySQL 服务端）..."
  if command -v mysql >/dev/null 2>&1; then
    deps_ok "已有 mysql 客户端"
    return 0
  fi
  # 若宝塔已有 mysql 二进制
  if [[ -x /www/server/mysql/bin/mysql ]]; then
    deps_ok "发现宝塔 mysql 客户端: /www/server/mysql/bin/mysql"
    return 0
  fi
  if [[ "${DEPS_YES}" != "1" ]]; then
    deps_warn "未找到 mysql 客户端（使用 --yes 可尝试仅安装客户端包）"
    return 0
  fi
  if [[ -z "${DEPS_PKG_MGR}" ]]; then
    deps_detect_pkg_mgr || true
  fi
  if [[ -z "${DEPS_PKG_MGR}" ]]; then
    deps_warn "无包管理器，跳过 mysql 客户端"
    return 0
  fi
  deps_miss "mysql 客户端"
  deps_install_pkgs "$(deps_pkg_name mysql-client)" || {
    deps_warn "mysql 客户端安装失败（非致命）"
    return 0
  }
  if command -v mysql >/dev/null 2>&1; then
    deps_ok "mysql 客户端安装成功"
  else
    deps_warn "客户端包已装但 PATH 中仍无 mysql（非致命）"
  fi
  return 0
}

# ---------- 防火墙：放行本机后端端口 ----------
deps_detect_firewall() {
  DEPS_FIREWALL="none"
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    DEPS_FIREWALL="firewalld"
  elif command -v ufw >/dev/null 2>&1; then
    DEPS_FIREWALL="ufw"
  elif command -v iptables >/dev/null 2>&1; then
    DEPS_FIREWALL="iptables"
  fi
}

deps_open_backend_port() {
  local port="${1:-}"
  if [[ "${DEPS_SKIP_FIREWALL}" == "1" ]]; then
    deps_log "已跳过防火墙 (--skip-firewall)"
    return 0
  fi
  if [[ -z "${port}" ]]; then
    return 0
  fi
  deps_step "防火墙放行后端端口 ${port}/tcp（本机反代通常仍建议仅监听 127.0.0.1）..."
  deps_detect_firewall
  case "${DEPS_FIREWALL}" in
    firewalld)
      deps_do "firewall-cmd --add-port=${port}/tcp"
      if firewall-cmd --permanent --add-port="${port}/tcp" 2>/dev/null \
        && firewall-cmd --reload 2>/dev/null; then
        deps_ok "firewalld 已放行 ${port}/tcp"
      else
        deps_warn "firewalld 放行失败 — 请手动: firewall-cmd --permanent --add-port=${port}/tcp && firewall-cmd --reload"
      fi
      ;;
    ufw)
      deps_do "ufw allow ${port}/tcp"
      if ufw status 2>/dev/null | grep -qi 'inactive'; then
        deps_warn "ufw 未启用，跳过写入规则（避免意外启用防火墙）"
        deps_warn "如需放行请手动: ufw allow ${port}/tcp"
      elif ufw allow "${port}/tcp" 2>/dev/null; then
        deps_ok "ufw 已放行 ${port}/tcp"
      else
        deps_warn "ufw 放行失败 — 请手动: ufw allow ${port}/tcp"
      fi
      ;;
    iptables)
      deps_warn "检测到 iptables：为免破坏宝塔规则，不自动改写。请手动放行 ${port}/tcp 或依赖 Nginx 本机反代"
      ;;
    *)
      deps_warn "未检测到可用防火墙工具，跳过端口放行"
      ;;
  esac
  return 0
}

# ---------- 下载封装 ----------
deps_download() {
  local url="$1"
  local dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --connect-timeout 30 -o "${dest}" "${url}"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --tries=3 --timeout=30 -O "${dest}" "${url}"
  else
    deps_err "无 curl/wget，无法下载"
    return 1
  fi
}

# ---------- 总入口 ----------
# deps_run_all [--yes] [--port N] [--skip-firewall]
deps_run_all() {
  local port=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y) DEPS_YES=1; shift ;;
      --port) port="${2:-}"; shift 2 ;;
      --skip-firewall) DEPS_SKIP_FIREWALL=1; shift ;;
      *) shift ;;
    esac
  done

  deps_log "======== 开始环境依赖检测 ========"
  deps_check_arch || return 1
  deps_detect_baota
  deps_detect_pkg_mgr || true
  deps_ensure_download_tool || return 1
  deps_ensure_tar || return 1
  deps_ensure_ca_certificates || true
  deps_ensure_process_mgr || return 1
  deps_detect_nginx
  deps_ensure_mysql_client || true
  if [[ -n "${port}" ]]; then
    deps_open_backend_port "${port}" || true
  fi
  deps_log "======== 依赖检测完成 (进程管理: ${DEPS_PROCESS_MGR}) ========"
  return 0
}
