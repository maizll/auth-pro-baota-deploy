# auth-pro-baota-deploy

宝塔面板 **真·全自动一键** 部署工具，用于部署 `auth_pro-full-vX.Y.Z.tar.gz`（cloud-control-auth / auth_pro）标准站点布局。

**解压后站点根目录应包含：**

| 路径 | 说明 |
|------|------|
| `index.html` | 前端入口 |
| `assets/` | 前端静态资源 |
| `backend/auth_pro` | Linux amd64 后端二进制 |
| `backend/software-source/data/catalog.json` | 软件源目录（随包） |
| `manifest.json` | 版本/清单信息 |

默认下载地址：

```text
https://github.com/zxcvbnm25/auth-pro-baota-deploy/releases/download/vX.Y.Z/auth_pro-full-vX.Y.Z.tar.gz
```

> **强烈建议使用 `--package` 本地包**：部分服务器访问 GitHub Releases 不稳定或被墙。

---

## 一键安装（推荐）

在宝塔服务器 SSH 中执行：

```bash
# 本地包（推荐）
sudo bash install.sh \
  --site-root /www/wwwroot/你的站点域名或目录 \
  --package /root/auth_pro-full-v1.2.1.tar.gz \
  --yes

# 或指定版本从 GitHub 拉取
cd /tmp && git clone https://github.com/zxcvbnm25/auth-pro-baota-deploy.git \
  && cd auth-pro-baota-deploy \
  && sudo bash install.sh --site-root /www/wwwroot/你的站点 --version 1.2.1 --yes
```

交互选择站点目录（列出 `/www/wwwroot`）：

```bash
sudo bash bt-deploy.sh --package /root/auth_pro-full-v1.2.1.tar.gz --yes
# 多个站点时请加: --site-root /www/wwwroot/xxx
```

`--yes` = **全自动非交互**：探测 → 补依赖 → 宝塔组件检查 → 解压 → 写服务 → 写 Nginx → 软件源种子 → 打印清单。

---

## 全自动会做什么

### A. 环境探测（中文报告）

- OS / 架构（**仅 amd64**）
- 宝塔面板是否存在、版本（`/www/server/panel`、`bt` CLI）
- Nginx/OpenResty 路径与版本
- MySQL/MariaDB 是否监听及端口
- systemd vs supervisor
- 防火墙（firewalld / ufw / iptables）状态
- `/www/wwwroot` 现有站点列表

### B. 自动补齐系统组件（`--yes` 默认路径）

- `curl`/`wget`、`tar`、`ca-certificates`（`lib/deps.sh`）
- 优先 **systemd**；否则安装 **supervisor**
- 可选安装 **mysql 客户端**（仅客户端；**不会**在宝塔已有 MySQL 时再装一套服务端）
- 尝试用 firewalld/ufw 放行后端端口；失败则明确警告
- `--skip-deps` / `--skip-firewall` 仍可用

### C. 宝塔面板组件

- 检查面板、`bt` CLI、vhost 目录、MySQL 痕迹、PHP（可选）
- Nginx 缺失时：尝试宝塔友好安装  
  `bash /www/server/panel/install/install_soft.sh 0 install nginx 1.22`  
  （需 `--yes` + root；**不破坏**已有 BT Nginx；**永不卸载**无关插件）
- CLI/脚本不可用时降级，并打印精确手动步骤
- 结束打印「已检查 / 本次安装 / 跳过 / 需手动」摘要

### D. Nginx 反代 + 站点配置 — **自动写入**

- 从 `--site-root` 基名推断站点名，匹配 `/www/server/panel/vhost/nginx/*.conf`
- **优先**写入  
  `/www/server/panel/vhost/nginx/extension/<站点>/auth_pro.conf`  
  并确保站点 conf `include` 该目录（面板不易整文件覆盖）
- 否则在 vhost 内用 `#AUTH_PRO_BEGIN` … `#AUTH_PRO_END` **幂等**更新
- 内容包括：静态 + SPA `try_files`；反代 `/api/`、`/realname-face`、`/openapi.yaml`、`/healthz`、`/docs`
- **不主动改写 SSL 证书块**
- `nginx -t` 后 `reload`（`init.d` / `systemctl` / `nginx -s reload`）
- `examples/nginx.conf.snippet` 与脚本生成内容保持同步
- `--skip-nginx-write` 可只打印片段

### E. 部署包 + 进程

- 解压到站点根；升级时备份 `backend/auth_pro`
- `chmod +x backend/auth_pro`
- 默认 `AUTO_PRO_DATA_DIR=<site-root>/backend/data`
- 安装并 enable+start systemd 或 supervisor
- 默认版本 **1.2.1**；`--package` 本地路径为关键路径

### F. 软件源 / 首页模板自动补全

- 后端健康后（`/healthz` 或 `/api/install/status`）：
  - 未完成安装向导 → 暂存演示种子并说明需先跑向导
  - 已安装 → 将 `examples/software-source-seed`（或包内 `software-source/data`）同步到数据目录；若提供管理密钥则尝试管理 API
- `--seed-software-source`（`--yes` 时默认开）/ `--no-seed-software-source`
- `--software-source-admin-key`（同时写入服务环境变量；**无硬编码真实密钥**）
- 仅 **hello-demo** 风格演示内容，不编造付费插件

### G. 体验

- 全程中文日志：`检测 → 缺失 → 安装/写入 → 成功/跳过`
- 结束清单：站点 URL、宝塔建库、管理员登录、软件源  
  `https://域名/api/software-source/index.json`

