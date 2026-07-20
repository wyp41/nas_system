#requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$SkipAccessLogin
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$NasHostName = 'nas.wyp.life'
$LabHostName = 'lab.wyp.life'
$SshUser = 'wyp'
$ProgramRoot = Join-Path $env:LOCALAPPDATA 'Programs'

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

    $existing = Get-Command cloudflared.exe -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "cloudflared already exists: $($existing.Source)"
        return $existing.Source
    }

    Write-Step 'Downloading cloudflared from the official GitHub release'
    $installDirectory = Join-Path $ProgramRoot 'cloudflared'
    $executable = Join-Path $installDirectory 'cloudflared.exe'
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

    $existing = Get-Command rclone.exe -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "rclone already exists: $($existing.Source)"
        return $existing.Source
    }

    Write-Step 'Downloading rclone from downloads.rclone.org'
    $installDirectory = Join-Path $ProgramRoot 'rclone'
    $executable = Join-Path $installDirectory 'rclone.exe'
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
        $checksums = (Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/SHA256SUMS").Content
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

function Ensure-OpenSshClient {
    $existing = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "OpenSSH Client already exists: $($existing.Source)"
        return $existing.Source
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdministrator) {
        throw 'OpenSSH Client is missing. Re-run this installer from an Administrator PowerShell window.'
    }

    Write-Step 'Installing the Windows OpenSSH Client capability'
    $capabilityName = 'OpenSSH.Client~~~~0.0.1.0'
    $capability = Get-WindowsCapability -Online -Name $capabilityName
    if ($capability.State -ne 'Installed') {
        Add-WindowsCapability -Online -Name $capabilityName | Out-Null
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

    $managedBlock = @"
$beginMarker
Host nas
    HostName $NasHostName
    User $SshUser
    ProxyCommand "$proxyExecutable" access ssh --hostname %h
    PreferredAuthentications password
    PubkeyAuthentication no
    ServerAliveInterval 30
    ServerAliveCountMax 3

Host lab
    HostName $LabHostName
    User $SshUser
    ProxyCommand "$proxyExecutable" access ssh --hostname %h
    PreferredAuthentications password
    PubkeyAuthentication no
    ServerAliveInterval 30
    ServerAliveCountMax 3
$endMarker
"@

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

    foreach ($alias in @('nas', 'lab')) {
        $resolved = & $SshPath -G $alias 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "OpenSSH could not parse host alias: $alias"
        }
        $expectedHostName = if ($alias -eq 'nas') { $NasHostName } else { $LabHostName }
        if (-not ($resolved | Where-Object { $_ -match "^hostname\s+$([regex]::Escape($expectedHostName))$" })) {
            throw "Host alias $alias did not resolve to $expectedHostName"
        }
        if (-not ($resolved | Where-Object { $_ -match '^proxycommand\s+.*cloudflared.*access ssh' })) {
            throw "Host alias $alias is missing the cloudflared ProxyCommand"
        }
    }

    return $configPath
}

Write-Step 'Checking platform and required programs'
$architecture = Get-PlatformArchitecture
$cloudflaredPath = Install-Cloudflared -Architecture $architecture.Cloudflared
& $cloudflaredPath --version
if ($LASTEXITCODE -ne 0) { throw 'cloudflared did not start correctly.' }

if (-not $SkipAccessLogin) {
    Invoke-AccessLogin -CloudflaredPath $cloudflaredPath -HostNames @($NasHostName, $LabHostName)
}

$rclonePath = Install-Rclone -Architecture $architecture.Rclone
$rcloneVersion = & $rclonePath version
if ($LASTEXITCODE -ne 0) { throw 'rclone did not start correctly.' }
Write-Host ($rcloneVersion | Select-Object -First 1)

$sshPath = Ensure-OpenSshClient
$sshConfigPath = Set-SshConfig -CloudflaredPath $cloudflaredPath -SshPath $sshPath

Write-Host "`nDeployment completed successfully." -ForegroundColor Green
Write-Host "SSH config: $sshConfigPath"
Write-Host 'Connect with: ssh nas'
Write-Host 'Connect with: ssh lab'
