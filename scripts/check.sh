#!/bin/zsh
# Offline checks only; never start services or touch installed credentials.
set -euo pipefail
readonly ROOT="${0:A:h:h}"
readonly CHECK_DIR="$(mktemp -d)"
trap '/bin/rm -r "$CHECK_DIR"' EXIT
cd "$ROOT"
for script in Mac/*.sh; do
  zsh -o NO_BG_NICE -n "$script"
done
plutil -lint Mac/launch-agent.plist.template 'Mac/NAS Local Edit.workflow/Contents/Info.plist' \
  'Mac/NAS Local Edit.workflow/Contents/document.wflow'
zsh Mac/setup.sh --help >/dev/null
if printf 'invalid host\nalice\n/srv/shared folders\n\n' | zsh Mac/setup.sh --config "$CHECK_DIR/wizard.json" > "$CHECK_DIR/wizard.log" 2>&1; then
  print -u2 'Invalid hostname was accepted'; exit 1
fi
[[ "$(plutil -extract sshUser raw -o - "$CHECK_DIR/wizard.json")" == alice ]]
plutil -replace nasHost -string nas.example.org "$CHECK_DIR/wizard.json"
NAS_CONFIG_FILE="$CHECK_DIR/wizard.json" zsh -eu -c '
  source Mac/nas-common.sh
  [[ "$TUNNEL_PORT" == 22022 && "$MOUNT_POINT" == "$HOME/Desktop/nas" && -z "$LAB_HOST" ]]
'
cp config.example.json "$CHECK_DIR/config.json"
plutil -replace localWorkDir -string "$CHECK_DIR/work" "$CHECK_DIR/config.json"
NAS_CONFIG_FILE="$CHECK_DIR/config.json" zsh -u -c '
  source "${0:h}/nas-common.sh" || exit 1
  source <(sed -e '\''/^source /d'\'' -e '\''/^case "${1:-}" in/,$d'\'' "$0") || exit 1
  [[ "$NAS_HOST" == nas.example.com && "$TUNNEL_PORT" == 22022 && -z "$LAB_HOST" ]] || exit 1
  [[ "$MOUNT_POINT" == "$HOME/Desktop/nas" && -z "$PRIMARY_WORK_DIR" ]] || exit 1
  [[ "$(tracked_local_file "$1/missing.state" etc/passwd)" == "$1/work/etc/passwd" ]] || exit 1
' "$ROOT/Mac/nas-local-edit.sh" "$CHECK_DIR"
plutil -replace tunnelPort -integer 0 "$CHECK_DIR/config.json"
if NAS_CONFIG_FILE="$CHECK_DIR/config.json" zsh -c 'source Mac/nas-common.sh' 2>/dev/null; then
  print -u2 'Invalid tunnelPort was accepted'; exit 1
fi
if command -v pwsh >/dev/null 2>&1; then
  NAS_CHECK_ROOT="$ROOT" pwsh -NoProfile -NonInteractive -Command - <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
try {
$root = $env:NAS_CHECK_ROOT
foreach ($file in Get-ChildItem (Join-Path $root 'Windows') -Filter '*.ps1') {
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$parseErrors)
    if ($parseErrors) { throw ($parseErrors | Out-String) }
}
. (Join-Path $root 'Windows/Nas-Common.ps1')
$config = Read-NasConfig (Join-Path $root 'config.example.json')
if ($config.nasHost -ne 'nas.example.com' -or $config.windowsMountDrive -ne 'Z:' -or $config.labHost) {
    throw 'Unexpected Windows configuration defaults.'
}
$temporaryConfig = [IO.Path]::GetTempFileName()
try {
    @{ nasHost = 'nas.example.org'; sshUser = 'alice'; remotePath = '/srv/shared' } |
        ConvertTo-Json | Set-Content $temporaryConfig
    $config = Read-NasConfig $temporaryConfig
    if ($config.tunnelPort -ne 22022 -or $config.windowsMountDrive -ne 'Z:') { throw 'Missing defaults.' }
    $config.tunnelPort = 0
    $config | ConvertTo-Json | Set-Content $temporaryConfig
    $rejected = $false
    try { Read-NasConfig $temporaryConfig | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Invalid tunnelPort was accepted.' }
} finally { Remove-Item -LiteralPath $temporaryConfig }
Write-Host 'Windows syntax and configuration checks passed.'
} catch { [Console]::Error.WriteLine($_); exit 1 }

POWERSHELL
else
  print 'PowerShell not found; Windows checks skipped.'
fi
print 'Checks passed.'
