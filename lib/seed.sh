#!/usr/bin/env bash
# lib/seed.sh — 软件源 / 首页模板演示内容补全（安全、可幂等）
# 由 install.sh source；勿单独执行。不编造付费插件。

SEED_ENABLED=1
SEED_ADMIN_KEY="${SOFTWARE_SOURCE_ADMIN_KEY:-}"
SEED_STAGED=0
SEED_COPIED=0
SEED_API_OK=0

seed_log()  { printf '[软件源] %s\n' "$*"; }
seed_ok()   { printf '[软件源] ✓ %s\n' "$*"; }
seed_warn() { printf '[软件源] ⚠ %s\n' "$*" >&2; }

seed_bundled_dir() {
  local script_dir="${1:-}"
  local candidates=(
    "${script_dir}/examples/software-source-seed"
    "${script_dir}/seed/software-source"
  )
  local c
  for c in "${candidates[@]}"; do
    if [[ -d "${c}" ]]; then
      echo "${c}"
      return 0
    fi
  done
  return 1
}

# 在解压后的站点包中查找自带 software-source 数据
seed_find_package_data() {
  local site_root="$1"
  local candidates=(
    "${site_root}/software-source/data"
    "${site_root}/backend/software-source/data"
    "${site_root}/backend/data/software-source"
    "${site_root}/data/software-source"
  )
  local c
  for c in "${candidates[@]}"; do
    if [[ -d "${c}" ]]; then
      echo "${c}"
      return 0
    fi
  done
  return 1
}

seed_http_get() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --connect-timeout 3 --max-time 8 "${url}" 2>/dev/null
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O - --timeout=8 "${url}" 2>/dev/null
  else
    return 1
  fi
}

seed_http_post_json() {
  local url="$1"
  local json="$2"
  local key="$3"
  if command -v curl >/dev/null 2>&1; then
    if [[ -n "${key}" ]]; then
      curl -fsS --connect-timeout 3 --max-time 15 \
        -H "Content-Type: application/json" \
        -H "X-Admin-Key: ${key}" \
        -H "Authorization: Bearer ${key}" \
        -d "${json}" "${url}" 2>/dev/null
    else
      curl -fsS --connect-timeout 3 --max-time 15 \
        -H "Content-Type: application/json" \
        -d "${json}" "${url}" 2>/dev/null
    fi
  else
    return 1
  fi
}

# 等待后端健康
seed_wait_healthy() {
  local port="$1"
  local retries="${2:-15}"
  local i url body
  seed_log "等待后端健康检查 (127.0.0.1:${port})..."
  for ((i=1; i<=retries; i++)); do
    for url in \
      "http://127.0.0.1:${port}/healthz" \
      "http://127.0.0.1:${port}/api/install/status" \
      "http://127.0.0.1:${port}/api/healthz"; do
      body="$(seed_http_get "${url}" || true)"
      if [[ -n "${body}" ]]; then
        seed_ok "后端已响应: ${url}"
        echo "${body}"
        return 0
      fi
    done
    sleep 1
  done
  seed_warn "后端暂未就绪（已重试 ${retries}s）"
  return 1
}

seed_is_installed() {
  local body="$1"
  # 粗略判断安装向导是否完成
  if echo "${body}" | grep -qiE '"installed"[[:space:]]*:[[:space:]]*true'; then
    return 0
  fi
  if echo "${body}" | grep -qiE '"status"[[:space:]]*:[[:space:]]*"(ok|ready|installed)"'; then
    return 0
  fi
  if echo "${body}" | grep -qiE 'ok|healthy|pong'; then
    # healthz 通但未必已完成安装向导
    return 2
  fi
  return 1
}

# 将演示目录同步到数据目录（幂等 rsync/cp）
seed_copy_demo_tree() {
  local src="$1"
  local dest="$2"
  mkdir -p "${dest}"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a "${src}/" "${dest}/"
  else
    cp -a "${src}/." "${dest}/"
  fi
  SEED_COPIED=1
  seed_ok "已同步演示内容: ${src} → ${dest}"
}

seed_stage_for_first_run() {
  local script_dir="$1"
  local data_dir="$2"
  local site_root="$3"
  local bundled pkg_data stage_dir

  stage_dir="${data_dir}/software-source-seed-staged"
  mkdir -p "${stage_dir}"

  if pkg_data="$(seed_find_package_data "${site_root}")"; then
    seed_copy_demo_tree "${pkg_data}" "${stage_dir}"
  elif bundled="$(seed_bundled_dir "${script_dir}")"; then
    seed_copy_demo_tree "${bundled}" "${stage_dir}"
  else
    seed_warn "无可用演示数据源，跳过暂存"
    return 1
  fi

  # 同时放入 data 下常见路径，便于首启扫描
  mkdir -p "${data_dir}/software-source"
  if [[ -d "${stage_dir}" ]]; then
    seed_copy_demo_tree "${stage_dir}" "${data_dir}/software-source" || true
  fi
  SEED_STAGED=1
  seed_ok "首启种子已暂存: ${stage_dir}"
  seed_log "说明: 请先在浏览器完成安装向导；完成后软件源可读取 data 下演示目录，或再次运行本脚本 --seed-software-source"
  return 0
}

