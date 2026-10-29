#requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config.json'),
    [switch]$SkipAccessLogin,
    [switch]$ResetNasPassword
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$OutputEncoding = New-Object Text.UTF8Encoding($false)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ProgramRoot = Join-Path $env:LOCALAPPDATA 'Programs'
. (Join-Path $PSScriptRoot 'Nas-Common.ps1')

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    $installedConfig = Join-Path $ProgramRoot 'rclone-nas\config.json'
    if (-not $PSBoundParameters.ContainsKey('ConfigPath') -and (Test-Path -LiteralPath $installedConfig)) {
        Copy-Item -LiteralPath $installedConfig -Destination $ConfigPath
    } else {
        Write-Host 'First-time setup. Leave LAB empty if it is not needed.'
        [ordered]@{
            nasHost = (Read-Host 'NAS hostname, e.g. nas.example.com')
            sshUser = (Read-Host 'SSH username')
            remotePath = (Read-Host 'Remote directory, e.g. /home/user/storage')
            labHost = (Read-Host 'LAB hostname (optional)')
        } | ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
    }
}
$Settings = Read-NasConfig -Path $ConfigPath
$NasHostName = $Settings.nasHost
$LabHostName = $Settings.labHost
$SshUser = $Settings.sshUser

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Get-PlatformArchitecture {
    $architecture = if ($env:PROCESSOR_ARCHITEW6432) {
        $env:PROCESSOR_ARCHITEW6432
    } else {
        $env:PROCESSOR_ARCHITECTURE
    }

    switch ($architecture.ToUpperInvariant()) {
        'AMD64' { return @{ Cloudflared = 'amd64'; Rclone = 'amd64' } }
        'X86'   { return @{ Cloudflared = '386'; Rclone = '386' } }
        'ARM64' { return @{ Cloudflared = 'amd64'; Rclone = 'arm64' } }
        default { throw "Unsupported Windows architecture: $architecture" }
    }
}

function Add-UserPath {
    param([string]$Directory)

    $normalizedDirectory = $Directory.TrimEnd([char]92)
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entries = @($userPath -split ';' | Where-Object { $_ })
    if (-not ($entries | Where-Object { $_.TrimEnd([char]92) -ieq $normalizedDirectory })) {
        $newPath = (@($entries) + $Directory) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    }

    $processEntries = @($env:Path -split ';')
    if (-not ($processEntries | Where-Object { $_.TrimEnd([char]92) -ieq $normalizedDirectory })) {
        $env:Path = "$Directory;$env:Path"
    }
}

function Install-Cloudflared {
    param([string]$Architecture)

    $installDirectory = Join-Path $ProgramRoot 'cloudflared'
    $executable = Join-Path $installDirectory 'cloudflared.exe'
    if (Test-Path -LiteralPath $executable -PathType Leaf) {
        Write-Host "cloudflared already exists: $executable"
        Add-UserPath $installDirectory
        return $executable
    }

    $existing = Get-Command cloudflared.exe -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "cloudflared already exists: $($existing.Source)"
        return $existing.Source
    }

    Write-Step 'Downloading cloudflared from the official GitHub release'
    $assetName = "cloudflared-windows-$Architecture.exe"
    $temporaryFile = Join-Path $env:TEMP ("cloudflared-{0}.exe" -f [Guid]::NewGuid())
    New-Item -ItemType Directory -Force -Path $installDirectory | Out-Null

    try {
        $headers = @{ 'User-Agent' = 'rclone-cloudflare-windows-installer' }
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/cloudflare/cloudflared/releases/latest' -Headers $headers
        $asset = $release.assets | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
        if (-not $asset) {
            throw "The latest cloudflared release does not contain $assetName"
        }

        Invoke-WebRequest -UseBasicParsing -Uri $asset.browser_download_url -Headers $headers -OutFile $temporaryFile
        if (-not $asset.digest -or -not $asset.digest.StartsWith('sha256:')) {
            throw 'The cloudflared release does not contain an SHA-256 digest.'
        }

        $expectedHash = $asset.digest.Substring(7).ToLowerInvariant()
        $actualHash = (Get-FileHash -Algorithm SHA256 -Path $temporaryFile).Hash.ToLowerInvariant()
        if ($actualHash -ne $expectedHash) {
            throw 'cloudflared SHA-256 verification failed.'
        }

        Move-Item -Force -Path $temporaryFile -Destination $executable
    } finally {
        if (Test-Path $temporaryFile) {
            Remove-Item -Force $temporaryFile
        }
    }

    Add-UserPath $installDirectory
    return $executable
}

