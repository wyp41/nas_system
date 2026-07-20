# NAS System

通过 Cloudflare Access 与 SSH/SFTP 访问 `nas`、`lab` 的跨平台部署脚本。

## 选择平台

| 平台 | 入口 | 功能 |
| --- | --- | --- |
| macOS | [Mac/README.md](Mac/README.md) | 安装并配置 NAS SFTP、VFS 缓存、桌面挂载和 launchd 自动启动 |
| Windows | [Windows/README.md](Windows/README.md) | 安装 cloudflared、rclone、WinFsp、OpenSSH Client，配置 SSH，并将 NAS 挂载到 `Z:` |

密码不会写入仓库：macOS 使用登录钥匙串；Windows 挂载密码由当前用户的 DPAPI 加密保存，交互式 SSH 连接仍会单独询问密码。

## SSH 别名

- `nas` → `nas.wyp.life`
- `lab` → `lab.wyp.life`

两个入口均通过 `cloudflared access ssh` 或本机 Cloudflare TCP 桥接访问服务器。
