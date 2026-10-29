# Shared configuration and password loading; no side effects when dot-sourced.
function Read-NasConfig {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration not found: $Path. Run install-windows.cmd first."
    }
    $config = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    $defaults = @{
        labHost = ''; macMountPoint = '~/Desktop/nas'; windowsMountDrive = 'Z:'
        localWorkDir = '~/Documents/NAS Local Edit'; preferredWorkDir = ''; tunnelPort = 22022
    }
    foreach ($key in $defaults.Keys) {
        if (-not $config.PSObject.Properties[$key]) {
            $config | Add-Member -NotePropertyName $key -NotePropertyValue $defaults[$key]
        }
    }
    if ($config.nasHost -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]*$' -or
        $config.sshUser -notmatch '^[A-Za-z0-9_.@-]+$' -or
        $config.remotePath -notlike '/*' -or
        ($config.labHost -and $config.labHost -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]*$') -or
        $config.windowsMountDrive -notmatch '^[D-Zd-z]:$' -or
        "$($config.tunnelPort)" -notmatch '^\d+$' -or
        [int]$config.tunnelPort -lt 1 -or [int]$config.tunnelPort -gt 65535) {
        throw 'Invalid configuration. Check nasHost, sshUser, remotePath, labHost, windowsMountDrive and tunnelPort.'
    }
    return $config
}

function Get-NasPasswordPath {
    param([string]$Directory, $Config)
    return Join-Path $Directory ("password-{0}-{1}.dat" -f $Config.nasHost, $Config.sshUser)
}

function Get-ObscuredPassword {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Protected NAS password not found: $Path. Run install-windows.cmd."
    }
    $securePassword = (Get-Content -Raw -LiteralPath $Path).Trim() | ConvertTo-SecureString
    $credential = New-Object Management.Automation.PSCredential('nas', $securePassword)
    return $credential.GetNetworkCredential().Password
}

function Test-TunnelPort {
    param([int]$Port)
    $client = New-Object Net.Sockets.TcpClient
    try {
        $connection = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $connection.AsyncWaitHandle.WaitOne(500)) { return $false }
        $client.EndConnect($connection)
        return $true
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}