function Install-Rclone {
    param([string]$Architecture)

    $installDirectory = Join-Path $ProgramRoot 'rclone'
    $executable = Join-Path $installDirectory 'rclone.exe'
    if (Test-Path -LiteralPath $executable -PathType Leaf) {
        Write-Host "rclone already exists: $executable"
        Add-UserPath $installDirectory
        return $executable
    }

    $existing = Get-Command rclone.exe -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "rclone already exists: $($existing.Source)"
        return $existing.Source
    }

    Write-Step 'Downloading rclone from downloads.rclone.org'
    $temporaryDirectory = Join-Path $env:TEMP ("rclone-{0}" -f [Guid]::NewGuid())
    New-Item -ItemType Directory -Force -Path $installDirectory | Out-Null
    New-Item -ItemType Directory -Force -Path $temporaryDirectory | Out-Null

    try {
        $versionText = (Invoke-WebRequest -UseBasicParsing -Uri 'https://downloads.rclone.org/version.txt').Content.Trim()
        $versionMatch = [regex]::Match($versionText, 'v\d+\.\d+\.\d+')
        if (-not $versionMatch.Success) {
            throw "Could not parse the current rclone version from: $versionText"
        }

        $version = $versionMatch.Value
        $archiveName = "rclone-$version-windows-$Architecture.zip"
        $baseUrl = "https://downloads.rclone.org/$version"
        $archivePath = Join-Path $temporaryDirectory $archiveName
        $checksumResponse = Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/SHA256SUMS"
        $checksums = if ($checksumResponse.Content -is [byte[]]) {
            [Text.Encoding]::UTF8.GetString($checksumResponse.Content)
        } else {
            [string]$checksumResponse.Content
        }
        $checksumPattern = '(?m)^([0-9a-fA-F]{64})\s+' + [regex]::Escape($archiveName) + '\s*$'
        $checksumMatch = [regex]::Match($checksums, $checksumPattern)
        if (-not $checksumMatch.Success) {
            throw "No SHA-256 checksum was found for $archiveName"
        }

        Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/$archiveName" -OutFile $archivePath
        $expectedHash = $checksumMatch.Groups[1].Value.ToLowerInvariant()
        $actualHash = (Get-FileHash -Algorithm SHA256 -Path $archivePath).Hash.ToLowerInvariant()
        if ($actualHash -ne $expectedHash) {
            throw 'rclone SHA-256 verification failed.'
        }

        Expand-Archive -Path $archivePath -DestinationPath $temporaryDirectory -Force
        $downloadedExecutable = Get-ChildItem -Path $temporaryDirectory -Filter rclone.exe -Recurse | Select-Object -First 1
        if (-not $downloadedExecutable) {
            throw 'rclone.exe was not found in the downloaded archive.'
        }
        Copy-Item -Force -Path $downloadedExecutable.FullName -Destination $executable
    } finally {
        if (Test-Path $temporaryDirectory) {
            Remove-Item -Recurse -Force $temporaryDirectory
        }
    }

    Add-UserPath $installDirectory
    return $executable
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-WinFspInstalled {
    $installationRoots = @(
        (Join-Path $env:ProgramFiles 'WinFsp'),
        $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'WinFsp' })
    ) | Where-Object { $_ }

    return [bool]($installationRoots | Where-Object { Test-Path (Join-Path $_ 'bin') } | Select-Object -First 1)
}

