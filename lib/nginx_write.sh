#!/usr/bin/env bash
# lib/nginx_write.sh — 自动写入宝塔兼容 Nginx 反代 + SPA 配置（幂等）
# 由 install.sh source；勿单独执行。

NGX_MARK_BEGIN="#AUTH_PRO_BEGIN"
NGX_MARK_END="#AUTH_PRO_END"
NGX_LAST_TARGET=""
NGX_LAST_MODE=""

ngx_log()  { printf '[nginx] %s\n' "$*"; }
ngx_ok()   { printf '[nginx] ✓ %s\n' "$*"; }
ngx_warn() { printf '[nginx] ⚠ %s\n' "$*" >&2; }
ngx_err()  { printf '[nginx] ✗ %s\n' "$*" >&2; }

ngx_find_bin() {
  if [[ -x /www/server/nginx/sbin/nginx ]]; then
    echo /www/server/nginx/sbin/nginx
    return 0
  fi
  command -v nginx 2>/dev/null || command -v openresty 2>/dev/null || return 1
}

# 生成 location 片段正文（不含标记）
ngx_snippet_body() {
  local port="$1"
  cat <<BODY
    # auth_pro 自动写入 — 静态 + SPA + API 反代（勿删标记行）
    location /api/ {
        proxy_pass http://127.0.0.1:${port};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Connection "";
        proxy_connect_timeout 60s;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        client_max_body_size 50m;
    }

    location /realname-face {
        proxy_pass http://127.0.0.1:${port};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        client_max_body_size 50m;
    }

    location = /openapi.yaml {
        proxy_pass http://127.0.0.1:${port};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location = /healthz {
        proxy_pass http://127.0.0.1:${port};
        proxy_set_header Host \$host;
        access_log off;
    }

    location /docs {
        proxy_pass http://127.0.0.1:${port};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # SPA 回退（静态资源优先）
    location / {
        try_files \$uri \$uri/ /index.html;
    }
BODY
}

ngx_marked_block() {
  local port="$1"
  echo "${NGX_MARK_BEGIN}"
  ngx_snippet_body "${port}"
  echo "${NGX_MARK_END}"
}

# 在站点 conf 中查找匹配 site-root 的 vhost 文件
ngx_find_vhost_for_site() {
  local site_root="$1"
  local site_name
  site_name="$(basename "${site_root}")"
  local vhost_dir="/www/server/panel/vhost/nginx"
  local f

  if [[ ! -d "${vhost_dir}" ]]; then
    return 1
  fi

  # 1) 文件名 = 站点目录名
  if [[ -f "${vhost_dir}/${site_name}.conf" ]]; then
    echo "${vhost_dir}/${site_name}.conf"
    return 0
  fi

  # 2) 配置内 root 指向 site_root
  while IFS= read -r f; do
    if grep -qE "root[[:space:]]+${site_root}[[:space:]]*;" "${f}" 2>/dev/null \
      || grep -qE "root[[:space:]]+${site_root}/[[:space:]]*;" "${f}" 2>/dev/null; then
      echo "${f}"
      return 0
    fi
  done < <(find "${vhost_dir}" -maxdepth 1 -type f -name '*.conf' ! -name '0.*.conf' 2>/dev/null | sort)

  # 3) server_name 含站点名
  while IFS= read -r f; do
    if grep -qE "server_name[[:space:]].*${site_name}" "${f}" 2>/dev/null; then
      echo "${f}"
      return 0
    fi
  done < <(find "${vhost_dir}" -maxdepth 1 -type f -name '*.conf' ! -name '0.*.conf' 2>/dev/null | sort)

  return 1
}

ngx_ensure_extension_include() {
  local vhost_file="$1"
  local site_name="$2"
  local ext_dir="/www/server/panel/vhost/nginx/extension/${site_name}"
  local include_line="include /www/server/panel/vhost/nginx/extension/${site_name}/*.conf;"

  mkdir -p "${ext_dir}"

  if grep -qF "extension/${site_name}/" "${vhost_file}" 2>/dev/null \
    || grep -qF "extension/${site_name}/*.conf" "${vhost_file}" 2>/dev/null; then
    ngx_ok "vhost 已含 extension include"
    return 0
  fi

  # 在 server 块末尾 } 前插入 include（不触碰 SSL 证书块）
  if grep -q "${NGX_MARK_BEGIN}" "${vhost_file}" 2>/dev/null; then
    ngx_log "vhost 已有 AUTH_PRO 标记块，extension include 可选"
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  # 在最后一个单独的 } 前插入（粗粒度但实用）
  awk -v line="    ${include_line}" '
    { lines[NR]=$0 }
    END {
      last=0
      for (i=1;i<=NR;i++) if (lines[i] ~ /^[[:space:]]*}[[:space:]]*$/) last=i
      for (i=1;i<=NR;i++) {
        if (i==last) print line
        print lines[i]
      }
    }
  ' "${vhost_file}" > "${tmp}"

  if [[ -s "${tmp}" ]]; then
    cp -a "${vhost_file}" "${vhost_file}.bak.authpro.$(date +%Y%m%d%H%M%S)"
    cat "${tmp}" > "${vhost_file}"
    rm -f "${tmp}"
    ngx_ok "已向 vhost 添加 extension include（已备份）"
    return 0
  fi
  rm -f "${tmp}"
  ngx_warn "无法自动插入 extension include"
  return 1
}

