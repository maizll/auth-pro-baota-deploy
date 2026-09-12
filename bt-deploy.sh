#!/usr/bin/env bash
# bt-deploy.sh — 在宝塔机器上选择 /www/wwwroot 下站点并调用 install.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WWWROOT="${BT_WWWROOT:-/www/wwwroot}"
ASSUME_YES=0
SITE_ROOT_OVERRIDE=""

# 预解析与站点选择相关的参数，其余原样传给 install.sh
PASS_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)
      ASSUME_YES=1
      PASS_ARGS+=("$1")
      shift
      ;;
    --site-root)
      SITE_ROOT_OVERRIDE="${2:-}"
      PASS_ARGS+=("$1" "${2:-}")
      shift 2
      ;;
    *)
      PASS_ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ -n "${SITE_ROOT_OVERRIDE}" ]]; then
  echo "[bt-deploy] 使用指定站点: ${SITE_ROOT_OVERRIDE}"
  exec bash "${SCRIPT_DIR}/install.sh" "${PASS_ARGS[@]}"
fi

if [[ ! -d "${WWWROOT}" ]]; then
  echo "[bt-deploy] 未找到 ${WWWROOT}。请在宝塔服务器上运行，或设置 BT_WWWROOT。"
  exit 1
fi

echo "[bt-deploy] 列出站点目录: ${WWWROOT}"
echo "----------------------------------------"
mapfile -t sites < <(find "${WWWROOT}" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | sort)
if [[ "${#sites[@]}" -eq 0 ]]; then
  echo "[bt-deploy] ${WWWROOT} 下没有站点目录。请先在宝塔创建网站。"
  exit 1
fi

i=1
for s in "${sites[@]}"; do
  printf "  %2d) %s\n" "${i}" "$(basename "${s}")"
  i=$((i + 1))
done
echo "----------------------------------------"

SITE_ROOT=""
if [[ "${ASSUME_YES}" -eq 1 ]]; then
  if [[ "${#sites[@]}" -eq 1 ]]; then
    SITE_ROOT="${sites[0]}"
    echo "[bt-deploy] --yes 且仅有一个站点，自动选择: ${SITE_ROOT}"
  else
    echo "[bt-deploy] --yes 但存在多个站点，请显式传入 --site-root"
    exit 1
  fi
else
  printf "[bt-deploy] 请输入序号选择站点: "
  read -r idx || true
  if ! [[ "${idx}" =~ ^[0-9]+$ ]] || [[ "${idx}" -lt 1 ]] || [[ "${idx}" -gt "${#sites[@]}" ]]; then
    echo "[bt-deploy] 无效选择"
    exit 1
  fi
  SITE_ROOT="${sites[$((idx - 1))]}"
fi

echo "[bt-deploy] 已选择: ${SITE_ROOT}"
echo "[bt-deploy] 其余参数传给 install.sh: ${PASS_ARGS[*]:-}"
exec bash "${SCRIPT_DIR}/install.sh" --site-root "${SITE_ROOT}" "${PASS_ARGS[@]}"