function Install-WinFsp {
    if (Test-WinFspInstalled) {
        Write-Host 'WinFsp is already installed.'
        return
    }

    Write-Step "Downloading and installing WinFsp for the $($Settings.windowsMountDrive) mount"
    $temporaryFile = Join-Path $env:TEMP ("winfsp-{0}.msi" -f [Guid]::NewGuid())

    try {
        $headers = @{ 'User-Agent' = 'rclone-cloudflare-windows-installer' }
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/winfsp/winfsp/releases/latest' -Headers $headers
        $asset = $release.assets | Where-Object { $_.name -match '^winfsp-[\d.]+\.msi$' } | Select-Object -First 1
        if (-not $asset) {
            throw 'The latest WinFsp release does not contain an MSI installer.'
        }
        if (-not $asset.digest -or -not $asset.digest.StartsWith('sha256:')) {
            throw 'The WinFsp release does not contain an SHA-256 digest.'
        }

        Invoke-WebRequest -UseBasicParsing -Uri $asset.browser_download_url -Headers $headers -OutFile $temporaryFile
        $expectedHash = $asset.digest.Substring(7).ToLowerInvariant()
        $actualHash = (Get-FileHash -Algorithm SHA256 -Path $temporaryFile).Hash.ToLowerInvariant()
        if ($actualHash -ne $expectedHash) {
            throw 'WinFsp SHA-256 verification failed.'
        }

        $arguments = '/i "{0}" /qn /norestart' -f $temporaryFile
        $installer = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -Verb RunAs -Wait -PassThru
        if ($installer.ExitCode -notin @(0, 3010)) {
            throw "WinFsp installation failed with exit code $($installer.ExitCode)."
        }
    } finally {
        if (Test-Path $temporaryFile) {
            Remove-Item -Force $temporaryFile
        }
    }

    if (-not (Test-WinFspInstalled)) {
        throw 'WinFsp installation completed, but its installation directory was not found.'
    }
}

function Ensure-OpenSshClient {
    $existing = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "OpenSSH Client already exists: $($existing.Source)"
        return $existing.Source
    }

    Write-Step 'Installing the Windows OpenSSH Client capability'
    $capabilityName = 'OpenSSH.Client~~~~0.0.1.0'
    if (Test-IsAdministrator) {
        Add-WindowsCapability -Online -Name $capabilityName -ErrorAction Stop | Out-Null
    } else {
        $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments = '-NoProfile -Command "Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0 -ErrorAction Stop | Out-Null"'
        $installer = Start-Process -FilePath $powershellPath -ArgumentList $arguments -Verb RunAs -Wait -PassThru
        if ($installer.ExitCode -ne 0) {
            throw 'OpenSSH Client installation failed.'
        }
    }

    $sshPath = Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
    if (-not (Test-Path $sshPath)) {
        throw 'OpenSSH Client installation completed, but ssh.exe was not found.'
    }
    return $sshPath
}

function Invoke-AccessLogin {
    param(
        [string]$CloudflaredPath,
        [string[]]$HostNames
    )

    foreach ($hostName in $HostNames) {
        Write-Step "Authenticating Cloudflare Access for $hostName"
        & $CloudflaredPath access login "https://$hostName"
        if ($LASTEXITCODE -ne 0) {
            throw "Cloudflare Access login failed for $hostName"
        }
    }
}