ngx_write_extension_file() {
  local site_name="$1"
  local port="$2"
  local ext_dir="/www/server/panel/vhost/nginx/extension/${site_name}"
  local target="${ext_dir}/auth_pro.conf"
  mkdir -p "${ext_dir}"
  {
    echo "${NGX_MARK_BEGIN}"
    ngx_snippet_body "${port}"
    echo "${NGX_MARK_END}"
  } > "${target}"
  NGX_LAST_TARGET="${target}"
  NGX_LAST_MODE="extension"
  ngx_ok "已写入 extension 配置: ${target}"
}

# 幂等更新标记块
ngx_upsert_marked_block() {
  local file="$1"
  local port="$2"
  local tmp block
  tmp="$(mktemp)"
  block="$(mktemp)"
  ngx_marked_block "${port}" > "${block}"

  if grep -q "${NGX_MARK_BEGIN}" "${file}" 2>/dev/null; then
    awk -v begin="${NGX_MARK_BEGIN}" -v end="${NGX_MARK_END}" -v blk="${block}" '
      BEGIN { while ((getline line < blk) > 0) { b=b line ORS } close(blk) }
      $0 ~ begin { print b; skip=1; next }
      skip && $0 ~ end { skip=0; next }
      !skip { print }
    ' "${file}" > "${tmp}"
    cp -a "${file}" "${file}.bak.authpro.$(date +%Y%m%d%H%M%S)"
    cat "${tmp}" > "${file}"
    ngx_ok "已更新标记块: ${file}"
  else
    # 插入到最后一个 } 前
    awk -v blk="${block}" '
      BEGIN { while ((getline line < blk) > 0) { b=b line ORS } close(blk) }
      { lines[NR]=$0 }
      END {
        last=0
        for (i=1;i<=NR;i++) if (lines[i] ~ /^[[:space:]]*}[[:space:]]*$/) last=i
        for (i=1;i<=NR;i++) {
          if (i==last) printf "%s", b
          print lines[i]
        }
      }
    ' "${file}" > "${tmp}"
    cp -a "${file}" "${file}.bak.authpro.$(date +%Y%m%d%H%M%S)"
    cat "${tmp}" > "${file}"
    ngx_ok "已插入标记块: ${file}"
  fi
  rm -f "${tmp}" "${block}"
  NGX_LAST_TARGET="${file}"
  NGX_LAST_MODE="markers"
}

