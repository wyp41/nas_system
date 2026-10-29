#!/bin/zsh

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
readonly SCRIPT_DIR="${0:A:h}"
CONFIG_PATH="$SCRIPT_DIR/../config.json"
config_given=false
reset_password=false
skip_access_login=false
while (( $# )); do
  case "$1" in
    --config) CONFIG_PATH="${2:?--config 需要指定 JSON 文件}"; config_given=true; shift 2 ;;
    --reset-password) reset_password=true; shift ;;
    --skip-access-login) skip_access_login=true; shift ;;
    -h|--help)
      print "用法：$0 [--config 文件] [--reset-password] [--skip-access-login]"
      exit 0 ;;
    *) print -u2 "未知参数：$1"; exit 2 ;;
  esac
done

if [[ ! -f "$CONFIG_PATH" ]]; then
  if [[ "$config_given" == false && -f "$HOME/Library/Application Support/rclone-nas/config.json" ]]; then
    /bin/cp "$HOME/Library/Application Support/rclone-nas/config.json" "$CONFIG_PATH"
  else
    print "首次配置（直接回车可跳过可选项）"
    read -r "nas_host?NAS 域名，例如 nas.example.com："
    read -r "ssh_user?SSH 用户名："
    read -r "remote_path?远端目录，例如 /home/user/storage："
    read -r "lab_host?LAB 域名（可选）："
    /usr/bin/plutil -create xml1 "$CONFIG_PATH"
    for key value in nasHost "$nas_host" sshUser "$ssh_user" remotePath "$remote_path" labHost "$lab_host"; do
      /usr/bin/plutil -insert "$key" -string "$value" "$CONFIG_PATH"
    done
    /usr/bin/plutil -convert json "$CONFIG_PATH"
  fi
fi
NAS_CONFIG_FILE="${CONFIG_PATH:A}"
source "$SCRIPT_DIR/nas-common.sh"

missing=()
for program in rclone cloudflared; do
  command -v "$program" >/dev/null 2>&1 || missing+=("$program")
