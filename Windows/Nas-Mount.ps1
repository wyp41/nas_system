#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet('run', 'start', 'stop', 'restart', 'status', 'logs')]
    [string]$Command = 'status'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ScriptPath = $MyInvocation.MyCommand.Path
$RuntimeDirectory = Split-Path -Parent $ScriptPath
$ConfigPath = Join-Path $RuntimeDirectory 'rclone.conf'
$PasswordPath = Join-Path $RuntimeDirectory 'nas-password.dat'
$CacheDirectory = Join-Path $env:LOCALAPPDATA 'rclone-nas\cache'
$LogDirectory = Join-Path $env:LOCALAPPDATA 'rclone-nas\logs'
$RcloneLogPath = Join-Path $LogDirectory 'rclone.log'
$CloudflaredLogPath = Join-Path $LogDirectory 'cloudflared.log'
$SupervisorLogPath = Join-Path $LogDirectory 'supervisor.log'
$SupervisorPidPath = Join-Path $RuntimeDirectory 'supervisor.pid'
$RclonePidPath = Join-Path $RuntimeDirectory 'rclone.pid'
$CloudflaredPidPath = Join-Path $RuntimeDirectory 'cloudflared.pid'
$StopPath = Join-Path $RuntimeDirectory 'stop.requested'
$MountDrive = 'Z:'
$TunnelPort = 22022
$RemotePath = if ($env:RCLONE_NAS_REMOTE_PATH) { $env:RCLONE_NAS_REMOTE_PATH } else { '/home/wyp/disk/data/storage' }
$RclonePath = if ($env:RCLONE_NAS_RCLONE) { $env:RCLONE_NAS_RCLONE } else { Join-Path $env:LOCALAPPDATA 'Programs\rclone\rclone.exe' }
$CloudflaredPath = if ($env:RCLONE_NAS_CLOUDFLARED) { $env:RCLONE_NAS_CLOUDFLARED } else { Join-Path $env:LOCALAPPDATA 'Programs\cloudflared\cloudflared.exe' }
$PowerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Write-SupervisorLog {
    param([string]$Message)

    New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null
    Add-Content -Path $SupervisorLogPath -Encoding UTF8 -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message)
}

function Get-TrackedProcess {
    param([string]$PidPath)

    if (-not (Test-Path $PidPath)) {
        return $null
    }
    $processId = 0
    if (-not [int]::TryParse(([IO.File]::ReadAllText($PidPath).Trim()), [ref]$processId)) {
        return $null
    }
    return Get-Process -Id $processId -ErrorAction SilentlyContinue
}

function Stop-TrackedProcess {
    param([string]$PidPath)

    $process = Get-TrackedProcess -PidPath $PidPath
    if ($process) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        Wait-Process -Id $process.Id -Timeout 10 -ErrorAction SilentlyContinue
    }
    Remove-Item -Force -ErrorAction SilentlyContinue -Path $PidPath
}

