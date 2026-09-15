#!/bin/zsh

set -u

readonly REMOTE_NAME="nas"
readonly REMOTE_PATH="/home/wyp/disk/data/storage"
readonly MOUNT_POINT="$HOME/Desktop/nas"
readonly PRIMARY_WORK_DIR="/Volumes/data/PhD"
readonly FALLBACK_WORK_DIR="$HOME/Documents/NAS Local Edit"
readonly STATE_DIR="$HOME/Library/Application Support/rclone-nas/local-edit-state"
readonly PROGRESS_FILE="$STATE_DIR/progress.tsv"
readonly LOG_DIR="$HOME/Library/Logs/rclone-nas"
readonly LOG_FILE="$LOG_DIR/local-edit.log"
readonly KEYCHAIN_SERVICE="rclone-nas-sftp"
readonly KEYCHAIN_ACCOUNT="wyp@nas"
readonly LEGACY_KEYCHAIN_ACCOUNT="wyp@server.wyp.life:6100"
readonly OBSCURED_KEYCHAIN_ACCOUNT="wyp@nas:rclone-obscured"
readonly RCLONE="${commands[rclone]:-/opt/homebrew/bin/rclone}"
readonly QUIET_SECONDS=20
readonly RETRY_SECONDS=10

log() {
  mkdir -p "$LOG_DIR"
  print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
}

load_password() {
  local password
  if RCLONE_CONFIG_NAS_PASS="$(/usr/bin/security find-generic-password \
    -a "$OBSCURED_KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null)"; then
    export RCLONE_CONFIG_NAS_PASS
    return
  fi

  if ! password="$(/usr/bin/security find-generic-password \
    -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null)"; then
    password="$(/usr/bin/security find-generic-password \
      -a "$LEGACY_KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" -w)" || return 1
  fi
  export RCLONE_CONFIG_NAS_PASS
  RCLONE_CONFIG_NAS_PASS="$(printf '%s\n' "$password" | "$RCLONE" obscure -)"
  /usr/bin/security add-generic-password \
    -a "$OBSCURED_KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" \
    -l "rclone NAS stable obscured password" -U -w "$RCLONE_CONFIG_NAS_PASS" >/dev/null
  unset password
}

remote_for() {
  print -r -- "$REMOTE_NAME:$REMOTE_PATH/$1"
}

local_signature() {
  /usr/bin/stat -f '%m:%z:%i' "$1" 2>/dev/null
}

remote_fingerprint() {
  "$RCLONE" lsl "$(remote_for "$1")" \
    --contimeout 10s --timeout 20s --retries 1 --low-level-retries 1 2>/dev/null |
    /usr/bin/awk 'NR == 1 { print $1 "|" $2 "T" $3; exit }'
}

write_state() {
  local state_file="$1"
  local signature="$2"
  local fingerprint="$3"
  local local_file="$4"
  mkdir -p "${state_file:h}"
  printf '%s\n%s\n%s\n' "$signature" "$fingerprint" "$local_file" > "$state_file.tmp.$$"
  /bin/mv -f "$state_file.tmp.$$" "$state_file"
}

write_progress() {
  local transfer_state="$1"
  local percent="$2"
  local relative="${3//$'\t'/ }"
  relative="${relative//$'\n'/ }"
  mkdir -p "$STATE_DIR"
  printf '%s\t%s\t%s\t%s\n' "$transfer_state" "$percent" "$relative" "$(date +%s)" \
    > "$PROGRESS_FILE.tmp.$$"
  /bin/mv -f "$PROGRESS_FILE.tmp.$$" "$PROGRESS_FILE"
}

upload_with_progress() {
  local source_file="$1"
  local destination="$2"
  local relative="$3"
  local line percent rclone_status

  write_progress uploading 0 "$relative"
  "$RCLONE" copyto "$source_file" "$destination" \
    --contimeout 10s --timeout 10m --retries 2 --low-level-retries 2 \
    --stats 1s --stats-one-line --stats-log-level NOTICE 2>&1 |
    while IFS= read -r line; do
      percent="$(print -r -- "$line" | /usr/bin/sed -nE 's/.*[^0-9]([0-9]{1,3})%.*/\1/p')"
      if [[ -n "$percent" ]]; then
        write_progress uploading "$percent" "$relative"
      elif [[ -n "$line" ]]; then
        log "rclone 上传：$line"
      fi
    done
  rclone_status="${pipestatus[1]}"

  if (( rclone_status == 0 )); then
    write_progress done 100 "$relative"
  else
    write_progress error 0 "$relative"
  fi
  return "$rclone_status"
}

preferred_work_dir() {
  if [[ -d "$PRIMARY_WORK_DIR" && -w "$PRIMARY_WORK_DIR" ]]; then
    print -r -- "$PRIMARY_WORK_DIR"
  else
    mkdir -p "$FALLBACK_WORK_DIR"
    print -r -- "$FALLBACK_WORK_DIR"
  fi
}