done
if (( ${#missing} )); then
  if ! command -v brew >/dev/null 2>&1; then
    print -u2 "请先安装 Homebrew（https://brew.sh），然后重新运行本脚本。"
    exit 1
  fi
  brew install "${missing[@]}"
fi
RCLONE_BIN="$(command -v rclone)"
CLOUDFLARED_BIN="$(command -v cloudflared)"
/usr/bin/xcrun --find swiftc >/dev/null

# Do not send tracked local edits to a different server or remote directory.
if [[ -d "$STATE_DIR" && -n "$(/usr/bin/find "$STATE_DIR" -name '*.state' -print -quit)" ]]; then
  if [[ -f "$RUNTIME_DIR/config.json" ]]; then
    previous_host="$(/usr/bin/plutil -extract nasHost raw -o - "$RUNTIME_DIR/config.json")"
    previous_user="$(/usr/bin/plutil -extract sshUser raw -o - "$RUNTIME_DIR/config.json")"
    previous_path="$(/usr/bin/plutil -extract remotePath raw -o - "$RUNTIME_DIR/config.json")"
  else
    # Read the identity of pre-config.json installations without running their scripts.
    previous_host="$(sed -n 's/^readonly TUNNEL_HOST="\(.*\)"$/\1/p' "$RUNTIME_DIR/nas-mount.sh")"
    previous_user="$(sed -n 's/^readonly KEYCHAIN_ACCOUNT="\(.*\)@nas"$/\1/p' "$RUNTIME_DIR/nas-local-edit.sh")"
    previous_path="$(sed -n 's/^readonly REMOTE_PATH="\(.*\)"$/\1/p' "$RUNTIME_DIR/nas-local-edit.sh")"
  fi
  if [[ "$previous_host" != "$NAS_HOST" || "$previous_user" != "$SSH_USER" || "$previous_path" != "$REMOTE_PATH" ]]; then
    print -u2 "存在本地编辑记录，不能直接切换远端。请先完成上传，再备份并移走 $STATE_DIR。"
    exit 1
  fi
fi

mkdir -p "$MOUNT_POINT" "$CACHE_DIR" "$LOG_DIR" "$RUNTIME_DIR" \
  "$HOME/Library/LaunchAgents" "$HOME/Library/Services"
if [[ "$skip_access_login" == false ]]; then
  for host in "$NAS_HOST" ${LAB_HOST:+"$LAB_HOST"}; do
    "$CLOUDFLARED_BIN" access login "https://$host"
  done
fi

# Stop the old agents before replacing their runtime files.
for label in "$LABEL" com.wyp.rclone-nas-local-edit com.wyp.rclone-nas-progress; do
  if launchctl print "$DOMAIN/$label" >/dev/null 2>&1; then
    launchctl bootout "$DOMAIN/$label"
  fi
done
for _ in {1..15}; do
  /usr/bin/nc -z 127.0.0.1 "$TUNNEL_PORT" 2>/dev/null || break
  sleep 1
done
if mount | /usr/bin/grep -Fq " on $MOUNT_POINT "; then
  /sbin/umount "$MOUNT_POINT"
fi
if [[ -d "$CACHE_DIR/vfsMeta" ]] && /usr/bin/grep -RlE '"Dirty"[[:space:]]*:[[:space:]]*true' "$CACHE_DIR/vfsMeta" >/dev/null; then
  print -u2 "挂载缓存仍有待上传修改。请先用已安装的 nas-mount.sh start 恢复旧服务，关闭文件并等待上传完成，再重装。"
  exit 1
fi
if /usr/bin/nc -z 127.0.0.1 "$TUNNEL_PORT" 2>/dev/null; then
  print -u2 "本机端口 $TUNNEL_PORT 已占用，请修改配置中的 tunnelPort。"
  exit 1
fi

if [[ "$reset_password" == true ]] || ! load_password 2>/dev/null; then
  read -rs "password?请输入 ${SSH_USER}@${NAS_HOST} 的 SSH 密码（输入时不会显示）："
  print
  [[ -n "$password" ]] || { print -u2 "密码不能为空"; exit 1; }
  obscured="$(printf '%s\n' "$password" | "$RCLONE_BIN" obscure -)"
  unset password
  /usr/bin/security add-generic-password -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" \
    -l "NAS System SFTP" -U -w "$obscured" >/dev/null
  unset obscured
  load_password
fi

"$CLOUDFLARED_BIN" access tcp --hostname "$NAS_HOST" --url "127.0.0.1:$TUNNEL_PORT" \
  --logfile "$LOG_DIR/cloudflared.log" --log-level info &
tunnel_pid=$!
trap 'kill "$tunnel_pid" 2>/dev/null || true; wait "$tunnel_pid" 2>/dev/null || true' EXIT
for _ in {1..30}; do
  /usr/bin/nc -z 127.0.0.1 "$TUNNEL_PORT" 2>/dev/null && break
  kill -0 "$tunnel_pid" 2>/dev/null || { print -u2 "Tunnel 启动失败，请查看 $LOG_DIR/cloudflared.log"; exit 1; }
  sleep 1
done

if [[ ! -s "$KNOWN_HOSTS_FILE" ]]; then
  candidate="$(/usr/bin/mktemp)"
  if ! /usr/bin/ssh-keyscan -T 10 -p "$TUNNEL_PORT" 127.0.0.1 > "$candidate" 2>/dev/null || [[ ! -s "$candidate" ]]; then
    /bin/rm -f "$candidate"
    print -u2 "无法读取服务器公钥，请检查 Cloudflare 登录和 SSH 路由。"
    exit 1
  fi
  print "服务器 SSH 公钥指纹（请与管理员提供的指纹核对）："
  /usr/bin/ssh-keygen -lf "$candidate"
  read -r "confirmed?确认指纹一致并保存？[y/N] "
  if [[ "$confirmed" != [yY] ]]; then
    /bin/rm -f "$candidate"
    exit 1
  fi
  /usr/bin/install -m 600 "$candidate" "$KNOWN_HOSTS_FILE"
  /bin/rm -f "$candidate"
fi

"$RCLONE_BIN" config create nas sftp host 127.0.0.1 user "$SSH_USER" port "$TUNNEL_PORT" \
  known_hosts_file "$KNOWN_HOSTS_FILE" shell_type unix --non-interactive --quiet >/dev/null
print "正在验证 SFTP 登录和远端目录……"
"$RCLONE_BIN" lsf "nas:$REMOTE_PATH" --max-depth 1 --contimeout 10s --timeout 30s \
  --retries 1 --low-level-retries 1 >/dev/null
kill "$tunnel_pid" 2>/dev/null || true
wait "$tunnel_pid" 2>/dev/null || true
trap - EXIT

if [[ "$NAS_CONFIG_FILE" != "$RUNTIME_DIR/config.json" ]]; then
  /usr/bin/install -m 600 "$NAS_CONFIG_FILE" "$RUNTIME_DIR/config.json"
fi
for script in nas-common.sh nas-mount.sh nas-local-edit.sh; do
  /usr/bin/install -m 755 "$SCRIPT_DIR/$script" "$RUNTIME_DIR/$script"
done
/usr/bin/xcrun --sdk macosx swiftc -O -framework AppKit \
  "$SCRIPT_DIR/NASProgress.swift" -o "$RUNTIME_DIR/nas-progress-menu"
/usr/bin/ditto "$SCRIPT_DIR/NAS Local Edit.workflow" "$HOME/Library/Services/NAS Local Edit.workflow"

mkdir -p "$HOME/.ssh"
ssh_config="$HOME/.ssh/config"
managed_config="$(/usr/bin/mktemp)"
{
  print '# BEGIN RCLONE-CLOUDFLARE MANAGED HOSTS'
  for alias host in nas "$NAS_HOST" lab "$LAB_HOST"; do
    [[ -n "$host" ]] || continue
    printf 'Host %s\n    HostName %s\n    User %s\n    ProxyCommand "%s" access ssh --hostname %%h\n    PreferredAuthentications password\n    PubkeyAuthentication no\n    ServerAliveInterval 30\n    ServerAliveCountMax 3\n\n' \
      "$alias" "$host" "$SSH_USER" "$CLOUDFLARED_BIN"
  done
  print '# END RCLONE-CLOUDFLARE MANAGED HOSTS'
  if [[ -f "$ssh_config" ]]; then
    /usr/bin/sed '/^# BEGIN RCLONE-CLOUDFLARE MANAGED HOSTS$/,/^# END RCLONE-CLOUDFLARE MANAGED HOSTS$/d' "$ssh_config"
  fi
} > "$managed_config"
if ! /usr/bin/cmp -s "$managed_config" "$ssh_config"; then
  [[ ! -f "$ssh_config" ]] || /bin/cp "$ssh_config" "$ssh_config.backup-$(date +%Y%m%d-%H%M%S)"
  /usr/bin/install -m 600 "$managed_config" "$ssh_config"
fi
/bin/rm -f "$managed_config"
/usr/bin/ssh -G nas >/dev/null

for service in mount local-edit progress; do
  case "$service" in
    mount) label="$LABEL"; script=nas-mount.sh; action=run ;;
    local-edit) label=com.wyp.rclone-nas-local-edit; script=nas-local-edit.sh; action=sync ;;
    progress) label=com.wyp.rclone-nas-progress; script=nas-mount.sh; action=progress ;;
  esac
  plist="$HOME/Library/LaunchAgents/$label.plist"
  /usr/bin/install -m 600 "$SCRIPT_DIR/launch-agent.plist.template" "$plist"
  /usr/bin/plutil -replace Label -string "$label" "$plist"
  /usr/bin/plutil -replace ProgramArguments.1 -string "$RUNTIME_DIR/$script" "$plist"
  /usr/bin/plutil -replace ProgramArguments.2 -string "$action" "$plist"
  /usr/bin/plutil -replace StandardOutPath -string "$LOG_DIR/$service.out.log" "$plist"
  /usr/bin/plutil -replace StandardErrorPath -string "$LOG_DIR/$service.err.log" "$plist"
  launchctl bootstrap "$DOMAIN" "$plist"
done
/System/Library/CoreServices/pbs -flush 2>/dev/null || true
for _ in {1..30}; do
  if mount | /usr/bin/grep -Fq " on $MOUNT_POINT "; then
    print "完成：NAS 已挂载到 $MOUNT_POINT；SSH 连接：ssh nas"
    exit 0
  fi
  sleep 1
done
print -u2 "服务已安装，挂载尚未就绪。请查看：$LOG_DIR/rclone.log"
exit 1
