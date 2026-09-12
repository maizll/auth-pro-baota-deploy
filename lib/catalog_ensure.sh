#!/usr/bin/env bash
# 确保软件源 catalog 存在，避免 auth_pro 因缺 catalog.json 直接 Fatal 退出
ensure_software_source_catalog() {
  local site_root="$1"
  local script_dir="${2:-}"
  local dest="${site_root}/backend/software-source/data"
  mkdir -p "${dest}"
  if [[ -f "${dest}/catalog.json" ]]; then
    return 0
  fi
  local src=""
  if [[ -n "${script_dir}" && -f "${script_dir}/seed/software-source-catalog/catalog.json" ]]; then
    src="${script_dir}/seed/software-source-catalog/catalog.json"
  fi
  if [[ -n "${src}" ]]; then
    cp -a "${src}" "${dest}/catalog.json"
  else
    cat > "${dest}/catalog.json" <<'JSON'
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
  chmod 644 "${dest}/catalog.json" || true
  echo "[catalog] ✓ 已写入 ${dest}/catalog.json"
}