tracked_local_file() {
  local state_file="$1"
  local relative="$2"
  local stored_file

  stored_file="$(/usr/bin/sed -n '3p' "$state_file" 2>/dev/null)"
  if [[ -n "$stored_file" ]]; then
    print -r -- "$stored_file"
  elif [[ -f "$FALLBACK_WORK_DIR/$relative" ]]; then
    print -r -- "$FALLBACK_WORK_DIR/$relative"
  elif [[ -f "$PRIMARY_WORK_DIR/$relative" ]]; then
    print -r -- "$PRIMARY_WORK_DIR/$relative"
  else
    print -r -- "$(preferred_work_dir)/$relative"
  fi
}

open_files() {
  local selected relative local_file state_file current_signature synced_signature
  local baseline_fingerprint current_fingerprint temporary_file preferred_file recorded_file

  (( $# > 0 )) || {
    log "没有收到 Finder 文件"
    return 2
  }

  mkdir -p "$FALLBACK_WORK_DIR" "$STATE_DIR" "$LOG_DIR"
  load_password || {
    log "无法从钥匙串读取 NAS 密码"
    return 1
  }

  for selected in "$@"; do
    selected="${selected:A}"
    if [[ "$selected" != "${MOUNT_POINT:A}/"* ]] || [[ ! -f "$selected" ]]; then
      log "跳过非 NAS 文件：$selected"
      continue
    fi

    relative="${selected#${MOUNT_POINT:A}/}"
    state_file="$STATE_DIR/$relative.state"
    local_file="$(tracked_local_file "$state_file" "$relative")"
    if [[ ! -f "$local_file" ]]; then
      local_file="$(preferred_work_dir)/$relative"
    fi
    mkdir -p "${local_file:h}" "${state_file:h}"

    if [[ ! -f "$local_file" ]]; then
      temporary_file="$local_file.download.$$"
      if ! "$RCLONE" copyto "$(remote_for "$relative")" "$temporary_file" \
        --contimeout 10s --timeout 2m --retries 2 --low-level-retries 2; then
        /bin/rm -f "$temporary_file"
        log "首次下载失败：$relative"
        continue
      fi
      /bin/mv -f "$temporary_file" "$local_file"
      current_signature="$(local_signature "$local_file")"
      current_fingerprint="$(remote_fingerprint "$relative")"
      write_state "$state_file" "$current_signature" "$current_fingerprint" "$local_file"
      log "已下载到本地工作区：$relative"
    else
      current_signature="$(local_signature "$local_file")"
      synced_signature="$(/usr/bin/sed -n '1p' "$state_file" 2>/dev/null)"
      baseline_fingerprint="$(/usr/bin/sed -n '2p' "$state_file" 2>/dev/null)"

      if [[ "$current_signature" == "$synced_signature" ]]; then
        current_fingerprint="$(remote_fingerprint "$relative")"
        if [[ -n "$current_fingerprint" && "$current_fingerprint" != "$baseline_fingerprint" ]]; then
          temporary_file="$local_file.download.$$"
          if "$RCLONE" copyto "$(remote_for "$relative")" "$temporary_file" \
            --contimeout 10s --timeout 2m --retries 2 --low-level-retries 2; then
            /bin/mv -f "$temporary_file" "$local_file"
            write_state "$state_file" "$(local_signature "$local_file")" "$current_fingerprint" "$local_file"
            log "打开前已更新远端版本：$relative"
          else
            /bin/rm -f "$temporary_file"
            log "远端更新下载失败，继续打开已有本地副本：$relative"
          fi
        fi
      else
        log "本地文件仍有待上传修改，未用远端版本覆盖：$relative"
      fi
    fi

    current_signature="$(local_signature "$local_file")"
    synced_signature="$(/usr/bin/sed -n '1p' "$state_file" 2>/dev/null)"
    baseline_fingerprint="$(/usr/bin/sed -n '2p' "$state_file" 2>/dev/null)"
    preferred_file="$(preferred_work_dir)/$relative"
    if [[ "$local_file" != "$preferred_file" && "$preferred_file" == "$PRIMARY_WORK_DIR/"* \
      && "$current_signature" == "$synced_signature" && ! -e "$preferred_file" ]]; then
      mkdir -p "${preferred_file:h}"
      temporary_file="$preferred_file.migrate.$$"
      if /bin/cp -p "$local_file" "$temporary_file" && /bin/mv -f "$temporary_file" "$preferred_file"; then
        /bin/rm -f "$local_file"
        local_file="$preferred_file"
        synced_signature="$(local_signature "$local_file")"
        write_state "$state_file" "$synced_signature" "$baseline_fingerprint" "$local_file"
        log "已将同步完成的本地副本移到 U 盘：$relative"
      else
        /bin/rm -f "$temporary_file"
        log "无法将本地副本移到 U 盘，继续使用原位置：$relative"
      fi
    fi

    recorded_file="$(/usr/bin/sed -n '3p' "$state_file" 2>/dev/null)"
    if [[ "$recorded_file" != "$local_file" ]]; then
      write_state "$state_file" "$synced_signature" "$baseline_fingerprint" "$local_file"
    fi

    /usr/bin/open "$local_file"
  done
}

conflict_remote_for() {
  local relative="$1"
  local directory="${relative:h}"
  local filename="${relative:t}"
  local timestamp="$(date '+%Y%m%d-%H%M%S')"
  local conflict_name

  if [[ "$filename" == *.* && "$filename" != .* ]]; then
    conflict_name="${filename:r} (remote conflict $timestamp).${filename:e}"
  else
    conflict_name="$filename (remote conflict $timestamp)"
  fi

  if [[ "$directory" == "." ]]; then
    print -r -- "$(remote_for "$conflict_name")"
  else
    print -r -- "$(remote_for "$directory/$conflict_name")"
  fi
}

sync_state_file() {
  local state_file="$1"
  local relative="${state_file#$STATE_DIR/}"
  local local_file current_signature synced_signature baseline_fingerprint
  local pending_file pending_signature pending_since now remote_fingerprint_now
  local snapshot_file snapshot_signature conflict_remote

  relative="${relative%.state}"
  local_file="$(tracked_local_file "$state_file" "$relative")"
  pending_file="$state_file.pending"

  [[ -f "$local_file" ]] || return 0
  current_signature="$(local_signature "$local_file")"
  synced_signature="$(/usr/bin/sed -n '1p' "$state_file" 2>/dev/null)"
  baseline_fingerprint="$(/usr/bin/sed -n '2p' "$state_file" 2>/dev/null)"

  if [[ "$current_signature" == "$synced_signature" ]]; then
    /bin/rm -f "$pending_file"
    return 0
  fi

  pending_signature="$(/usr/bin/sed -n '1p' "$pending_file" 2>/dev/null)"
  pending_since="$(/usr/bin/sed -n '2p' "$pending_file" 2>/dev/null)"
  now="$(date +%s)"
  if [[ "$pending_signature" != "$current_signature" ]]; then
    printf '%s\n%s\n' "$current_signature" "$now" > "$pending_file"
    return 0
  fi
  [[ "$pending_since" == <-> ]] || pending_since="$now"
  (( now - pending_since >= QUIET_SECONDS )) || return 0

  remote_fingerprint_now="$(remote_fingerprint "$relative")"
  if [[ -z "$remote_fingerprint_now" ]]; then
    log "远端不可用，保留待上传修改：$relative"
    return 0
  fi

  if [[ -n "$baseline_fingerprint" && "$remote_fingerprint_now" != "$baseline_fingerprint" ]]; then
    conflict_remote="$(conflict_remote_for "$relative")"
    if ! "$RCLONE" copyto "$(remote_for "$relative")" "$conflict_remote" \
      --contimeout 10s --timeout 2m --retries 2 --low-level-retries 2; then
      log "无法保存远端冲突副本，取消覆盖：$relative"
      return 0
    fi
    log "检测到远端变化，已保存冲突副本：$conflict_remote"
  fi

  snapshot_file="$(/usr/bin/mktemp /private/tmp/rclone-nas-local-edit.XXXXXX)"
  if ! /bin/cp -p "$local_file" "$snapshot_file"; then
    /bin/rm -f "$snapshot_file"
    return 0
  fi
  snapshot_signature="$current_signature"

  if upload_with_progress "$snapshot_file" "$(remote_for "$relative")" "$relative"; then
    remote_fingerprint_now="$(remote_fingerprint "$relative")"
    write_state "$state_file" "$snapshot_signature" "$remote_fingerprint_now" "$local_file"
    /bin/rm -f "$pending_file"
    log "上传完成：$relative"
  else
    log "上传失败，将自动重试：$relative"
  fi
  /bin/rm -f "$snapshot_file"
}

sync_once() {
  local state_file
  mkdir -p "$FALLBACK_WORK_DIR" "$STATE_DIR" "$LOG_DIR"
  load_password || {
    log "后台同步无法从钥匙串读取 NAS 密码"
    return 1
  }

  while IFS= read -r -d '' state_file; do
    sync_state_file "$state_file"
  done < <(/usr/bin/find "$STATE_DIR" -type f -name '*.state' -print0)
}

sync_loop() {
  log "本地编辑后台同步已启动"
  while true; do
    sync_once
    sleep "$RETRY_SECONDS"
  done
}

case "${1:-}" in
  open)
    shift
    open_files "$@"
    ;;
  sync) sync_loop ;;
  sync-once) sync_once ;;
  reveal)
    /usr/bin/open "$(preferred_work_dir)"
    ;;
  *)
    print -u2 "用法：$0 {open 文件...|sync|sync-once|reveal}"
    exit 2
    ;;
esac
