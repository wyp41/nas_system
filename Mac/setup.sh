#!/bin/zsh

set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly REMOTE_NAME="nas"
readonly REMOTE_USER="wyp"
readonly REMOTE_PATH="/home/wyp/disk/data/storage"
readonly MOUNT_POINT="$HOME/Desktop/nas"
readonly CACHE_DIR="$HOME/Library/Caches/rclone-nas"
readonly LOG_DIR="$HOME/Library/Logs/rclone-nas"
readonly RUNTIME_DIR="$HOME/Library/Application Support/rclone-nas"
readonly RUNTIME_SCRIPT="$RUNTIME_DIR/nas-mount.sh"
readonly KNOWN_HOSTS_FILE="$RUNTIME_DIR/known_hosts"
readonly KEYCHAIN_SERVICE="rclone-nas-sftp"
readonly KEYCHAIN_ACCOUNT="wyp@nas"
readonly LEGACY_KEYCHAIN_ACCOUNT="wyp@server.wyp.life:6100"
readonly LABEL="com.wyp.rclone-nas"
readonly PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
readonly DOMAIN="gui/$(id -u)"

if ! command -v rclone >/dev/null 2>&1; then
  print -u2 "未找到 rclone，请先执行：brew install rclone"
  exit 1
fi

mkdir -p "$MOUNT_POINT" "$CACHE_DIR" "$LOG_DIR" "$RUNTIME_DIR" "$HOME/Library/LaunchAgents"

if /usr/bin/security find-generic-password \
  -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" -w >/dev/null 2>&1; then
  active_keychain_account="$KEYCHAIN_ACCOUNT"
  password_exists=true
elif /usr/bin/security find-generic-password \
  -a "$LEGACY_KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" -w >/dev/null 2>&1; then
  active_keychain_account="$LEGACY_KEYCHAIN_ACCOUNT"
  password_exists=true
else
  active_keychain_account="$KEYCHAIN_ACCOUNT"
  password_exists=false
fi

if [[ "${1:-}" == "--reset-password" ]] || [[ "$password_exists" == false ]]; then
  print "请输入 $KEYCHAIN_ACCOUNT 的 SSH 密码（输入时不会显示）："
  /usr/bin/security add-generic-password \
    -a "$KEYCHAIN_ACCOUNT" \
    -s "$KEYCHAIN_SERVICE" \
    -l "rclone NAS SFTP" \
    -U \
    -w
  active_keychain_account="$KEYCHAIN_ACCOUNT"
else
  print "正在复用 macOS 登录钥匙串中的 SSH 密码"
fi

/usr/bin/install -m 600 "$SCRIPT_DIR/known_hosts" "$KNOWN_HOSTS_FILE"

config_args=(
  host 127.0.0.1
  user "$REMOTE_USER"
  port 22022
  known_hosts_file "$KNOWN_HOSTS_FILE"
  shell_type unix
)

if rclone listremotes | grep -Fxq "$REMOTE_NAME:"; then
  rclone config update "$REMOTE_NAME" "${config_args[@]}" --non-interactive
else
  rclone config create "$REMOTE_NAME" sftp "${config_args[@]}" --non-interactive
fi

password="$(/usr/bin/security find-generic-password \
  -a "$active_keychain_account" -s "$KEYCHAIN_SERVICE" -w)"
export RCLONE_CONFIG_NAS_PASS
RCLONE_CONFIG_NAS_PASS="$(printf '%s\n' "$password" | rclone obscure -)"
unset password

/usr/bin/install -m 755 "$SCRIPT_DIR/nas-mount.sh" "$RUNTIME_SCRIPT"

escaped_script="${RUNTIME_SCRIPT//&/\\&}"
escaped_log="${LOG_DIR//&/\\&}"
sed \
  -e "s|__SCRIPT_PATH__|$escaped_script|g" \
  -e "s|__LOG_DIR__|$escaped_log|g" \
  "$SCRIPT_DIR/com.wyp.rclone-nas.plist.template" > "$PLIST"
plutil -lint "$PLIST" >/dev/null
chmod 600 "$PLIST"

if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "$DOMAIN/$LABEL"
  sleep 1
fi
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl kickstart -k "$DOMAIN/$LABEL"

for _ in {1..15}; do
  if mount | grep -Fq " on $MOUNT_POINT "; then
    print "完成：NAS 已挂载到 $MOUNT_POINT"
    exit 0
  fi
  sleep 1
done

print -u2 "服务已安装，但挂载未在 15 秒内完成。请查看：$LOG_DIR/rclone.log"
exit 1