function Test-TunnelPort {
    $client = New-Object Net.Sockets.TcpClient
    try {
        $connection = $client.BeginConnect('127.0.0.1', $TunnelPort, $null, $null)
        if (-not $connection.AsyncWaitHandle.WaitOne(500)) {
            return $false
        }
        $client.EndConnect($connection)
        return $true
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function Test-NasMounted {
    $drive = Get-PSDrive -Name $MountDrive.TrimEnd(':') -PSProvider FileSystem -ErrorAction SilentlyContinue
    return [bool]$drive
}

function Get-ObscuredPassword {
    if (-not (Test-Path $PasswordPath)) {
        throw "The protected NAS password was not found: $PasswordPath"
    }
    $encryptedPassword = [IO.File]::ReadAllText($PasswordPath).Trim()
    $securePassword = $encryptedPassword | ConvertTo-SecureString
    $credential = New-Object Management.Automation.PSCredential('wyp', $securePassword)
    $plainPassword = $credential.GetNetworkCredential().Password
    try {
        $obscuredPassword = $plainPassword | & $RclonePath obscure -
        if ($LASTEXITCODE -ne 0) {
            throw 'rclone could not obscure the NAS password.'
        }
        return ($obscuredPassword | Select-Object -First 1).Trim()
    } finally {
        $plainPassword = $null
    }
}

function Quote-ProcessArgument {
    param([string]$Value)
    return '"{0}"' -f $Value.Replace('"', '\"')
}

function Invoke-MountSupervisor {
    if (-not (Test-Path $RclonePath)) {
        throw "rclone.exe was not found: $RclonePath"
    }
    if (-not (Test-Path $CloudflaredPath)) {
        throw "cloudflared.exe was not found: $CloudflaredPath"
    }
    if (-not (Test-Path $ConfigPath)) {
        throw "The rclone configuration was not found: $ConfigPath"
    }
    if (Test-NasMounted) {
        Write-SupervisorLog "$MountDrive is already in use; the mount supervisor is exiting."
        return
    }

    New-Item -ItemType Directory -Force -Path $CacheDirectory, $LogDirectory | Out-Null
    Remove-Item -Force -ErrorAction SilentlyContinue -Path $StopPath
    Set-Content -Path $SupervisorPidPath -Encoding ASCII -Value $PID
    $env:RCLONE_CONFIG_NAS_PASS = Get-ObscuredPassword

    try {
        while (-not (Test-Path $StopPath)) {
            $cloudflaredArguments = @(
                'access', 'tcp',
                '--hostname', 'nas.wyp.life',
                '--url', "127.0.0.1:$TunnelPort",
                '--logfile', (Quote-ProcessArgument $CloudflaredLogPath),
                '--log-level', 'info'
            )
            $cloudflared = Start-Process -FilePath $CloudflaredPath -ArgumentList $cloudflaredArguments -WindowStyle Hidden -PassThru
            Set-Content -Path $CloudflaredPidPath -Encoding ASCII -Value $cloudflared.Id
            Write-SupervisorLog "Cloudflare tunnel started with PID $($cloudflared.Id)."

            $tunnelReady = $false
            for ($attempt = 0; $attempt -lt 60; $attempt++) {
                if (Test-Path $StopPath) { break }
                if ($cloudflared.HasExited) { break }
                if (Test-TunnelPort) {
                    $tunnelReady = $true
                    break
                }
                Start-Sleep -Milliseconds 500
                $cloudflared.Refresh()
            }

            if ($tunnelReady -and -not (Test-Path $StopPath)) {
                $mountArguments = @(
                    'mount', "nas:$RemotePath", $MountDrive,
                    '--config', (Quote-ProcessArgument $ConfigPath),
                    '--network-mode',
                    '--volname', 'NAS',
                    '--vfs-cache-mode', 'full',
                    '--cache-dir', (Quote-ProcessArgument $CacheDirectory),
                    '--vfs-cache-max-age', '720h',
                    '--vfs-cache-min-free-space', '10Gi',
                    '--vfs-write-back', '5s',
                    '--dir-cache-time', '30s',
                    '--poll-interval', '0',
                    '--transfers', '4',
                    '--log-file', (Quote-ProcessArgument $RcloneLogPath),
                    '--log-level', 'INFO',
                    '--log-file-max-size', '10Mi',
                    '--log-file-max-backups', '5',
                    '--log-file-max-age', '30d',
                    '--no-console'
                )
                $rclone = Start-Process -FilePath $RclonePath -ArgumentList $mountArguments -WindowStyle Hidden -PassThru
                Set-Content -Path $RclonePidPath -Encoding ASCII -Value $rclone.Id
                Write-SupervisorLog "rclone mount started with PID $($rclone.Id)."

                while (-not (Test-Path $StopPath)) {
                    $cloudflared.Refresh()
                    $rclone.Refresh()
                    if ($cloudflared.HasExited -or $rclone.HasExited) { break }
                    Start-Sleep -Seconds 2
                }
            } else {
                Write-SupervisorLog 'Cloudflare tunnel did not become ready.'
            }

            Stop-TrackedProcess -PidPath $RclonePidPath
            Stop-TrackedProcess -PidPath $CloudflaredPidPath
            if (-not (Test-Path $StopPath)) {
                Write-SupervisorLog 'Mount stopped unexpectedly; retrying in 10 seconds.'
                Start-Sleep -Seconds 10
            }
        }
    } catch {
        Write-SupervisorLog "Mount supervisor error: $($_.Exception.Message)"
        throw
    } finally {
        Stop-TrackedProcess -PidPath $RclonePidPath
        Stop-TrackedProcess -PidPath $CloudflaredPidPath
        Remove-Item -Force -ErrorAction SilentlyContinue -Path $SupervisorPidPath, $StopPath
        Remove-Item Env:RCLONE_CONFIG_NAS_PASS -ErrorAction SilentlyContinue
        Write-SupervisorLog 'Mount supervisor stopped.'
    }
}

function Start-NasMount {
    $supervisor = Get-TrackedProcess -PidPath $SupervisorPidPath
    if ($supervisor) {
        Write-Host "NAS mount supervisor is already running (PID $($supervisor.Id))."
        return
    }
    if (Test-NasMounted) {
        throw "$MountDrive is already in use."
    }

    Remove-Item -Force -ErrorAction SilentlyContinue -Path $StopPath, $SupervisorPidPath
    $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" run' -f $ScriptPath
    Start-Process -FilePath $PowerShellPath -ArgumentList $arguments -WindowStyle Hidden | Out-Null

    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        Start-Sleep -Seconds 1
        if (Test-NasMounted) {
            Write-Host "NAS mounted at $MountDrive"
            return
        }
        if (-not (Get-TrackedProcess -PidPath $SupervisorPidPath) -and $attempt -gt 2) {
            break
        }
    }
    throw "NAS did not mount at $MountDrive within 30 seconds. Check $SupervisorLogPath and $RcloneLogPath"
}

function Stop-NasMount {
    New-Item -ItemType File -Force -Path $StopPath | Out-Null
    Stop-TrackedProcess -PidPath $RclonePidPath
    Stop-TrackedProcess -PidPath $CloudflaredPidPath

    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        if (-not (Get-TrackedProcess -PidPath $SupervisorPidPath)) { break }
        Start-Sleep -Seconds 1
    }
    $supervisor = Get-TrackedProcess -PidPath $SupervisorPidPath
    if ($supervisor) {
        Stop-Process -Id $supervisor.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -Force -ErrorAction SilentlyContinue -Path $SupervisorPidPath, $StopPath
    Write-Host 'NAS mount stopped.'
}

switch ($Command) {
    'run' { Invoke-MountSupervisor }
    'start' { Start-NasMount }
    'stop' { Stop-NasMount }
    'restart' {
        Stop-NasMount
        Start-NasMount
    }
    'status' {
        $supervisor = Get-TrackedProcess -PidPath $SupervisorPidPath
        if (Test-NasMounted) {
            Write-Host "NAS is mounted at $MountDrive"
        } elseif ($supervisor) {
            Write-Host "NAS mount supervisor is running (PID $($supervisor.Id)), but $MountDrive is not ready."
            exit 1
        } else {
            Write-Host 'NAS is not mounted.'
            exit 1
        }
    }
    'logs' {
        Write-Host "Supervisor log: $SupervisorLogPath"
        Write-Host "rclone log: $RcloneLogPath"
        Write-Host "cloudflared log: $CloudflaredLogPath"
        if (Test-Path $RcloneLogPath) {
            Get-Content -Tail 100 -Path $RcloneLogPath
        }
    }
}
