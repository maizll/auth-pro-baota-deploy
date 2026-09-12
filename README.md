# auth-pro-baota-deploy

宝塔面板一键部署工具，用于部署 `auth_pro-full-vX.Y.Z.tar.gz`（cloud-control-auth / auth_pro）标准站点布局。

**解压后站点根目录应包含：**

| 路径 | 说明 |
|------|------|
| `index.html` | 前端入口 |
| `assets/` | 前端静态资源 |
| `backend/auth_pro` | Linux amd64 后端二进制 |
| `manifest.json` | 版本/清单信息 |

默认下载地址：

```text
https://github.com/zxcvbnm25/cloud-control-auth/releases/download/vX.Y.Z/auth_pro-full-vX.Y.Z.tar.gz
```

---

## 一键安装（推荐）

在宝塔服务器 SSH 中执行（将版本号与站点目录换成你的）：

```bash
cd /tmp && git clone https://github.com/zxcvbnm25/auth-pro-baota-deploy.git \
  && cd auth-pro-baota-deploy \
  && sudo bash install.sh --site-root /www/wwwroot/你的站点域名或目录 --version 1.0.0 --yes
```

使用本地已下载的包：

```bash
sudo bash install.sh --site-root /www/wwwroot/你的站点 --package /tmp/auth_pro-full-v1.0.0.tar.gz --yes
```

交互选择站点目录（列出 `/www/wwwroot`）：

```bash
sudo bash bt-deploy.sh --version 1.0.0 --yes
```

---

## 脚本会做什么

1. **检测架构**：仅支持 Linux amd64（x86_64），其他架构直接报错退出。
2. **检测宝塔路径**：`/www/wwwroot`、`/www/server/panel`，并打印部署提示。
3. **自动检测并安装缺失依赖**（除非 `--skip-deps`）：
   - 包管理器：`apt-get` / `yum` / `dnf` / `apk`
   - 工具：`curl` 或 `wget`、`tar`、`ca-certificates`
   - 进程管理：优先 **systemd**；若不可用则尝试安装并配置 **supervisor**
   - **不会**强制安装 Nginx（宝塔通常已有）；仅检测 nginx/openresty 并在缺失时警告
   - **不会**自动安装 MySQL/MariaDB；仅可选检查 `mysql` 客户端，并提示在面板中建库
4. 下载（或使用本地）`auth_pro-full-*.tar.gz`，解压到 `--site-root`。
5. 升级时备份已有 `backend/auth_pro`，并 `chmod +x`。
6. 写入并启动 systemd 或 supervisor 服务。
7. 打印 Nginx 反代片段与后续步骤。

依赖自动安装前会询问确认；加 `--yes` / `-y` 可免交互。

每一步检测 → 缺失 → 安装均有中文日志：`[deps]` / `[install]`。

---

## 命令行参数

| 参数 | 说明 |
|------|------|
| `--site-root <路径>` | 站点根目录（必填）。例：`/www/wwwroot/auth.example.com` |
| `--port <端口>` | 后端端口，默认 `19127` |
| `--package <文件>` | 本地 tar.gz 路径 |
| `--version <X.Y.Z>` | 版本号，用于拼接默认 GitHub Release URL |
| `--url <URL>` | 完整包下载地址（覆盖默认 URL） |
| `--data-dir <路径>` | 数据目录；默认 `<site-root>/data` |
| `--yes` / `-y` | 自动确认依赖安装等操作 |
| `--skip-deps` | 跳过依赖检测与自动安装 |
| `--uninstall` | 停止并移除服务单元（保留站点文件） |
| `--purge` | 卸载并删除后端二进制等（配合 `--site-root`；`--yes` 时可删默认 `data/`） |
| `--help` / `-h` | 帮助 |

---

## 环境变量

| 变量 | 说明 |
|------|------|
| `PORT` | 后端监听端口（同 `--port`） |
| `AUTO_PRO_DATA_DIR` | 数据目录（同 `--data-dir`） |
| `SOFTWARE_SOURCE_ADMIN_KEY` | 软件源管理密钥。由 auth_pro 进程读取；请写入 systemd `Environment=` 或 supervisor `environment`，**不要**放进可被 Web 访问的目录 |

示例（systemd 安装后编辑单元）：

```bash
sudo systemctl edit auth-pro
# 添加:
# [Service]
# Environment=SOFTWARE_SOURCE_ADMIN_KEY=你的密钥
sudo systemctl restart auth-pro
```

---

## Nginx

示例片段见 [`examples/nginx.conf.snippet`](examples/nginx.conf.snippet)。

在宝塔：网站 → 对应站点 → 配置文件，将 `/api/` 反代到 `http://127.0.0.1:19127`（或你设置的端口）。静态 `index.html` / `assets/` 由站点根目录直接提供。

本仓库**不会**在宝塔上强制 `apt/yum install nginx`，以免与面板自带 Nginx/OpenResty 冲突。若检测不到 Nginx，请到面板「软件商店」安装。

---

## 进程管理示例

- systemd：[`examples/auth-pro.service`](examples/auth-pro.service)
- supervisor：[`examples/auth-pro.supervisor.conf`](examples/auth-pro.supervisor.conf)

常用命令：

```bash
# systemd
sudo systemctl status auth-pro
sudo systemctl restart auth-pro
sudo journalctl -u auth-pro -f

# supervisor
sudo supervisorctl status auth-pro
sudo supervisorctl restart auth-pro
```

卸载：

```bash
sudo bash install.sh --uninstall
# 或清理后端文件:
sudo bash install.sh --site-root /www/wwwroot/你的站点 --purge --yes
```

---

## 数据库

请在 **宝塔面板 → 数据库** 中创建 MySQL/MariaDB 库与用户，并按 auth_pro 项目文档配置连接。

本脚本**不会**自动安装或初始化数据库服务。

---

## 安全建议

1. 对外只暴露 Nginx 的 80/443；后端端口仅监听本机或内网。
2. `SOFTWARE_SOURCE_ADMIN_KEY` 仅放在服务环境变量中，勿提交到 Git、勿写入前端。
3. 站点目录避免 `777`；`backend/auth_pro` 保持可执行即可。
4. 使用 HTTPS（宝塔可申请 Let’s Encrypt）。
5. 定期备份 `AUTO_PRO_DATA_DIR` 与数据库。

---

## 目录结构

```text
auth-pro-baota-deploy/
├── install.sh              # 主入口（可执行）
├── bt-deploy.sh            # 可选：列出 /www/wwwroot 并调用 install.sh
├── lib/deps.sh             # 依赖检测与自动安装
├── examples/
│   ├── nginx.conf.snippet
│   ├── auth-pro.service
│   └── auth-pro.supervisor.conf
├── README.md
└── LICENSE                 # MIT
```

---

## 许可证

MIT License © 2026 zxcvbnm25
