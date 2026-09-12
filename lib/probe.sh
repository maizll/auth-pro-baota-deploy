#!/usr/bin/env bash
# lib/probe.sh — 环境探测，输出清晰中文报告
# 由 install.sh source；勿单独执行。

# shellcheck disable=SC2034

PROBE_OS=""
PROBE_ARCH=""
PROBE_BT_PRESENT=0
PROBE_BT_VERSION=""
PROBE_BT_CLI=0
PROBE_NGINX_PATH=""
PROBE_NGINX_VERSION=""
PROBE_MYSQL_LISTENING=0
PROBE_MYSQL_PORT=""
PROBE_PROCESS_MGR=""
PROBE_FIREWALL=""
PROBE_WWWROOT_SITES=""

probe_log()  { printf '[探测] %s\n' "$*"; }
probe_ok()   { printf '[探测] ✓ %s\n' "$*"; }
probe_warn() { printf '[探测] ⚠ %s\n' "$*" >&2; }
probe_miss() { printf '[探测] ✗ 缺失 → %s\n' "$*"; }

probe_os_arch() {
  PROBE_OS="$(uname -s 2>/dev/null || echo unknown)"
  local pretty=""
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    pretty="${PRETTY_NAME:-${NAME:-}}"
  fi
  PROBE_ARCH="$(uname -m 2>/dev/null || echo unknown)"
  probe_log "操作系统: ${pretty:-${PROBE_OS}} ($(uname -r 2>/dev/null || echo '?'))"
  case "${PROBE_ARCH}" in
    x86_64|amd64)
      probe_ok "CPU 架构: ${PROBE_ARCH}（仅支持 amd64）"
      ;;
    *)
      probe_miss "CPU 架构 ${PROBE_ARCH} — 本包仅支持 Linux amd64"
      return 1
      ;;
  esac
  return 0
}