---

## 命令行参数

| 参数 | 说明 |
|------|------|
| `--site-root <路径>` | 站点根目录（必填） |
| `--port <端口>` | 后端端口，默认 `19127` |
| `--package <文件>` | 本地 tar.gz（推荐） |
| `--version <X.Y.Z>` | 版本号，默认 `1.2.0` |
| `--url <URL>` | 完整下载地址 |
| `--data-dir <路径>` | 数据目录；默认 `<site-root>/backend/data` |
| `--yes` / `-y` | 全自动非交互 |
| `--skip-deps` | 跳过依赖检测与自动安装 |
| `--skip-firewall` | 跳过防火墙放行 |
| `--skip-nginx-write` | 跳过自动写 Nginx |
| `--skip-probe` | 跳过环境探测报告 |
| `--seed-software-source` | 启用软件源种子 |
| `--no-seed-software-source` | 禁用软件源种子 |
| `--software-source-admin-key <密钥>` | 软件源管理密钥 |
| `--uninstall` / `--purge` | 卸载 / 清理 |
| `--help` / `-h` | 帮助 |

---

## 环境变量

| 变量 | 说明 |
|------|------|
| `PORT` | 后端端口 |
| `AUTO_PRO_DATA_DIR` | 数据目录 |
| `SOFTWARE_SOURCE_ADMIN_KEY` | 软件源管理密钥（仅服务环境，勿放进 Web 目录） |
| `BT_WWWROOT` | `bt-deploy.sh` 扫描根，默认 `/www/wwwroot` |

---

## 宝塔 CLI 能力与限制

| 能力 | 说明 |
|------|------|
| `bt` / `bt 14` 等 | 面板管理菜单；**非**通用「安装任意插件」非交互 API |
| `install_soft.sh 0 install nginx <ver>` | 官方常见的 Nginx 命令行安装方式 |
| vhost 路径 | `/www/server/panel/vhost/nginx/`；extension：`.../extension/<站点>/` |
| 限制 | 无稳定公开的「一键装所有商店插件」CLI；付费/第三方插件不自动安装；MySQL **服务端**请在软件商店安装；本脚本只检查并给出手动步骤 |

---

## 进程管理

```bash
sudo systemctl status auth-pro
sudo systemctl restart auth-pro
sudo journalctl -u auth-pro -f

sudo supervisorctl status auth-pro
sudo supervisorctl restart auth-pro
```

卸载：

```bash
sudo bash install.sh --uninstall
sudo bash install.sh --site-root /www/wwwroot/你的站点 --purge --yes
```

---

## 数据库

请在 **宝塔面板 → 数据库** 中创建 MySQL/MariaDB 库与用户，并在 auth_pro 安装向导中配置。

本脚本**不会**自动安装 MySQL 服务端，也**不会**删除已有数据库或其他站点。

---

## 安全建议

1. 对外只暴露 Nginx 80/443；后端端口仅本机反代。
2. `SOFTWARE_SOURCE_ADMIN_KEY` 只放在服务环境变量中。
3. 站点目录避免 `777`；使用 HTTPS。
4. 定期备份 `AUTO_PRO_DATA_DIR` 与数据库。
5. Nginx 修改带备份后缀 `.bak.authpro.*`，可回滚。

---

## 目录结构

```text
auth-pro-baota-deploy/
├── install.sh                 # 主入口（全自动）
├── bt-deploy.sh               # 列出 /www/wwwroot 并调用 install.sh
├── lib/
│   ├── deps.sh                # 依赖 / 防火墙 / mysql 客户端
│   ├── probe.sh               # 环境探测中文报告
│   ├── baota.sh               # 宝塔组件检查与 Nginx 友好安装
│   ├── nginx_write.sh         # 自动写 vhost / extension
│   └── seed.sh                # 软件源 / 模板种子
├── examples/
│   ├── nginx.conf.snippet
│   ├── auth-pro.service
│   ├── auth-pro.supervisor.conf
│   └── software-source-seed/  # hello-demo 演示内容
├── seed/software-source/      # 同上（备用路径）
├── README.md
└── LICENSE                    # MIT
```

---

## 许可证

MIT License © 2026 zxcvbnm25


## 忘记管理员密码 / 强制重装向导

一键脚本**不会**替你生成管理员密码。若部署后直接进入登录页且密码未知：

```bash
sudo bash install.sh --site-root /www/wwwroot/auth.maizll.com --yes --fresh
```

然后在宝塔重建空 MySQL 库，再打开站点走安装向导。

`--fresh` 会：停止服务、删除 `install.lock`/`db.json`、清空数据目录；**不会**自动删 MySQL 库。


## 仍跳过安装向导时

先跑强制复位（在服务器上）：

```bash
cd /tmp && git clone https://github.com/zxcvbnm25/auth-pro-baota-deploy.git && cd auth-pro-baota-deploy
sudo bash reset-install.sh /www/wwwroot/auth.maizll.com
```

确认输出里 `local status` 为 `{"installed":false}` 后再打开网站。


## 在线更新源

默认清单（公开仓库）：

```text
https://github.com/zxcvbnm25/auth-pro-baota-deploy/releases/latest/download/latest.json
```

一键安装会写入服务环境变量 `AUTO_PRO_UPDATE_URL`。主仓 `cloud-control-auth` 为私有仓，不适合作为匿名更新源。