seed_try_admin_api() {
  local port="$1"
  local key="$2"
  local script_dir="$3"
  # 尝试若干常见管理端点（失败则静默降级）
  local base="http://127.0.0.1:${port}"
  local endpoints=(
    "/api/software-source/admin/seed"
    "/api/admin/software-source/seed"
    "/api/software-source/seed"
  )
  local ep url
  for ep in "${endpoints[@]}"; do
    url="${base}${ep}"
    seed_log "尝试管理 API: ${ep}"
    if seed_http_post_json "${url}" '{"demo":true,"source":"baota-deploy"}' "${key}" >/dev/null; then
      SEED_API_OK=1
      seed_ok "管理 API 种子调用成功: ${ep}"
      return 0
    fi
  done
  seed_warn "管理 API 不可用或密钥未配置 — 已回退为本地文件种子"
  return 1
}

seed_ensure_index_hint() {
  local data_dir="$1"
  local idx="${data_dir}/software-source/index.json"
  if [[ -f "${idx}" ]]; then
    seed_ok "已存在 index.json: ${idx}"
    return 0
  fi
  # 若演示包带 index，上面 copy 已处理；否则写最小 demo index
  mkdir -p "$(dirname "${idx}")"
  if [[ ! -f "${idx}" ]]; then
    cat > "${idx}" <<'JSON'
{
  "name": "auth-pro 演示软件源",
  "version": "1.0.0",
  "description": "宝塔一键部署附带的 hello-demo 目录（非付费插件）",
  "categories": [
    { "id": "demo", "name": "演示", "description": "hello-demo 示例分类" }
  ],
  "plugins": [
    {
      "id": "hello-demo",
      "name": "Hello Demo",
      "version": "0.1.0",
      "category": "demo",
      "description": "开源演示插件占位，非付费内容",
      "paid": false
    }
  ],
  "templates": [
    {
      "id": "home-hello",
      "name": "Hello 首页模板",
      "version": "0.1.0",
      "description": "演示用首页模板占位"
    }
  ]
}
JSON
    seed_ok "已写入演示 index.json"
  fi
}

# 主入口
# seed_run <script_dir> <site_root> <data_dir> <port> [--yes] [--admin-key KEY] [--seed|--no-seed]
seed_run() {
  local script_dir="$1"
  local site_root="$2"
  local data_dir="$3"
  local port="$4"
  shift 4 || true

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y) shift ;;
      --admin-key)
        SEED_ADMIN_KEY="${2:-}"; shift 2 ;;
      --seed) SEED_ENABLED=1; shift ;;
      --no-seed) SEED_ENABLED=0; shift ;;
      *) shift ;;
    esac
  done

  if [[ "${SEED_ENABLED}" -ne 1 ]]; then
    seed_log "已跳过软件源种子 (--no-seed)"
    return 0
  fi

  seed_log "======== 软件源 / 模板自动补全 ========"
  mkdir -p "${data_dir}"

  local body=""
  if body="$(seed_wait_healthy "${port}" 20)"; then
    local inst=0
    seed_is_installed "${body}"
    inst=$?
    if [[ "${inst}" -eq 0 ]]; then
      seed_ok "检测到应用已安装"
      if [[ -n "${SEED_ADMIN_KEY}" ]]; then
        seed_try_admin_api "${port}" "${SEED_ADMIN_KEY}" "${script_dir}" || true
      else
        seed_warn "未提供 --software-source-admin-key，跳过管理 API 种子"
      fi
      local pkg_data bundled
      if pkg_data="$(seed_find_package_data "${site_root}")"; then
        seed_copy_demo_tree "${pkg_data}" "${data_dir}/software-source"
      elif bundled="$(seed_bundled_dir "${script_dir}")"; then
        seed_copy_demo_tree "${bundled}" "${data_dir}/software-source"
      fi
      seed_ensure_index_hint "${data_dir}"
    else
      seed_warn "后端已启动，但安装向导可能尚未完成"
      seed_log "将演示内容暂存，供首次安装后使用"
      seed_stage_for_first_run "${script_dir}" "${data_dir}" "${site_root}" || true
      seed_ensure_index_hint "${data_dir}"
    fi
  else
    seed_warn "后端未健康 — 仍暂存演示种子到数据目录"
    seed_stage_for_first_run "${script_dir}" "${data_dir}" "${site_root}" || true
    seed_ensure_index_hint "${data_dir}"
  fi

  # 公开索引 URL 提示由 install.sh 汇总打印
  seed_log "======== 软件源处理结束 (staged=${SEED_STAGED} copied=${SEED_COPIED} api=${SEED_API_OK}) ========"
  return 0
}
