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
- rclone 使用钥匙串中固定的密码指纹复用同一个 VFS 缓存空间，重启挂载不会再生成多个 `nas{…}` 缓存副本。
- 上传失败的更改会保留在缓存中，服务恢复并使用同一缓存目录启动后继续重试。退出登录或关机前，仍建议先确认日志中没有待上传错误。

VFS 缓存并不是“永久离线保留”。需要长期离线保存的文件，请从 `nas` 拖到普通本地目录。

## 本地编辑

初始化后，在 Finder 中右键 `~/Desktop/nas` 里的文件，选择 **快速操作 → NAS 本地编辑**：

1. U 盘可用时，文件会完整下载到 `/Volumes/data/PhD`；该目录不存在或不可写时，自动改用 `~/Documents/NAS Local Edit`。PowerPoint 等应用打开的是真正的本地文件。
2. 保存操作只写入本机磁盘；文件停止变化 20 秒后，后台服务静默上传到原 NAS 路径。
3. 断网时修改继续保留在本地，连接恢复后自动重试。
4. 如果上传前检测到远端文件已被其他设备修改，程序会先在远端保存带 `remote conflict` 时间戳的副本，再上传本地版本。

菜单栏中的 **NAS** 图标会显示后台上传状态：上传时显示文件名和百分比，点开可查看进度条；成功后显示勾，失败则显示警告并由后台服务自动重试。菜单中也可以打开当前本地工作区和同步日志。

程序不会在 U 盘离线时创建 `/Volumes/data/PhD`。每个文件会记录当前本地副本的实际位置，因此插拔 U 盘不会让后台同步误用另一份同名文件。

如果文件先在回退目录中编辑，重新连接 U 盘后再次使用 **NAS 本地编辑** 打开它：只要该副本已经上传完成且 U 盘中没有同名文件，程序会把它安全移到 `/Volumes/data/PhD`；仍有待上传修改时不会移动。

第一次使用某个文件时必须联网完成下载。以后请继续通过 **NAS 本地编辑** 打开，或直接在当前工作目录中打开本地副本。不要同时编辑 NAS 挂载中的原文件和本地副本。

如果 Finder 中没有显示该操作，请前往 **系统设置 → 键盘 → 键盘快捷键 → 服务 → 文件和文件夹**，启用 **NAS 本地编辑**。

打开本地工作区：

```bash
~/Library/Application\ Support/rclone-nas/nas-local-edit.sh reveal
```

同步日志位于 `~/Library/Logs/rclone-nas/local-edit.log`。在日志出现“上传完成”之前不要删除本地工作副本。

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
