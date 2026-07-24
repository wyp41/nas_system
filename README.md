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

## NAS 服务端设置

以下配置以 Debian/Ubuntu 为例。客户端当前固定使用：

- SSH 用户：`wyp`
- NAS 域名：`nas.wyp.life`
- 远端目录：`/home/wyp/disk/data/storage`
- 验证方式：Cloudflare Access 身份验证 + NAS SSH 密码

因此，其他人部署本仓库后若不修改客户端脚本，也会以同一个 Linux 用户 `wyp` 读写同一目录。

### 1. 准备 SSH 用户和存储目录

在 NAS 上执行：

```bash
sudo apt update
sudo apt install openssh-server

id wyp || sudo adduser wyp
```

首次配置或需要轮换密码时，执行 `sudo passwd wyp`。如果 `/home/wyp/disk/data` 是单独挂载的数据盘，先确认数据盘已经挂载，再创建存储目录，避免把文件误写到系统盘：

```bash
findmnt /home/wyp/disk/data
sudo install -d -m 0750 -o wyp -g wyp /home/wyp/disk/data/storage
namei -l /home/wyp/disk/data/storage
```

不要在不了解现有文件归属时直接递归执行 `chown`。已有文件需要保证 `wyp` 对相应目录具有读、写和进入权限。

### 2. 启用 SSH 密码验证

确认 `/etc/ssh/sshd_config` 或 `/etc/ssh/sshd_config.d/` 中启用了：

```sshconfig
PasswordAuthentication yes
```

验证配置并重新启动 SSH：

```bash
sudo sshd -t
sudo systemctl restart ssh
sudo sshd -T -C user=wyp,host=localhost,addr=127.0.0.1 | grep passwordauthentication
sudo ss -ltnp | grep ':22'
```

最后两条命令应分别显示 `passwordauthentication yes` 和 SSH 正在监听 22 端口。先在 NAS 本机验证密码登录，确认成功后再继续：

```bash
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no wyp@localhost
```

### 3. 在 NAS 上运行 Cloudflare Tunnel

1. 登录 Cloudflare Zero Trust 控制台，进入 **Networks → Tunnels**。
2. 新建一个 tunnel，或选择 NAS 已在使用的 tunnel。
3. 按控制台显示的 Linux 安装命令，在 NAS 上安装 `cloudflared` 并注册服务。命令中的 tunnel token 属于机密，不要写入本仓库或发送给访问者。
4. 在 tunnel 的 **Routes** 中添加 **Published application**：
   - Hostname：`nas.wyp.life`
   - Service type：`SSH`
   - URL：`localhost:22`
5. 检查服务和 tunnel 状态：

```bash
sudo systemctl enable --now cloudflared
sudo systemctl status cloudflared
sudo journalctl -u cloudflared -n 100 --no-pager
```

如果同一台 NAS 已经运行 `cloudflared` 服务，不要再安装第二个服务，直接向现有 tunnel 添加 route。Cloudflare Tunnel 是由 NAS 主动向外建立连接，因此无需在路由器上映射公网 22 端口；若不需要局域网直连，也不应向公网开放 22 端口。

Cloudflare 官方参考：[创建 Tunnel](https://developers.cloudflare.com/tunnel/setup/)、[通过客户端 cloudflared 连接 SSH](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/use-cases/ssh/ssh-cloudflared-authentication/)。

### 4. 建立 Cloudflare Access 应用

1. 在 Cloudflare Zero Trust 控制台进入 **Access → Applications**。
2. 新建 **Self-hosted** 应用，应用域名填写 `nas.wyp.life`。
3. 建立 **Allow** policy，只加入允许访问 NAS 的邮箱、邮箱域名或身份提供商群组。
4. 不要使用无条件的 `Everyone` 放行规则。

Cloudflare Access 决定“谁可以到达 SSH 服务”，NAS 的 SSH 密码决定“到达后能否登录”。两层都通过后，客户端才能连接。

`lab.wyp.life` 如需提供给其他人，使用相同流程为它添加 tunnel route 和独立的 Access 应用。

### 5. 新增一个访问者

1. 将对方的 Cloudflare 登录身份加入 `nas.wyp.life` 的 Access Allow policy。
2. 让对方克隆本仓库并按 [Mac/README.md](Mac/README.md) 或 [Windows/README.md](Windows/README.md) 部署。
3. 通过安全渠道单独提供 `wyp` 的 SSH 密码，不要写入 GitHub、聊天记录或部署脚本。
4. macOS 用户先安装 `rclone` 和 `cloudflared`，执行 `cloudflared access login https://nas.wyp.life`，再运行 `Mac/setup.sh`；密码会存入其本机登录钥匙串并用于自动挂载。当前 Mac 脚本使用 Apple Silicon Homebrew 路径 `/opt/homebrew/bin/cloudflared`。
5. Windows 用户运行部署程序，然后执行 `ssh nas`，完成 Cloudflare 验证并输入 SSH 密码。

Windows 部署程序默认会依次登录 `nas.wyp.life` 和 `lab.wyp.life`。管理员应将 Windows 用户同时加入两个 Access 应用；如果不准备开放 `lab`，可在 PowerShell 中执行：

```powershell
.\Windows\install-windows.cmd -SkipAccessLogin
& "$env:LOCALAPPDATA\Programs\cloudflared\cloudflared.exe" access login https://nas.wyp.life
ssh nas
```

### 6. 验证和撤销访问

Windows 客户端按顺序验证：

```powershell
cloudflared access login https://nas.wyp.life
ssh nas
```

macOS 客户端用 `./Mac/nas-mount.sh status` 验证挂载；该平台当前不会自动写入 `ssh nas` 别名。

连接失败时，依次检查：

- Cloudflare 控制台中的 tunnel 是否为 Healthy。
- `nas.wyp.life` 的 route 是否指向 `SSH localhost:22`。
- 访问者身份是否被 Access policy 放行。
- NAS 上 `cloudflared` 与 `ssh` 服务是否正常。
- `wyp` 密码和 `/home/wyp/disk/data/storage` 权限是否正确。

撤销某人的访问时，先从 Access policy 中移除其身份。因为当前部署由多人共用 `wyp`，如果密码可能泄露，或对方还能通过局域网直接连接 NAS，还应执行 `sudo passwd wyp` 轮换密码，并让仍获授权的 macOS 用户重新运行 `./setup.sh --reset-password`。

共用账户适合可信的小范围用户，但无法按人区分文件权限和 SSH 审计记录。需要独立账户时，应为每人创建 Linux 用户或受限 SFTP 账户，并同步修改客户端中的 SSH 用户及远端路径。

macOS 客户端还会校验仓库中 [Mac/known_hosts](Mac/known_hosts) 保存的 NAS SSH 主机公钥。重装 SSH 服务或更换 NAS 后若主机公钥发生变化，需要先核对新指纹，再更新该文件并让所有 macOS 客户端重新运行 `setup.sh`；不要为了绕过报错而关闭主机密钥校验。
