# Windows 部署

适用于 Windows 10（1809 及以上）、Windows 11 和 Windows Server 2019 及以上，要求 PowerShell 5.1 或更高版本。

## 自动完成的操作

1. 检查 `cloudflared.exe`。若不存在，从 Cloudflare 官方 GitHub 最新发行版下载，并校验发行资产的 SHA-256。
2. 默认依次执行 `cloudflared access login https://nas.wyp.life` 和 `https://lab.wyp.life`，浏览器会打开 Cloudflare Access 登录页面。
3. 检查 `rclone.exe`。若不存在，从 `downloads.rclone.org` 下载当前 Windows 版本，并用官方 `SHA256SUMS` 校验。
4. 检查并安装 rclone 挂载盘符所需的 WinFsp；首次安装会显示 Windows UAC 确认框。
5. 检查 Windows OpenSSH Client；缺失时会在管理员 PowerShell 中安装 Windows 可选组件。
6. 在 `%USERPROFILE%\.ssh\config` 顶部写入受管理的 `nas`、`lab` 配置，保留其他 SSH 配置并在修改前建立时间戳备份。
7. 配置 SFTP remote，将 `/home/wyp/disk/data/storage` 挂载到 `Z:`，并在当前用户登录后自动启动。
8. 用 `ssh -G` 验证两个别名可被 OpenSSH 正确解析。

程序安装在当前用户目录，无需修改 `C:\Windows`：

- `%LOCALAPPDATA%\Programs\cloudflared\cloudflared.exe`
- `%LOCALAPPDATA%\Programs\rclone\rclone.exe`
- `%LOCALAPPDATA%\Programs\rclone-nas\Nas-Mount.ps1`

## 运行

在 Windows Terminal 或 PowerShell 中进入本目录，然后执行：

```powershell
.\install-windows.cmd
```

也可以直接运行 PowerShell 脚本：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-RcloneCloudflare.ps1
```

首次运行会要求输入一次 `wyp@nas` 的 SSH 密码。密码通过当前 Windows 用户的 DPAPI 加密后保存，不会以明文写入 rclone 配置。

Cloudflare Access 登录仍有效、只想重复检查安装和刷新 SSH 配置时：

```powershell
.\install-windows.cmd -SkipAccessLogin
```

服务器 SSH 密码发生变化时，重新输入并更新：

```powershell
.\install-windows.cmd -SkipAccessLogin -ResetNasPassword
```

如果脚本提示缺少 OpenSSH Client，请右键 Windows Terminal 或 PowerShell，选择“以管理员身份运行”，再执行一次。

## 使用

```powershell
ssh nas
ssh lab
rclone version
cloudflared --version
```

NAS 默认挂载为资源管理器中的 `Z:`。挂载请从普通用户 PowerShell 启动；管理员进程创建的盘符通常不会显示在普通权限的资源管理器中。

## 管理 NAS 挂载

```powershell
.\nas-mount.cmd status
.\nas-mount.cmd stop
.\nas-mount.cmd start
.\nas-mount.cmd restart
.\nas-mount.cmd logs
```

日志位于 `%LOCALAPPDATA%\rclone-nas\logs`，VFS 缓存位于 `%LOCALAPPDATA%\rclone-nas\cache`。读取过的远端文件最多缓存 30 天；磁盘剩余空间低于 10 GiB 时，会优先清理最久未使用的缓存。

SSH 连接仍使用服务器密码验证；Cloudflare Access 登录和 SSH 密码验证是两个独立步骤。

## 写入的 SSH 配置

程序在 `%USERPROFILE%\.ssh\config` 顶部维护以下标记区块，重复执行不会产生重复条目：

```sshconfig
# BEGIN RCLONE-CLOUDFLARE MANAGED HOSTS
Host nas
    HostName nas.wyp.life
    User wyp
    ProxyCommand ".../cloudflared.exe" access ssh --hostname %h
    PreferredAuthentications password
    PubkeyAuthentication no
    ServerAliveInterval 30
    ServerAliveCountMax 3

Host lab
    HostName lab.wyp.life
    User wyp
    ProxyCommand ".../cloudflared.exe" access ssh --hostname %h
    PreferredAuthentications password
    PubkeyAuthentication no
    ServerAliveInterval 30
    ServerAliveCountMax 3
# END RCLONE-CLOUDFLARE MANAGED HOSTS
```

若要恢复部署前的 SSH 配置，可使用同目录下的 `config.backup-年月日-时分秒` 文件。
