# macOS NAS 挂载

远端 SFTP 目录会通过 Cloudflare Tunnel 自动挂载到 `~/Desktop/nas`，登录后由 launchd 自动启动。

## 首次初始化

```bash
cd ~/Desktop/Scripts/rclone/Mac
./setup.sh
```

脚本会要求输入一次 SSH 密码，并把它保存到 macOS 登录钥匙串；密码不会写入本目录或 rclone 配置文件。初始化完成后，可直接在 Finder 中使用桌面上的 `nas` 文件夹。

如果服务器密码发生变化，可重新输入并更新钥匙串：

```bash
./setup.sh --reset-password
```

## 文件行为

- 在 `nas` 中新建、修改或拖入文件：先写入本机 VFS 缓存，文件关闭 5 秒后自动上传远端。
- 从 `nas` 拖到桌面、下载目录或其他本地目录：创建一份独立的本地副本，不受后续远端变化影响。
- 读取过的远端内容会在本机缓存最长 30 天；磁盘剩余空间低于 10 GiB 时，rclone 会优先清理最久未使用的已同步缓存。
- 上传失败的更改会保留在缓存中，服务恢复并使用同一缓存目录启动后继续重试。退出登录或关机前，仍建议先确认日志中没有待上传错误。

VFS 缓存并不是“永久离线保留”。需要长期离线保存的文件，请从 `nas` 拖到普通本地目录。

## 管理命令

```bash
./nas-mount.sh status
./nas-mount.sh stop
./nas-mount.sh start
./nas-mount.sh restart
./nas-mount.sh logs
```

日志位于 `~/Library/Logs/rclone-nas/`，缓存位于 `~/Library/Caches/rclone-nas`。
launchd 使用的运行副本位于 `~/Library/Application Support/rclone-nas`，以避开 macOS 对后台进程读取桌面目录的限制。

## 当前连接配置

- 挂载点：`~/Desktop/nas`
- SSH 别名：`nas`（`nas.wyp.life`，Cloudflare Tunnel）
- 远端路径：`/home/wyp/disk/data/storage`
- 本机桥接：`127.0.0.1:22022`
- rclone remote 名称：`nas`
- 验证：密码（保存在 macOS 登录钥匙串）
