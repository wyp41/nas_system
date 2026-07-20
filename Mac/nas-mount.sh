#!/bin/zsh

set -euo pipefail

readonly REMOTE_NAME="nas"
readonly REMOTE_PATH="/home/wyp/disk/data/storage"
readonly MOUNT_POINT="$HOME/Desktop/nas"
readonly CACHE_DIR="$HOME/Library/Caches/rclone-nas"
readonly LOG_DIR="$HOME/Library/Logs/rclone-nas"
readonly TUNNEL_HOST="nas.wyp.life"
readonly TUNNEL_ADDRESS="127.0.0.1:22022"
readonly CLOUDFLARED="/opt/homebrew/bin/cloudflared"
readonly KEYCHAIN_SERVICE="rclone-nas-sftp"
readonly KEYCHAIN_ACCOUNT="wyp@nas"
readonly LEGACY_KEYCHAIN_ACCOUNT="wyp@server.wyp.life:6100"
readonly LABEL="com.wyp.rclone-nas"
readonly PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
readonly DOMAIN="gui/$(id -u)"
readonly RCLONE="${commands[rclone]:-/opt/homebrew/bin/rclone}"
typeset -gi tunnel_pid=0
typeset -gi mount_pid=0

load_password() {
  local password
  if ! password="$(/usr/bin/security find-generic-password \
    -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null)"; then
    password="$(/usr/bin/security find-generic-password \
      -a "$LEGACY_KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" -w)"
  fi
  export RCLONE_CONFIG_NAS_PASS
  RCLONE_CONFIG_NAS_PASS="$(printf '%s\n' "$password" | "$RCLONE" obscure -)"
  unset password
}

cleanup() {
  trap - EXIT INT TERM
  if (( mount_pid > 0 )); then
    kill -TERM "$mount_pid" 2>/dev/null || true
    wait "$mount_pid" 2>/dev/null || true
  fi
  if (( tunnel_pid > 0 )); then
    kill -TERM "$tunnel_pid" 2>/dev/null || true
    wait "$tunnel_pid" 2>/dev/null || true
  fi
}

run_mount() {
  mkdir -p "$MOUNT_POINT" "$CACHE_DIR" "$LOG_DIR"
  load_password

  trap cleanup EXIT
  trap 'cleanup; exit 0' INT TERM

  "$CLOUDFLARED" access tcp \
    --hostname "$TUNNEL_HOST" \
    --url "$TUNNEL_ADDRESS" \
    --logfile "$LOG_DIR/cloudflared.log" \
    --log-level info &
  tunnel_pid=$!

  for _ in {1..30}; do
    if /usr/bin/nc -z 127.0.0.1 22022 2>/dev/null; then
      break
    fi
    if ! kill -0 "$tunnel_pid" 2>/dev/null; then
      print -u2 "Cloudflare Tunnel 启动失败，请查看 $LOG_DIR/cloudflared.log"
      return 1
    fi
    sleep 1
  done
  if ! /usr/bin/nc -z 127.0.0.1 22022 2>/dev/null; then
    print -u2 "Cloudflare Tunnel 未在 30 秒内就绪"
    return 1
  fi

  "$RCLONE" nfsmount "$REMOTE_NAME:$REMOTE_PATH" "$MOUNT_POINT" \
    --volname NAS \
    --vfs-cache-mode full \
    --cache-dir "$CACHE_DIR" \
    --vfs-cache-max-age 720h \
    --vfs-cache-min-free-space 10Gi \
    --vfs-write-back 5s \
    --dir-cache-time 30s \
    --poll-interval 0 \
    --transfers 4 \
    --log-file "$LOG_DIR/rclone.log" \
    --log-level INFO \
    --log-file-max-size 10Mi \
    --log-file-max-backups 5 \
    --log-file-max-age 30d &
  mount_pid=$!

  while kill -0 "$tunnel_pid" 2>/dev/null && kill -0 "$mount_pid" 2>/dev/null; do
    sleep 2
  done
  if ! kill -0 "$tunnel_pid" 2>/dev/null; then
    print -u2 "Cloudflare Tunnel 已断开，将由 launchd 自动重启"
    return 1
  fi
  wait "$mount_pid"
}

is_loaded() {
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1
}

start_service() {
  if [[ ! -f "$PLIST" ]]; then
    print -u2 "尚未初始化，请先运行 ./setup.sh"
    exit 1
  fi

  if ! is_loaded; then
    launchctl bootstrap "$DOMAIN" "$PLIST"
  fi
  launchctl kickstart -k "$DOMAIN/$LABEL"
  sleep 2
  status_service
}

stop_service() {
  if is_loaded; then
    launchctl bootout "$DOMAIN/$LABEL"
  fi
  if mount | grep -Fq " on $MOUNT_POINT "; then
    /sbin/umount "$MOUNT_POINT"
  fi
  print "NAS 已停止挂载"
}

status_service() {
  if mount | grep -Fq " on $MOUNT_POINT "; then
    print "NAS 已挂载：$MOUNT_POINT"
  else
    print -u2 "NAS 尚未挂载。查看日志：$LOG_DIR/rclone.log"
    return 1
  fi
}

case "${1:-status}" in
  run) run_mount ;;
  start) start_service ;;
  stop) stop_service ;;
  restart)
    stop_service
    start_service
    ;;
  status) status_service ;;
  logs) tail -n 100 -f "$LOG_DIR/rclone.log" "$LOG_DIR/cloudflared.log" ;;
  *)
    print -u2 "用法：$0 {start|stop|restart|status|logs}"
    exit 2
    ;;
esac