function Set-SshConfig {
    param(
        [string]$CloudflaredPath,
        [string]$SshPath
    )

    Write-Step 'Writing managed nas and lab entries to the user SSH config'
    $sshDirectory = Join-Path $env:USERPROFILE '.ssh'
    $configPath = Join-Path $sshDirectory 'config'
    $beginMarker = '# BEGIN RCLONE-CLOUDFLARE MANAGED HOSTS'
    $endMarker = '# END RCLONE-CLOUDFLARE MANAGED HOSTS'
    $proxyExecutable = $CloudflaredPath.Replace('\', '/')
    New-Item -ItemType Directory -Force -Path $sshDirectory | Out-Null

    $sshHosts = [ordered]@{ nas = $NasHostName }
    if ($LabHostName) { $sshHosts['lab'] = $LabHostName }
    $managedBlock = @(
        $beginMarker
        foreach ($entry in $sshHosts.GetEnumerator()) {
            @"
Host $($entry.Key)
    HostName $($entry.Value)
    User $SshUser
    ProxyCommand "$proxyExecutable" access ssh --hostname %h
    PreferredAuthentications password
    PubkeyAuthentication no
    ServerAliveInterval 30
    ServerAliveCountMax 3
"@
        }
        $endMarker
    ) -join "`r`n"

    $existingContent = if (Test-Path $configPath) {
        [IO.File]::ReadAllText($configPath)
    } else {
        ''
    }
    $managedPattern = '(?ms)^' + [regex]::Escape($beginMarker) + '.*?^' + [regex]::Escape($endMarker) + '\r?\n?'
    $remainingContent = [regex]::Replace($existingContent, $managedPattern, '')
    $remainingContent = ($remainingContent -replace '^[\r\n]+', '').TrimEnd()
    $newContent = if ($remainingContent) {
        "$managedBlock`r`n`r`n$remainingContent`r`n"
    } else {
        "$managedBlock`r`n"
    }

    if ($newContent -ne $existingContent) {
        if (Test-Path $configPath) {
            $backupPath = "$configPath.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Copy-Item -Path $configPath -Destination $backupPath
            Write-Host "SSH config backup: $backupPath"
        }
        $utf8WithoutBom = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($configPath, $newContent, $utf8WithoutBom)
    }

    foreach ($alias in $sshHosts.Keys) {
        $resolved = & $SshPath -G $alias 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "OpenSSH could not parse host alias: $alias"
        }
        $expectedHostName = $sshHosts[$alias]
        if (-not ($resolved | Where-Object { $_ -match "^hostname\s+$([regex]::Escape($expectedHostName))$" })) {
            throw "Host alias $alias did not resolve to $expectedHostName"
        }
        if (-not ($resolved | Where-Object { $_ -match '^proxycommand\s+.*cloudflared.*access ssh' })) {
            throw "Host alias $alias is missing the cloudflared ProxyCommand"
        }
    }

    return $configPath
}

function Initialize-NasHostKey {
    param([string]$CloudflaredPath, [string]$SshPath, [string]$KnownHostsPath)

    $port = [int]$Settings.tunnelPort
    if (Test-TunnelPort -Port $port) { throw "Local port $port is already in use. Change tunnelPort in config.json." }
    $candidate = "$KnownHostsPath.candidate"
    $scanError = "$candidate.err"
    $tunnel = Start-Process -FilePath $CloudflaredPath -ArgumentList @(
        'access', 'tcp', '--hostname', $NasHostName, '--url', "127.0.0.1:$port"
    ) -WindowStyle Hidden -PassThru
    try {
        for ($attempt = 0; $attempt -lt 60; $attempt++) {
            if (Test-TunnelPort -Port $port) { break }
            $tunnel.Refresh()
            if ($tunnel.HasExited) { throw 'Cloudflare tunnel failed to start.' }
            Start-Sleep -Milliseconds 500
        }
        $sshDirectory = Split-Path -Parent $SshPath
        $scanner = Start-Process -FilePath (Join-Path $sshDirectory 'ssh-keyscan.exe') -ArgumentList @(
            '-T', '10', '-p', [string]$port, '127.0.0.1'
        ) -RedirectStandardOutput $candidate -RedirectStandardError $scanError -WindowStyle Hidden -Wait -PassThru
        if ($scanner.ExitCode -ne 0 -or (Get-Item -LiteralPath $candidate).Length -eq 0) {
            throw 'Could not read the NAS SSH host key.'
        }
        Write-Host 'Compare these SSH fingerprints with the ones supplied by your administrator:'
        & (Join-Path $sshDirectory 'ssh-keygen.exe') -lf $candidate
        if ((Read-Host 'Do the fingerprints match? [y/N]') -notmatch '^[yY]$') {
            throw 'SSH host key was not confirmed.'
        }
        Move-Item -LiteralPath $candidate -Destination $KnownHostsPath
    } finally {
        Stop-Process -Id $tunnel.Id -ErrorAction SilentlyContinue
        Wait-Process -Id $tunnel.Id -Timeout 10 -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $candidate, $scanError -Force -ErrorAction SilentlyContinue
    }
}

