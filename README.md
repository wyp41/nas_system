# NAS System

用 Cloudflare Access + rclone，通过 SSH 密码访问远端目录。支持 macOS Finder / Windows 资源管理器挂载、按需缓存和后台上传；macOS 另有本地编辑和菜单栏上传进度。

## 安装

先由管理员完成一次 [Cloudflare 网页端配置](docs/server-setup.md)，再下载本仓库、进入项目目录运行：

| macOS | Windows 10/11 |
| --- | --- |
| `zsh Mac/setup.sh` | `.\Windows\install-windows.cmd` |
| 需先安装 [Homebrew](https://brew.sh)（按提示安装命令行开发工具） | 使用普通权限 PowerShell；安装 WinFsp / OpenSSH 时会弹出 UAC |

首次运行只需填写 **NAS 域名、SSH 用户、远端目录**，LAB 域名可留空。脚本会安装缺失依赖、打开 Cloudflare 登录、保存 SSH 密码、显示服务器公钥指纹供核对，并配置登录后自动挂载。

默认挂载位置：macOS `~/Desktop/nas`，Windows `Z:`。安装后可直接使用文件管理器，或执行 `ssh nas`；填写了 LAB 域名时也可执行 `ssh lab`。

密码由 macOS 钥匙串 / Windows 当前用户 DPAPI 保护，不写入项目配置。Cloudflare 登录和服务器 SSH 密码是两层独立验证。

## 配置

首次运行自动生成根目录的 `config.json`，两端共用，且已被 Git 忽略。也可复制 [config.example.json](config.example.json) 后修改。更改配置或更新代码后，重新运行安装命令即可生效。

| 字段 | 含义 / 默认值 |
| --- | --- |
| `nasHost`、`sshUser`、`remotePath` | 必填：NAS 域名、SSH 用户、远端绝对路径 |
| `labHost` | 可选的 LAB 域名，留空则只配置 NAS |
| `macMountPoint` / `windowsMountDrive` | `~/Desktop/nas` / `Z:` |
| `localWorkDir` | Mac 本地编辑目录，默认 `~/Documents/NAS Local Edit` |
| `preferredWorkDir` | 可选优先目录，例如 `/Volumes/Work/NAS`；已存在且可写才使用，否则回退到 `localWorkDir` |
| `tunnelPort` | 本机 TCP 桥接端口，默认 `22022`；占用时可修改 |

指定其他配置文件：

```sh
# macOS
zsh Mac/setup.sh --config /path/to/config.json
```
```powershell
# Windows
.\Windows\install-windows.cmd -ConfigPath C:\path\to\config.json
```

更新 SSH 密码：Mac 加 `--reset-password`，Windows 加 `-ResetNasPassword`；跳过已有的 Access 登录：分别加 `--skip-access-login` / `-SkipAccessLogin`。

## 文件与本地编辑

- 挂载目录按需读取；写入先进入本机 VFS 缓存，文件关闭并空闲 5 秒后上传。拖到普通本地目录会得到独立副本。
- 已同步缓存超过 30 天未使用，或磁盘剩余不足 10 GiB 时，可被自动清理。缓存使用固定密码指纹，重启会复用；未上传的修改应保留到同步完成。
- Mac 编辑 PPT 等文件：右键 NAS 文件 → **快速操作 → NAS 本地编辑**。首次完整下载，以后复用本地副本；保存写本地，静止 20 秒后后台上传，断网会重试，远端冲突会先保留冲突副本。
- Mac 菜单栏图标显示本地编辑的上传进度，也可打开工作区和日志。离线时直接打开工作区已有文件。不要同时编辑挂载原文件和本地副本。
- 本地工作副本不会自动删除。确认上传完成后可手动删除；VFS 缓存不等于永久离线保留。

Finder 未显示快速操作时，在 **系统设置 → 键盘 → 键盘快捷键 → 服务 → 文件和文件夹** 中启用 **NAS 本地编辑**。

## 管理与排查

| 操作 | macOS | Windows |
| --- | --- | --- |
| 查看状态 | `zsh Mac/nas-mount.sh status` | `.\Windows\nas-mount.cmd status` |
| 重启 / 停止 / 日志 | 将 `status` 改为 `restart` / `stop` / `logs` | 同左 |
| 日志 | `~/Library/Logs/rclone-nas` | `%LOCALAPPDATA%\rclone-nas\logs` |
| 缓存 | `~/Library/Caches/rclone-nas` | `%LOCALAPPDATA%\rclone-nas\cache` |
| 已安装配置和运行程序 | `~/Library/Application Support/rclone-nas` | `%LOCALAPPDATA%\Programs\rclone-nas` |

连接失败先检查 [Cloudflare Tunnel 和 Access 策略](docs/server-setup.md)，再看日志。Windows 挂载盘不可见时，从普通权限 PowerShell 执行 `restart`。

重装保留缓存和本地编辑记录；发现挂载缓存仍有待上传修改时会停止升级，需先恢复旧挂载、关闭文件并等待上传完成。首次从旧版升级会重新确认密码和服务器指纹，旧缓存不自动删除。Mac 已有本地编辑记录时，切换远端前需先确认上传完成并备份、移走记录。

SSH 配置仅维护带 `RCLONE-CLOUDFLARE MANAGED HOSTS` 标记的区块，其他条目保留，改写前自动备份。

开发检查：`zsh scripts/check.sh`（安装了 `pwsh` 时同时检查 Windows 脚本；不会启动服务）。
