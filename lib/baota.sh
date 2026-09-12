#!/usr/bin/env bash
# lib/baota.sh — 宝塔面板插件/组件检测与友好安装尝试
# 由 install.sh source；勿单独执行。永不卸载无关插件。

# shellcheck disable=SC2034

BT_CHECKED=()
BT_INSTALLED=()
BT_SKIPPED=()
BT_MANUAL=()

bt_log()  { printf '[宝塔] %s\n' "$*"; }
bt_ok()   { printf '[宝塔] ✓ %s\n' "$*"; }
bt_warn() { printf '[宝塔] ⚠ %s\n' "$*" >&2; }
bt_miss() { printf '[宝塔] ✗ 缺失 → %s\n' "$*"; }

bt_record_checked() { BT_CHECKED+=("$1"); }
bt_record_installed() { BT_INSTALLED+=("$1"); }
bt_record_skipped() { BT_SKIPPED+=("$1"); }
bt_record_manual() { BT_MANUAL+=("$1"); }

bt_find_nginx_bin() {
  if [[ -x /www/server/nginx/sbin/nginx ]]; then
    echo /www/server/nginx/sbin/nginx
    return 0
  fi
  if command -v nginx >/dev/null 2>&1; then
    command -v nginx
    return 0
  fi
  if command -v openresty >/dev/null 2>&1; then
    command -v openresty
    return 0
  fi
  return 1
}

bt_nginx_available() {
  bt_find_nginx_bin >/dev/null 2>&1 || [[ -d /www/server/nginx ]]
}

# 尝试通过宝塔 install_soft.sh 安装 nginx（仅当完全缺失且 --yes）
bt_try_install_nginx() {
  local yes="${1:-0}"
  bt_record_checked "nginx"
  if bt_nginx_available; then
    bt_ok "Nginx 已可用，跳过安装（不破坏现有宝塔 Nginx）"
    bt_record_skipped "nginx(已存在)"
    return 0
  fi
  bt_miss "Nginx"
  local installer="/www/server/panel/install/install_soft.sh"
  local nginx_sh="/www/server/panel/install/nginx.sh"
  if [[ ! -f "${installer}" && ! -f "${nginx_sh}" ]]; then
    bt_warn "宝塔安装脚本不可用，无法自动安装 Nginx"
    bt_record_manual "在宝塔「软件商店」安装 Nginx（推荐稳定版）"
    return 1
  fi
  if [[ "${yes}" != "1" ]]; then
    bt_warn "缺少 Nginx。使用 --yes 可尝试宝塔友好安装；或手动: 软件商店 → Nginx"
    bt_record_manual "bash /www/server/panel/install/install_soft.sh 0 install nginx 1.22"
    return 1
  fi
  if [[ "$(id -u)" -ne 0 ]]; then
    bt_warn "安装 Nginx 需要 root"
    bt_record_manual "sudo bash /www/server/panel/install/install_soft.sh 0 install nginx 1.22"
    return 1
  fi
  bt_log "尝试通过宝塔脚本安装 Nginx（可能耗时较长）..."
  local rc=0
  if [[ -f "${installer}" ]]; then
    # 常见: install_soft.sh 0 install nginx 1.22
    bash "${installer}" 0 install nginx 1.22 || rc=$?
  elif [[ -f "${nginx_sh}" ]]; then
    bash "${nginx_sh}" install 1.22 || rc=$?
  fi
  if bt_nginx_available; then
    bt_ok "Nginx 安装成功（或已就绪）"
    bt_record_installed "nginx"
    return 0
  fi
  bt_warn "自动安装 Nginx 未成功 (exit=${rc})。请到宝塔「软件商店」手动安装 Nginx"
  bt_record_manual "面板软件商店 → 安装 Nginx；或: bash ${installer} 0 install nginx 1.22"
  return 1
}

