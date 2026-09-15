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
readonly LOCAL_EDIT_SCRIPT="$RUNTIME_DIR/nas-local-edit.sh"
readonly PROGRESS_APP="$RUNTIME_DIR/nas-progress-menu"
readonly KNOWN_HOSTS_FILE="$RUNTIME_DIR/known_hosts"
readonly KEYCHAIN_SERVICE="rclone-nas-sftp"
readonly KEYCHAIN_ACCOUNT="wyp@nas"
readonly LEGACY_KEYCHAIN_ACCOUNT="wyp@server.wyp.life:6100"
readonly OBSCURED_KEYCHAIN_ACCOUNT="wyp@nas:rclone-obscured"
readonly LABEL="com.wyp.rclone-nas"
readonly PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
readonly LOCAL_EDIT_LABEL="com.wyp.rclone-nas-local-edit"
readonly LOCAL_EDIT_PLIST="$HOME/Library/LaunchAgents/$LOCAL_EDIT_LABEL.plist"
readonly PROGRESS_LABEL="com.wyp.rclone-nas-progress"
readonly PROGRESS_PLIST="$HOME/Library/LaunchAgents/$PROGRESS_LABEL.plist"
readonly LOCAL_EDIT_WORKFLOW="$HOME/Library/Services/NAS Local Edit.workflow"
readonly DOMAIN="gui/$(id -u)"

if ! command -v rclone >/dev/null 2>&1; then
  print -u2 "未找到 rclone，请先执行：brew install rclone"
  exit 1
fi

mkdir -p "$MOUNT_POINT" "$CACHE_DIR" "$LOG_DIR" "$RUNTIME_DIR" \
  "$HOME/Library/LaunchAgents" "$HOME/Library/Services"

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

password_changed=false
if [[ "${1:-}" == "--reset-password" ]] || [[ "$password_exists" == false ]]; then
  print "请输入 $KEYCHAIN_ACCOUNT 的 SSH 密码（输入时不会显示）："
  /usr/bin/security add-generic-password \
    -a "$KEYCHAIN_ACCOUNT" \
    -s "$KEYCHAIN_SERVICE" \
    -l "rclone NAS SFTP" \
    -U \
    -w
  active_keychain_account="$KEYCHAIN_ACCOUNT"
  password_changed=true
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

export RCLONE_CONFIG_NAS_PASS
if [[ "$password_changed" == true ]] || ! RCLONE_CONFIG_NAS_PASS="$(/usr/bin/security find-generic-password \
  -a "$OBSCURED_KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null)"; then
  password="$(/usr/bin/security find-generic-password \
    -a "$active_keychain_account" -s "$KEYCHAIN_SERVICE" -w)"
  RCLONE_CONFIG_NAS_PASS="$(printf '%s\n' "$password" | rclone obscure -)"
  /usr/bin/security add-generic-password \
    -a "$OBSCURED_KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" \
    -l "rclone NAS stable obscured password" -U -w "$RCLONE_CONFIG_NAS_PASS" >/dev/null
  unset password
fi

/usr/bin/install -m 755 "$SCRIPT_DIR/nas-mount.sh" "$RUNTIME_SCRIPT"
/usr/bin/install -m 755 "$SCRIPT_DIR/nas-local-edit.sh" "$LOCAL_EDIT_SCRIPT"
/usr/bin/xcrun --sdk macosx swiftc -O -framework AppKit \
  "$SCRIPT_DIR/NASProgress.swift" -o "$PROGRESS_APP"
/usr/bin/ditto "$SCRIPT_DIR/NAS Local Edit.workflow" "$LOCAL_EDIT_WORKFLOW"

escaped_script="${RUNTIME_SCRIPT//&/\\&}"
escaped_log="${LOG_DIR//&/\\&}"
sed \
  -e "s|__SCRIPT_PATH__|$escaped_script|g" \
  -e "s|__LOG_DIR__|$escaped_log|g" \
  "$SCRIPT_DIR/com.wyp.rclone-nas.plist.template" > "$PLIST"
plutil -lint "$PLIST" >/dev/null
chmod 600 "$PLIST"

escaped_local_edit_script="${LOCAL_EDIT_SCRIPT//&/\\&}"
sed \
  -e "s|__SCRIPT_PATH__|$escaped_local_edit_script|g" \
  -e "s|__LOG_DIR__|$escaped_log|g" \
  "$SCRIPT_DIR/com.wyp.rclone-nas-local-edit.plist.template" > "$LOCAL_EDIT_PLIST"
plutil -lint "$LOCAL_EDIT_PLIST" >/dev/null
chmod 600 "$LOCAL_EDIT_PLIST"

escaped_progress_app="${PROGRESS_APP//&/\\&}"
sed \
  -e "s|__APP_PATH__|$escaped_progress_app|g" \
  -e "s|__LOG_DIR__|$escaped_log|g" \
  "$SCRIPT_DIR/com.wyp.rclone-nas-progress.plist.template" > "$PROGRESS_PLIST"
plutil -lint "$PROGRESS_PLIST" >/dev/null
chmod 600 "$PROGRESS_PLIST"

if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "$DOMAIN/$LABEL"
  sleep 1
fi
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl kickstart -k "$DOMAIN/$LABEL"

if launchctl print "$DOMAIN/$LOCAL_EDIT_LABEL" >/dev/null 2>&1; then
  launchctl bootout "$DOMAIN/$LOCAL_EDIT_LABEL"
fi
launchctl bootstrap "$DOMAIN" "$LOCAL_EDIT_PLIST"
if launchctl print "$DOMAIN/$PROGRESS_LABEL" >/dev/null 2>&1; then
  launchctl bootout "$DOMAIN/$PROGRESS_LABEL"
fi
launchctl bootstrap "$DOMAIN" "$PROGRESS_PLIST"
/System/Library/CoreServices/pbs -flush 2>/dev/null || true

for _ in {1..15}; do
  if mount | grep -Fq " on $MOUNT_POINT "; then
    print "完成：NAS 已挂载到 $MOUNT_POINT"
    exit 0
  fi
  sleep 1
done

print -u2 "服务已安装，但挂载未在 15 秒内完成。请查看：$LOG_DIR/rclone.log"
exit 1