function Install-NasMount {
    param(
        [string]$CloudflaredPath,
        [string]$RclonePath,
        [string]$SshPath,
        [switch]$ResetPassword
    )

    Write-Step "Configuring the NAS SFTP remote and $($Settings.windowsMountDrive) mount"
    $runtimeDirectory = Join-Path $ProgramRoot 'rclone-nas'
    $runtimeScript = Join-Path $runtimeDirectory 'Nas-Mount.ps1'
    $knownHostsPath = Join-Path $runtimeDirectory ("known_hosts-{0}-{1}" -f $NasHostName, $Settings.tunnelPort)
    $configPath = Join-Path $runtimeDirectory 'rclone.conf'
    $passwordPath = Get-NasPasswordPath -Directory $runtimeDirectory -Config $Settings
    $sourceRuntimeScript = Join-Path $PSScriptRoot 'Nas-Mount.ps1'

    if (-not (Test-Path $sourceRuntimeScript)) {
        throw "NAS mount runtime script was not found: $sourceRuntimeScript"
    }
    New-Item -ItemType Directory -Force -Path $runtimeDirectory | Out-Null
    if (Test-Path -LiteralPath $runtimeScript) {
        & $runtimeScript stop
    }
    $metadataDirectory = Join-Path $env:LOCALAPPDATA 'rclone-nas\cache\vfsMeta'
    if ((Test-Path -LiteralPath $metadataDirectory) -and
        (Get-ChildItem -LiteralPath $metadataDirectory -Recurse -File | Select-String -Pattern '"Dirty"\s*:\s*true' -Quiet)) {
        throw 'Pending writes remain in the VFS cache. Start the installed mount, close files and wait for uploads before reinstalling.'
    }
    Copy-Item -Force -Path $sourceRuntimeScript -Destination $runtimeScript
    Copy-Item -Force -Path (Join-Path $PSScriptRoot 'Nas-Common.ps1') -Destination $runtimeDirectory
    $Settings | Add-Member -NotePropertyName rcloneExecutable -NotePropertyValue $RclonePath -Force
    $Settings | Add-Member -NotePropertyName cloudflaredExecutable -NotePropertyValue $CloudflaredPath -Force
    $Settings | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runtimeDirectory 'config.json') -Encoding UTF8

    if (-not (Test-Path -LiteralPath $knownHostsPath)) {
        Initialize-NasHostKey -CloudflaredPath $CloudflaredPath -SshPath $SshPath -KnownHostsPath $knownHostsPath
    }

    $configArguments = @(
        'host', '127.0.0.1',
        'user', $SshUser,
        'port', [string]$Settings.tunnelPort,
        'known_hosts_file', $knownHostsPath,
        'shell_type', 'unix'
    )
    $remoteExists = $false
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $existingRemotes = & $RclonePath listremotes --config $configPath --quiet
        if ($LASTEXITCODE -ne 0) {
            throw 'Could not read the rclone NAS configuration.'
        }
        $remoteExists = $existingRemotes -contains 'nas:'
    }

    if ($remoteExists) {
        & $RclonePath config update nas @configArguments --config $configPath --non-interactive --quiet | Out-Null
    } else {
        & $RclonePath config create nas sftp @configArguments --config $configPath --non-interactive --quiet | Out-Null
    }
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not configure the rclone NAS SFTP remote.'
    }

    if ($ResetPassword -or -not (Test-Path $passwordPath)) {
        $securePassword = Read-Host "SSH password for ${SshUser}@${NasHostName} (input is hidden)" -AsSecureString
        if ($securePassword.Length -eq 0) {
            throw 'The NAS SSH password cannot be empty.'
        }
        $credential = New-Object Management.Automation.PSCredential($SshUser, $securePassword)
        $plainPassword = $credential.GetNetworkCredential().Password
        try {
            $obscured = $plainPassword | & $RclonePath obscure -
            if ($LASTEXITCODE -ne 0) { throw 'rclone could not obscure the NAS password.' }
            ($obscured | Select-Object -First 1).Trim() | ConvertTo-SecureString -AsPlainText -Force |
                ConvertFrom-SecureString | Set-Content -LiteralPath $passwordPath -Encoding ASCII
        } finally {
            $plainPassword = $null
            $obscured = $null
        }
    } else {
        Write-Host 'Reusing the NAS password protected by Windows DPAPI.'
    }

    $startupDirectory = [Environment]::GetFolderPath('Startup')
    $shortcutPath = Join-Path $startupDirectory 'rclone-nas.lnk'
    $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $powershellPath
    $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" start' -f $runtimeScript
    $shortcut.WorkingDirectory = $runtimeDirectory
    $shortcut.Description = "Mount NAS storage as $($Settings.windowsMountDrive) with rclone"
    $shortcut.Save()

    $mountStarted = $false
    if (Test-IsAdministrator) {
        Write-Warning 'Run nas-mount.cmd restart from a normal PowerShell window to make the drive visible in Explorer.'
    } else {
        & $runtimeScript restart
        $mountStarted = $true
    }

    return @{
        RuntimeScript = $runtimeScript
        ConfigPath = $configPath
        StartupShortcut = $shortcutPath
        MountStarted = $mountStarted
    }
}

