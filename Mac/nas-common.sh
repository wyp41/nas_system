#!/bin/zsh

# Shared settings for setup, the mount service and local editing.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
readonly RUNTIME_DIR="$HOME/Library/Application Support/rclone-nas"
readonly SETTINGS_FILE="${NAS_CONFIG_FILE:-$RUNTIME_DIR/config.json}"
if [[ ! -f "$SETTINGS_FILE" ]]; then
  print -u2 "未找到配置，请先运行 Mac/setup.sh"
  return 1
fi

setting() {
  local value
  if value="$(/usr/bin/plutil -extract "$1" raw -o - "$SETTINGS_FILE" 2>/dev/null)"; then
    print -r -- "$value"
  else
    print -r -- "${2:-}"
  fi
}

expand_path() {
  local value="$1"
  [[ "$value" == '~' || "$value" == '~/'* ]] && value="$HOME${value#\~}"
  print -r -- "$value"
}

readonly NAS_HOST="$(setting nasHost)"
readonly LAB_HOST="$(setting labHost)"
readonly SSH_USER="$(setting sshUser)"
readonly REMOTE_PATH="$(setting remotePath)"
readonly TUNNEL_PORT="$(setting tunnelPort 22022)"
if [[ ! "$NAS_HOST" =~ '^[A-Za-z0-9][A-Za-z0-9.-]*$' \
  || ! "$SSH_USER" =~ '^[A-Za-z0-9_.@-]+$' || "$REMOTE_PATH" != /* \
  || "$TUNNEL_PORT" != <1-65535> \
  || ( -n "$LAB_HOST" && ! "$LAB_HOST" =~ '^[A-Za-z0-9][A-Za-z0-9.-]*$' ) ]]; then
  print -u2 "配置无效：请检查 nasHost、sshUser、remotePath、labHost 和 tunnelPort"
  return 1
fi

readonly REMOTE_NAME="nas"
readonly MOUNT_POINT="$(expand_path "$(setting macMountPoint '~/Desktop/nas')")"
readonly PRIMARY_WORK_DIR="$(expand_path "$(setting preferredWorkDir)")"
readonly FALLBACK_WORK_DIR="$(expand_path "$(setting localWorkDir '~/Documents/NAS Local Edit')")"
if [[ "$MOUNT_POINT" != /* || "$MOUNT_POINT" == / || "$FALLBACK_WORK_DIR" != /* \
  || ( -n "$PRIMARY_WORK_DIR" && "$PRIMARY_WORK_DIR" != /* ) ]]; then
  print -u2 "本地目录必须使用绝对路径或 ~/ 开头的路径"
  return 1
fi
for work_dir in "$FALLBACK_WORK_DIR" ${PRIMARY_WORK_DIR:+"$PRIMARY_WORK_DIR"}; do
  if [[ "${work_dir:A}" == "${MOUNT_POINT:A}" || "${work_dir:A}" == "${MOUNT_POINT:A}/"* ]]; then
    print -u2 "本地编辑目录不能位于 NAS 挂载目录内"
    return 1
  fi
done

readonly CACHE_DIR="$HOME/Library/Caches/rclone-nas"
readonly LOG_DIR="$HOME/Library/Logs/rclone-nas"
readonly STATE_DIR="$RUNTIME_DIR/local-edit-state"
readonly PROGRESS_FILE="$STATE_DIR/progress.tsv"
readonly KNOWN_HOSTS_FILE="$RUNTIME_DIR/known_hosts-$NAS_HOST-$TUNNEL_PORT"
readonly KEYCHAIN_SERVICE="rclone-nas-sftp"
readonly KEYCHAIN_ACCOUNT="${SSH_USER}@${NAS_HOST}:rclone-obscured"
readonly RCLONE="${commands[rclone]:-}"
readonly CLOUDFLARED="${commands[cloudflared]:-}"
export RCLONE_CONFIG="$RUNTIME_DIR/rclone.conf"

# Keep these labels stable so upgrades replace existing launch agents.
readonly LABEL="com.wyp.rclone-nas"
readonly PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
readonly DOMAIN="gui/$(id -u)"

load_password() {
  RCLONE_CONFIG_NAS_PASS="$(/usr/bin/security find-generic-password \
    -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" -w)" || return 1
  export RCLONE_CONFIG_NAS_PASS
}