# 检测常见「对本 Go+静态站有用」的面板能力（仅检查，不乱装付费插件）
bt_check_useful_extensions() {
  bt_log "检测宝塔相关组件（仅检查，不卸载任何已有插件）..."
  bt_record_checked "panel"
  if [[ -d /www/server/panel ]]; then
    bt_ok "面板: /www/server/panel"
  else
    bt_miss "面板目录"
    bt_record_manual "请先安装宝塔 Linux 面板"
  fi

  bt_record_checked "bt-cli"
  if command -v bt >/dev/null 2>&1; then
    bt_ok "bt CLI 存在"
  else
    bt_warn "bt CLI 不可用 → 无法调用 bt default / bt reload 等快捷命令"
    bt_record_manual "确认 /usr/bin/bt 存在；面板修复: bt 16"
  fi

  bt_record_checked "vhost-nginx"
  if [[ -d /www/server/panel/vhost/nginx ]]; then
    bt_ok "站点 vhost 目录: /www/server/panel/vhost/nginx"
  else
    bt_warn "未找到 vhost/nginx（站点配置将写入备用路径或仅生成片段）"
  fi

  bt_record_checked "mysql-server-bt"
  if [[ -d /www/server/mysql ]] || [[ -x /etc/init.d/mysqld ]]; then
    bt_ok "宝塔 MySQL 痕迹存在（不会安装第二套 MySQL 服务端）"
    bt_record_skipped "mysql-server(宝塔已有或不强制)"
  else
    bt_warn "未发现宝塔 MySQL。请在软件商店安装 MySQL/MariaDB（本脚本不自动装服务端）"
    bt_record_manual "软件商店 → 安装 MySQL，再在「数据库」中建库"
  fi

  # 可选：纯静态/反代不需要 PHP；仅记录
  bt_record_checked "php(可选)"
  if ls /www/server/php/*/bin/php >/dev/null 2>&1; then
    bt_ok "检测到 PHP（本站 Go 后端通常不需要）"
    bt_record_skipped "php(非必需)"
  else
    bt_log "未安装 PHP — 对 auth_pro Go+静态站通常无影响，跳过"
    bt_record_skipped "php(非必需-未装)"
  fi
}

bt_reload_web() {
  local nginx_bin
  nginx_bin="$(bt_find_nginx_bin 2>/dev/null || true)"
  if [[ -n "${nginx_bin}" ]]; then
    if "${nginx_bin}" -t 2>/dev/null; then
      if [[ -x /etc/init.d/nginx ]]; then
        /etc/init.d/nginx reload && return 0
      fi
      if command -v systemctl >/dev/null 2>&1; then
        systemctl reload nginx 2>/dev/null && return 0
      fi
      "${nginx_bin}" -s reload 2>/dev/null && return 0
    else
      bt_warn "nginx -t 失败，跳过 reload"
      return 1
    fi
  fi
  if command -v bt >/dev/null 2>&1; then
    # bt 没有统一非交互 reload web；尝试 init 脚本
    true
  fi
  return 1
}

bt_print_summary() {
  echo
  bt_log "-------- 宝塔组件检查摘要 --------"
  local x
  if [[ "${#BT_CHECKED[@]}" -gt 0 ]]; then
    bt_log "已检查: ${BT_CHECKED[*]}"
  fi
  if [[ "${#BT_INSTALLED[@]}" -gt 0 ]]; then
    bt_ok "本次安装: ${BT_INSTALLED[*]}"
  fi
  if [[ "${#BT_SKIPPED[@]}" -gt 0 ]]; then
    bt_log "跳过: ${BT_SKIPPED[*]}"
  fi
  if [[ "${#BT_MANUAL[@]}" -gt 0 ]]; then
    bt_warn "需手动处理:"
    for x in "${BT_MANUAL[@]}"; do
      printf '         - %s\n' "${x}"
    done
  fi
  bt_log "----------------------------------"
}

# 总入口: bt_ensure_stack [--yes]
bt_ensure_stack() {
  local yes=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y) yes=1; shift ;;
      *) shift ;;
    esac
  done
  BT_CHECKED=()
  BT_INSTALLED=()
  BT_SKIPPED=()
  BT_MANUAL=()
  bt_log "======== 宝塔组件保障 ========"
  bt_check_useful_extensions
  bt_try_install_nginx "${yes}" || true
  bt_print_summary
  return 0
}
