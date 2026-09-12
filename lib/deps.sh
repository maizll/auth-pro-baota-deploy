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

# ---------- 日志 ----------
deps_log()  { printf '[deps] %s\n' "$*"; }
deps_ok()   { printf '[deps] ✓ %s\n' "$*"; }
deps_warn() { printf '[deps] ⚠ %s\n' "$*" >&2; }
deps_err()  { printf '[deps] ✗ %s\n' "$*" >&2; }

# ---------- 架构 ----------
deps_check_arch() {
  local arch
  arch="$(uname -m 2>/dev/null || echo unknown)"
  deps_log "检测 CPU 架构 → ${arch}"
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
  deps_log "检测宝塔面板路径..."
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
  if [[ "${found}" -eq 1 ]]; then
    deps_log "提示: 建议将 --site-root 设为 /www/wwwroot/<你的站点目录>"
    deps_log "提示: 数据库请在宝塔面板「数据库」中创建，本脚本不会自动安装 MySQL/MariaDB"
  fi
  return 0
}

# ---------- 包管理器 ----------
deps_detect_pkg_mgr() {
  deps_log "检测包管理器..."
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
  deps_log "准备安装缺失依赖 → ${joined}"
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
}

# 按发行版映射包名
deps_pkg_name() {
  local logical="$1"
  case "${logical}" in
    curl)
      echo "curl"
      ;;
    wget)
      echo "wget"
      ;;
    tar)
      echo "tar"
      ;;
    ca-certificates)
      case "${DEPS_PKG_MGR}" in
        apk) echo "ca-certificates" ;;
        *)   echo "ca-certificates" ;;
      esac
      ;;
    supervisor)
      case "${DEPS_PKG_MGR}" in
        apk) echo "supervisor" ;;
        *)   echo "supervisor" ;;
      esac
      ;;
    *)
      echo "${logical}"
      ;;
  esac
}

# ---------- 基础工具 ----------
deps_ensure_download_tool() {
  deps_log "检测下载工具 (curl / wget)..."
  if command -v curl >/dev/null 2>&1; then
    deps_ok "已有 curl"
    return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    deps_ok "已有 wget"
    return 0
  fi
  deps_log "缺失 → curl 与 wget 均未找到，尝试安装 curl"
  local pkg
  pkg="$(deps_pkg_name curl)"
  deps_install_pkgs "${pkg}" || return 1
  if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
    deps_ok "下载工具安装成功"
    return 0
  fi
  deps_err "安装后仍无 curl/wget，请手动安装"
  return 1
}

deps_ensure_tar() {
  deps_log "检测 tar..."
  if command -v tar >/dev/null 2>&1; then
    deps_ok "已有 tar"
    return 0
  fi
  deps_log "缺失 → tar，尝试安装"
  deps_install_pkgs "$(deps_pkg_name tar)" || return 1
  if command -v tar >/dev/null 2>&1; then
    deps_ok "tar 安装成功"
    return 0
  fi
  deps_err "安装后仍无 tar"
  return 1
}

deps_ensure_ca_certificates() {
  deps_log "检测 ca-certificates..."
  # 粗略检测：常见证书目录或包是否可用
  if [[ -d /etc/ssl/certs ]] || [[ -f /etc/ssl/certs/ca-certificates.crt ]] \
    || [[ -f /etc/pki/tls/certs/ca-bundle.crt ]] \
    || [[ -f /etc/ssl/cert.pem ]]; then
    # 仍尝试确保包存在（部分精简系统目录在但过期）
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
  deps_log "缺失或不确定 → ca-certificates，尝试安装"
  deps_install_pkgs "$(deps_pkg_name ca-certificates)" || {
    deps_warn "ca-certificates 安装失败，HTTPS 下载可能失败"
    return 0  # 非致命，继续尝试
  }
  deps_ok "ca-certificates 已处理"
  return 0
}

# ---------- 进程管理 ----------
deps_detect_process_mgr() {
  deps_log "检测进程管理器..."
  DEPS_HAS_SYSTEMD=0
  DEPS_HAS_SUPERVISOR=0
  DEPS_PROCESS_MGR="none"

  if command -v systemctl >/dev/null 2>&1; then
    # 确认 systemd 真正在跑（容器里可能有 systemctl 但未启用）
    if systemctl is-system-running >/dev/null 2>&1 \
      || systemctl list-units >/dev/null 2>&1; then
      DEPS_HAS_SYSTEMD=1
      DEPS_PROCESS_MGR="systemd"
      deps_ok "优先使用 systemd (systemctl 可用)"
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
  if [[ "${DEPS_PROCESS_MGR}" == "systemd" ]]; then
    return 0
  fi
  if [[ "${DEPS_PROCESS_MGR}" == "supervisor" ]]; then
    return 0
  fi
  # 无 systemd → 尝试安装 supervisor
  deps_log "缺失 → systemd 不可用，尝试安装/配置 supervisor"
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
    # 尝试启动 supervisord
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

# ---------- Nginx（仅检测，不强制安装）----------
deps_detect_nginx() {
  deps_log "检测 Nginx / OpenResty（宝塔通常已自带，不强制安装）..."
  DEPS_HAS_NGINX=0
  if command -v nginx >/dev/null 2>&1 \
    || command -v openresty >/dev/null 2>&1 \
    || [[ -x /www/server/nginx/sbin/nginx ]] \
    || [[ -d /www/server/nginx ]]; then
    DEPS_HAS_NGINX=1
    deps_ok "检测到 Nginx/OpenResty（或宝塔 Nginx 目录）"
  else
    deps_warn "未检测到 Nginx/OpenResty。宝塔环境请在面板「软件商店」安装 Nginx"
    deps_warn "本脚本不会自动安装 Nginx，以免与宝塔冲突"
  fi
  return 0
}

# ---------- MySQL 客户端（可选检查）----------
deps_check_mysql_client() {
  deps_log "检测 mysql 客户端（可选，不自动安装数据库）..."
  if command -v mysql >/dev/null 2>&1; then
    deps_ok "已有 mysql 客户端，可用于手动导入/测试"
  else
    deps_warn "未找到 mysql 客户端。数据库请在宝塔面板中创建；如需命令行可自行安装 mysql 客户端"
  fi
  deps_log "重要: 本脚本不会自动安装 MySQL/MariaDB，请使用宝塔面板管理数据库"
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
deps_run_all() {
  # 用法: deps_run_all [--yes]
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y) DEPS_YES=1; shift ;;
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
  deps_check_mysql_client
  deps_log "======== 依赖检测完成 (进程管理: ${DEPS_PROCESS_MGR}) ========"
  return 0
}

# 导出给 install.sh 使用的变量在调用 deps_run_all 后可用:
#   DEPS_PKG_MGR, DEPS_HAS_SYSTEMD, DEPS_HAS_SUPERVISOR,
#   DEPS_HAS_NGINX, DEPS_PROCESS_MGR
