#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    One-time setup per lab PC. Installs the Student Log In auto-updater:
    copies Update-RRLogin.ps1 to "C:\Program Files\RRLogin Updater" and
    registers a scheduled task that runs it as SYSTEM at startup and every
    hour.

.EXAMPLE
    Right-click PowerShell -> Run as administrator, then:
    Set-ExecutionPolicy -Scope Process Bypass
    .\Install-RRLoginUpdater.ps1
#>

$ErrorActionPreference = 'Stop'
$TaskName = 'RRLogin Updater'
$Dest     = Join-Path $env:ProgramFiles 'RRLogin Updater'
$Source   = Join-Path $PSScriptRoot 'Update-RRLogin.ps1'

if (-not (Test-Path $Source)) { throw "Update-RRLogin.ps1 must be in the same folder as this script." }

New-Item -ItemType Directory -Force -Path $Dest | Out-Null
Copy-Item $Source $Dest -Force

# IMPORTANT: this script runs as SYSTEM. If students could edit it, they
# could make it run anything as SYSTEM. Lock the folder: Administrators and
# SYSTEM full control, Users read-only. SIDs instead of names so this works
# on non-English Windows.
icacls $Dest /inheritance:r `
    /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null

$powershell = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
$action = New-ScheduledTaskAction -Execute $powershell `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Dest\Update-RRLogin.ps1`""

# At startup (after 2 minutes, so the network is up), then every hour.
# Hourly matters: the updater skips while a student is logged in, so it
# needs another chance once they log out.
$atStartup = New-ScheduledTaskTrigger -AtStartup
$atStartup.Delay = 'PT2M'
$hourly = New-ScheduledTaskTrigger -Once -At (Get-Date).Date `
    -RepetitionInterval (New-TimeSpan -Hours 1) -RandomDelay (New-TimeSpan -Minutes 10)

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($atStartup, $hourly) `
    -Principal $principal -Settings $settings -Force | Out-Null

Start-ScheduledTask -TaskName $TaskName
Write-Host "Installed. The first check is running now. Log: $Dest\updater.log"
