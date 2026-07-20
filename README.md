# NAS System

通过 Cloudflare Access 与 SSH/SFTP 访问 `nas`、`lab` 的跨平台部署脚本。

## 选择平台

| 平台 | 入口 | 功能 |
| --- | --- | --- |
| macOS | [Mac/README.md](Mac/README.md) | 安装并配置 NAS SFTP、VFS 缓存、桌面挂载和 launchd 自动启动 |
| Windows | [Windows/README.md](Windows/README.md) | 安装 cloudflared、rclone、OpenSSH Client，并配置 `ssh nas`、`ssh lab` |

密码不会写入仓库：macOS 使用登录钥匙串，Windows SSH 在连接时交互输入服务器密码。

## SSH 别名

- `nas` → `nas.wyp.life`
- `lab` → `lab.wyp.life`

两个入口均通过 `cloudflared access ssh` 或本机 Cloudflare TCP 桥接访问服务器。
