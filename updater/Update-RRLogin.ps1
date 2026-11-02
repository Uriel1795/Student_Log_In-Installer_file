#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the latest Student Log In release with no prompts. Run by the
    "RRLogin Updater" scheduled task as SYSTEM - not meant to be run by hand
    (though an admin can, to test).

.DESCRIPTION
    1. Reads update_info.json from GitHub.
    2. Compares its Version with the installed version (Add/Remove Programs).
    3. If newer: makes sure the .NET Desktop Runtime is installed, downloads
       the MSI, checks its SHA-256 against update_info.json, and installs it
       silently with msiexec.

    Skips (and tries again on the next run) while RRLogin is running, so a
    student's session is never interrupted.

    Log: C:\Program Files\RRLogin Updater\updater.log
#>
param(
    [string]$UpdateInfoUrl  = 'https://raw.githubusercontent.com/Uriel1795/Student-Log-In-Installer-file/main/update_info.json',
    [string]$MsiUrlTemplate = 'https://raw.githubusercontent.com/Uriel1795/Student-Log-In-Installer-file/main/v{0}/Student_Log_In.msi',

    # Must match the name shown in Add/Remove Programs.
    [string]$ProductName = 'Student Log In',

    [int]$RequiredDotnetMajor = 10
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # progress bars make downloads ~10x slower in PowerShell 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$WorkDir = Join-Path $Root 'work'
$LogPath = Join-Path $Root 'updater.log'
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

function Write-Log([string]$Message) {
    if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt 1MB) {
        Move-Item $LogPath "$LogPath.old" -Force
    }
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Message" | Add-Content -Path $LogPath -Encoding UTF8
}

# "2.2" and "2.2.0" must compare as equal, or a PC would reinstall forever.
function ConvertTo-Version([string]$Text) {
    $parts = @($Text.Trim().Split('.') | Select-Object -First 3)
    while ($parts.Count -lt 3) { $parts += '0' }
    return [version]($parts -join '.')
}

function Get-InstalledVersion {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $entry = Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -eq $ProductName -and $_.DisplayVersion } |
        Select-Object -First 1

    if ($entry) { return ConvertTo-Version $entry.DisplayVersion }
    return $null
}

function Install-DotnetRuntimeIfMissing {
    $shared = Join-Path $env:ProgramFiles 'dotnet\shared\Microsoft.WindowsDesktop.App'
    $present = (Test-Path $shared) -and
        (Get-ChildItem $shared -Directory | Where-Object { $_.Name -like "$RequiredDotnetMajor.*" })

    if ($present) { return }

    Write-Log ".NET $RequiredDotnetMajor Desktop Runtime missing - installing it."
    $exe = Join-Path $WorkDir 'windowsdesktop-runtime.exe'
    Invoke-WebRequest "https://aka.ms/dotnet/$RequiredDotnetMajor.0/windowsdesktop-runtime-win-x64.exe" `
        -OutFile $exe -UseBasicParsing -TimeoutSec 600

    # Only run it if Microsoft really signed it.
    $sig = Get-AuthenticodeSignature $exe
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notlike '*O=Microsoft Corporation*') {
        Remove-Item $exe -Force -ErrorAction SilentlyContinue
        throw ".NET runtime download failed its signature check ($($sig.Status)) - not installed."
    }

    $p = Start-Process $exe -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru
    Remove-Item $exe -Force -ErrorAction SilentlyContinue

    if ($p.ExitCode -notin 0, 3010) {
        throw ".NET runtime installer exited with code $($p.ExitCode)."
    }
    Write-Log ".NET $RequiredDotnetMajor Desktop Runtime installed."
}

try {
    $info = Invoke-RestMethod -Uri $UpdateInfoUrl -UseBasicParsing -TimeoutSec 30
    if (-not $info.Version) { throw 'update_info.json has no Version.' }

    $latest    = ConvertTo-Version ([string]$info.Version)
    $installed = Get-InstalledVersion

    if ($installed -and $installed -ge $latest) {
        exit 0   # up to date - nothing to log every hour
    }

    $from = if ($installed) { $installed } else { 'not installed' }
    Write-Log "Update available: $from -> $latest"

    # SYSTEM never runs an MSI it can't verify.
    if (-not $info.Sha256) {
        Write-Log 'update_info.json has no Sha256 - refusing to install. Add the hash and it will run next time.'
        exit 1
    }

    if (Get-Process -Name 'RRLogin' -ErrorAction SilentlyContinue) {
        Write-Log 'RRLogin is running (a student is logged in) - will try again next run.'
        exit 0
    }

    Install-DotnetRuntimeIfMissing

    $msi = Join-Path $WorkDir "Student_Log_In-$($info.Version).msi"
    Invoke-WebRequest -Uri ($MsiUrlTemplate -f $info.Version) -OutFile $msi -UseBasicParsing -TimeoutSec 600

    $actual = (Get-FileHash $msi -Algorithm SHA256).Hash
    if ($actual -ne ([string]$info.Sha256).Trim().ToUpperInvariant()) {
        Remove-Item $msi -Force -ErrorAction SilentlyContinue
        Write-Log "Hash mismatch: expected $($info.Sha256), got $actual - NOT installed."
        exit 1
    }

    $msiLog = Join-Path $WorkDir 'msi-install.log'
    $p = Start-Process 'msiexec.exe' -Wait -PassThru -ArgumentList @(
        '/i', "`"$msi`"", '/qn', '/norestart', '/l*v', "`"$msiLog`""
    )
    Remove-Item $msi -Force -ErrorAction SilentlyContinue

    switch ($p.ExitCode) {
        0       { Write-Log "Installed $latest." }
        3010    { Write-Log "Installed $latest (finishes on next reboot)." }
        1641    { Write-Log "Installed $latest (reboot started by installer)." }
        1618    { Write-Log 'Another install is in progress - will try again next run.' }
        default { Write-Log "msiexec failed with code $($p.ExitCode). Details: $msiLog"; exit 1 }
    }
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    exit 1
}