probe_baota() {
  PROBE_BT_PRESENT=0
  PROBE_BT_VERSION=""
  PROBE_BT_CLI=0
  probe_log "检测宝塔面板..."
  if [[ -d /www/server/panel ]]; then
    PROBE_BT_PRESENT=1
    probe_ok "面板目录存在: /www/server/panel"
    local ver_file
    for ver_file in /www/server/panel/data/version.pl /www/server/panel/version.pl /www/server/panel/class/common.py; do
      if [[ -f /www/server/panel/data/version.pl ]]; then
        PROBE_BT_VERSION="$(tr -d '\r\n' < /www/server/panel/data/version.pl 2>/dev/null || true)"
        break
      fi
    done
    if [[ -z "${PROBE_BT_VERSION}" && -f /www/server/panel/config/config.json ]]; then
      PROBE_BT_VERSION="$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' /www/server/panel/config/config.json 2>/dev/null | head -1 | sed 's/.*"\([^"]*\)"$/\1/' || true)"
    fi
    if [[ -n "${PROBE_BT_VERSION}" ]]; then
      probe_ok "面板版本: ${PROBE_BT_VERSION}"
    else
      probe_warn "面板已安装，但未能解析版本号"
    fi
  else
    probe_miss "宝塔面板目录 /www/server/panel"
  fi
  if command -v bt >/dev/null 2>&1; then
    PROBE_BT_CLI=1
    probe_ok "bt CLI 可用: $(command -v bt)"
  else
    probe_warn "bt CLI 不在 PATH（部分操作将降级为手动说明）"
  fi
  return 0
}

probe_nginx() {
  PROBE_NGINX_PATH=""
  PROBE_NGINX_VERSION=""
  probe_log "检测 Nginx / OpenResty..."
  local cand
  for cand in \
    /www/server/nginx/sbin/nginx \
    "$(command -v nginx 2>/dev/null || true)" \
    "$(command -v openresty 2>/dev/null || true)" \
    /usr/local/openresty/nginx/sbin/nginx \
    /usr/sbin/nginx; do
    if [[ -n "${cand}" && -x "${cand}" ]]; then
      PROBE_NGINX_PATH="${cand}"
      break
    fi
  done
  if [[ -z "${PROBE_NGINX_PATH}" && -d /www/server/nginx ]]; then
    PROBE_NGINX_PATH="/www/server/nginx"
    probe_ok "发现宝塔 Nginx 目录: /www/server/nginx（sbin 可能尚未就绪）"
  fi
  if [[ -n "${PROBE_NGINX_PATH}" && -x "${PROBE_NGINX_PATH}" ]]; then
    PROBE_NGINX_VERSION="$("${PROBE_NGINX_PATH}" -v 2>&1 | head -1 || true)"
    probe_ok "Nginx 路径: ${PROBE_NGINX_PATH}"
    probe_ok "Nginx 版本: ${PROBE_NGINX_VERSION:-未知}"
  elif [[ -n "${PROBE_NGINX_PATH}" ]]; then
    probe_ok "Nginx 相关路径: ${PROBE_NGINX_PATH}"
  else
    probe_miss "Nginx/OpenResty（需在宝塔软件商店安装，或由本脚本尝试宝塔安装路径）"
  fi
  return 0
}

probe_mysql() {
  PROBE_MYSQL_LISTENING=0
  PROBE_MYSQL_PORT=""
  probe_log "检测 MySQL/MariaDB 监听..."
  local port
  for port in 3306 3307 33060; do
    if (echo >/dev/tcp/127.0.0.1/"${port}") >/dev/null 2>&1; then
      PROBE_MYSQL_LISTENING=1
      PROBE_MYSQL_PORT="${port}"
      break
    fi
  done
  if [[ "${PROBE_MYSQL_LISTENING}" -eq 0 ]] && command -v ss >/dev/null 2>&1; then
    local line
    line="$(ss -lnt 2>/dev/null | grep -E ':(3306|3307)\s' | head -1 || true)"
    if [[ -n "${line}" ]]; then
      PROBE_MYSQL_LISTENING=1
      if echo "${line}" | grep -q ':3307'; then
        PROBE_MYSQL_PORT="3307"
      else
        PROBE_MYSQL_PORT="3306"
      fi
    fi
  fi
  if [[ "${PROBE_MYSQL_LISTENING}" -eq 0 ]] && command -v netstat >/dev/null 2>&1; then
    if netstat -lnt 2>/dev/null | grep -qE ':(3306|3307)\s'; then
      PROBE_MYSQL_LISTENING=1
      PROBE_MYSQL_PORT="3306"
    fi
  fi
  # 宝塔 MySQL 目录
  if [[ -d /www/server/mysql ]] || [[ -x /etc/init.d/mysqld ]]; then
    probe_ok "发现宝塔/系统 MySQL 安装痕迹 (/www/server/mysql 或 mysqld)"
  fi
  if [[ "${PROBE_MYSQL_LISTENING}" -eq 1 ]]; then
    probe_ok "MySQL/MariaDB 正在监听 127.0.0.1:${PROBE_MYSQL_PORT}"
  else
    probe_warn "未检测到本机 MySQL/MariaDB 监听（请在宝塔「数据库」安装/启动；本脚本不会安装第二套 MySQL 服务端）"
  fi
  if command -v mysql >/dev/null 2>&1; then
    probe_ok "mysql 客户端: $(command -v mysql)"
  else
    probe_warn "mysql 客户端未安装（可选，仅用于健康检查）"
  fi
  return 0
}

probe_process_mgr() {
  PROBE_PROCESS_MGR="none"
  probe_log "检测进程管理 (systemd / supervisor)..."
  if command -v systemctl >/dev/null 2>&1; then
    if [[ -d /run/systemd/system ]] || systemctl list-units --type=service >/dev/null 2>&1; then
      PROBE_PROCESS_MGR="systemd"
      probe_ok "进程管理: systemd"
      return 0
    fi
  fi
  if command -v supervisord >/dev/null 2>&1 || command -v supervisorctl >/dev/null 2>&1; then
    PROBE_PROCESS_MGR="supervisor"
    probe_ok "进程管理: supervisor"
    return 0
  fi
  probe_miss "systemd 与 supervisor 均不可用（将尝试安装 supervisor）"
  return 0
}

probe_firewall() {
  PROBE_FIREWALL="none"
  probe_log "检测防火墙..."
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    PROBE_FIREWALL="firewalld"
    probe_ok "防火墙: firewalld（运行中）"
  elif command -v firewall-cmd >/dev/null 2>&1; then
    PROBE_FIREWALL="firewalld-installed"
    probe_warn "firewalld 已安装但可能未运行"
  elif command -v ufw >/dev/null 2>&1; then
    local st
    st="$(ufw status 2>/dev/null | head -1 || true)"
    PROBE_FIREWALL="ufw"
    probe_ok "防火墙: ufw（${st:-状态未知}）"
  elif command -v iptables >/dev/null 2>&1; then
    PROBE_FIREWALL="iptables"
    probe_ok "防火墙: iptables 可用"
  else
    probe_warn "未检测到 firewalld/ufw/iptables（或无权限查看）"
  fi
  return 0
}

probe_wwwroot() {
  PROBE_WWWROOT_SITES=""
  probe_log "检测 /www/wwwroot 现有站点..."
  if [[ ! -d /www/wwwroot ]]; then
    probe_warn "不存在 /www/wwwroot"
    return 0
  fi
  local list=""
  local d
  while IFS= read -r d; do
    [[ -z "${d}" ]] && continue
    list="${list} $(basename "${d}")"
  done < <(find /www/wwwroot -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null | sort)
  PROBE_WWWROOT_SITES="${list# }"
  if [[ -n "${PROBE_WWWROOT_SITES}" ]]; then
    probe_ok "现有站点目录:${PROBE_WWWROOT_SITES}"
  else
    probe_warn "/www/wwwroot 下暂无站点目录（请先在宝塔创建网站）"
  fi
  return 0
}

# 打印完整中文探测报告；架构不支持时返回 1
probe_run_report() {
  echo
  probe_log "======== 环境探测报告 ========"
  local arch_ok=0
  probe_os_arch && arch_ok=1
  probe_baota
  probe_nginx
  probe_mysql
  probe_process_mgr
  probe_firewall
  probe_wwwroot
  probe_log "======== 探测结束 ========"
  echo
  if [[ "${arch_ok}" -ne 1 ]]; then
    return 1
  fi
  return 0
}