ngx_write_site_local_snippet() {
  local site_root="$1"
  local port="$2"
  local out="${site_root}/backend/nginx-auth-pro.snippet.conf"
  mkdir -p "$(dirname "${out}")"
  ngx_marked_block "${port}" > "${out}"
  ngx_ok "站点内参考片段: ${out}"
}

ngx_test_and_reload() {
  local bin
  bin="$(ngx_find_bin)" || {
    ngx_warn "未找到 nginx 二进制，跳过 -t/reload"
    return 1
  }
  ngx_log "执行: ${bin} -t"
  if ! "${bin}" -t; then
    ngx_err "nginx -t 失败 — 配置未重载。请检查上方错误；已保留 .bak.authpro.* 备份"
    return 1
  fi
  ngx_ok "nginx -t 通过"
  if [[ -x /etc/init.d/nginx ]]; then
    /etc/init.d/nginx reload && ngx_ok "已 reload (init.d)" && return 0
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload nginx 2>/dev/null && ngx_ok "已 reload (systemctl)" && return 0
  fi
  if "${bin}" -s reload 2>/dev/null; then
    ngx_ok "已 reload (nginx -s reload)"
    return 0
  fi
  ngx_warn "reload 失败，请手动: /etc/init.d/nginx reload"
  return 1
}

# 主入口
# ngx_auto_configure <site_root> <port> [--yes]
ngx_auto_configure() {
  local site_root="$1"
  local port="$2"
  shift 2 || true
  local site_name
  site_name="$(basename "${site_root}")"

  ngx_log "======== 自动写入 Nginx 配置 ========"
  ngx_log "站点名: ${site_name}  根目录: ${site_root}  后端端口: ${port}"

  ngx_write_site_local_snippet "${site_root}" "${port}"

  local vhost=""
  if vhost="$(ngx_find_vhost_for_site "${site_root}")"; then
    ngx_ok "匹配到宝塔 vhost: ${vhost}"
    # 优先 extension 目录（面板不易整文件覆盖）
    local ext_dir="/www/server/panel/vhost/nginx/extension"
    if [[ -d /www/server/panel/vhost/nginx ]]; then
      mkdir -p "${ext_dir}/${site_name}" 2>/dev/null || true
      if [[ -d "${ext_dir}/${site_name}" ]] || mkdir -p "${ext_dir}/${site_name}"; then
        ngx_ensure_extension_include "${vhost}" "${site_name}" || true
        ngx_write_extension_file "${site_name}" "${port}"
        # 同时在 vhost 内维护标记块作为双保险（若 extension include 失败仍可用）
        # 若 extension 写入成功且 include 存在，可不再改 vhost 主体以免重复 location
        if grep -qF "extension/${site_name}/" "${vhost}" 2>/dev/null; then
          ngx_ok "使用 extension 模式，避免在主 conf 重复 location"
        else
          ngx_upsert_marked_block "${vhost}" "${port}"
        fi
      else
        ngx_upsert_marked_block "${vhost}" "${port}"
      fi
    else
      ngx_upsert_marked_block "${vhost}" "${port}"
    fi
  else
    ngx_warn "未找到匹配的宝塔 vhost 配置"
    ngx_warn "已生成站点内片段，请手动将内容并入宝塔站点「配置文件」"
    ngx_warn "手动步骤: 网站 → ${site_name} → 配置文件 → 粘贴 #AUTH_PRO_BEGIN ... #AUTH_PRO_END 块 → 保存 → 重载"
    # 仍尝试写 extension，便于用户日后建站后 include
    if [[ -d /www/server/panel/vhost/nginx ]]; then
      ngx_write_extension_file "${site_name}" "${port}" || true
    fi
  fi

  ngx_test_and_reload || true
  ngx_log "======== Nginx 配置处理结束 (mode=${NGX_LAST_MODE:-none}) ========"
  return 0
}