Write-Step 'Checking platform and required programs'
$architecture = Get-PlatformArchitecture
$cloudflaredPath = Install-Cloudflared -Architecture $architecture.Cloudflared
& $cloudflaredPath --version
if ($LASTEXITCODE -ne 0) { throw 'cloudflared did not start correctly.' }

if (-not $SkipAccessLogin) {
    Invoke-AccessLogin -CloudflaredPath $cloudflaredPath -HostNames @(@($NasHostName, $LabHostName) | Where-Object { $_ })
}

$rclonePath = Install-Rclone -Architecture $architecture.Rclone
$rcloneVersion = & $rclonePath version
if ($LASTEXITCODE -ne 0) { throw 'rclone did not start correctly.' }
Write-Host ($rcloneVersion | Select-Object -First 1)

Install-WinFsp

$sshPath = Ensure-OpenSshClient
$sshConfigPath = Set-SshConfig -CloudflaredPath $cloudflaredPath -SshPath $sshPath
$nasMount = Install-NasMount -CloudflaredPath $cloudflaredPath -RclonePath $rclonePath -SshPath $sshPath -ResetPassword:$ResetNasPassword

Write-Host "`nDeployment completed successfully." -ForegroundColor Green
Write-Host "SSH config: $sshConfigPath"
Write-Host "rclone config: $($nasMount.ConfigPath)"
if ($nasMount.MountStarted) {
    Write-Host "NAS mount: $($Settings.windowsMountDrive)"
} else {
    Write-Host 'NAS mount pending: run nas-mount.cmd restart from a normal PowerShell window.'
}
Write-Host 'Connect with: ssh nas'
if ($LabHostName) { Write-Host 'Connect with: ssh lab' }
