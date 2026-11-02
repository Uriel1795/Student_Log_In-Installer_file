#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    One-time per lab PC: registers this computer with rrlogin-api and saves
    its API key, encrypted, to C:\ProgramData\Student Log In\api_key.bin.

.DESCRIPTION
    - If this PC already has a working key, it does nothing (no admin key
      needed), so running setup again is harmless.
    - Otherwise it asks for your admin key (typed, never shown, never saved),
      registers the PC under its computer name, and stores the new key with
      Windows DPAPI (LocalMachine) so it only decrypts on this PC.
    - If the PC was registered before (e.g. Windows was reinstalled), it
      rotates the key instead: the old key stops working.
#>
param(
    # Your Railway public domain. Not a secret - fine to keep in GitHub.
    [string]$ApiBaseUrl = 'https://studentlogin-sourcecode-production.up.railway.app',

    [string]$ComputerName = $env:COMPUTERNAME
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Security

$ApiBaseUrl = $ApiBaseUrl.TrimEnd('/')
if ($ApiBaseUrl -like '*YOUR-API*') {
    throw 'Set $ApiBaseUrl at the top of Set-RRLoginApiKey.ps1 to your Railway domain first.'
}

$Dir     = Join-Path $env:ProgramData 'Student Log In'
$KeyFile = Join-Path $Dir 'api_key.bin'

# Calls the API and returns the status code and parsed body, including for
# 4xx/5xx (which Invoke-WebRequest otherwise throws on).
function Invoke-Api([string]$Method, [string]$Path, [hashtable]$Headers, $Body = $null) {
    $params = @{
        Uri = "$ApiBaseUrl$Path"; Method = $Method; Headers = $Headers
        UseBasicParsing = $true; TimeoutSec = 30
    }
    if ($null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json)
        $params.ContentType = 'application/json'
    }

    try {
        $r = Invoke-WebRequest @params
        $data = if ($r.Content) { $r.Content | ConvertFrom-Json } else { $null }
        return [pscustomobject]@{ Status = [int]$r.StatusCode; Data = $data }
    }
    catch {
        $resp = $_.Exception.Response
        if ($resp) { return [pscustomobject]@{ Status = [int]$resp.StatusCode; Data = $null } }
        throw "Could not reach $ApiBaseUrl - $($_.Exception.Message)"
    }
}

function Test-PcKey([string]$Key) {
    (Invoke-Api 'GET' '/v1/whoami' @{ 'X-Api-Key' = $Key }).Status -eq 200
}

# 1. Already set up? Then there's nothing to do.
if (Test-Path $KeyFile) {
    try {
        $existing = [Text.Encoding]::UTF8.GetString(
            [Security.Cryptography.ProtectedData]::Unprotect(
                [IO.File]::ReadAllBytes($KeyFile), $null, 'LocalMachine'))

        if (Test-PcKey $existing) {
            Write-Host "API key already set up for $ComputerName and working. Nothing to do." -ForegroundColor Green
            return
        }
        Write-Host 'Saved key no longer works (revoked or rotated) - getting a new one.' -ForegroundColor Yellow
    }
    catch {
        Write-Host 'Saved key file is unreadable - getting a new one.' -ForegroundColor Yellow
    }
}

# 2. Ask for the admin key. Held in memory only for this script.
$secure = Read-Host 'Admin key (X-Admin-Key)' -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try   { $adminKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
$admin = @{ 'X-Admin-Key' = $adminKey }

# 3. Register this PC, or rotate its key if it's already registered.
$r = Invoke-Api 'POST' '/admin/computers' $admin @{ name = $ComputerName }

if ($r.Status -eq 409) {
    $list = Invoke-Api 'GET' '/admin/computers' $admin
    $pc = @($list.Data) | Where-Object { $_.name -eq $ComputerName } | Select-Object -First 1
    if (-not $pc) { throw "API says $ComputerName exists but it isn't in the computer list." }

    Write-Host "$ComputerName was registered before - rotating its key." -ForegroundColor Yellow
    $r = Invoke-Api 'POST' "/admin/computers/$($pc.id)/rotate-key" $admin
}

switch ($r.Status) {
    200     { }
    401     { throw 'Admin key was rejected. Check it matches ADMIN_API_KEY on Railway.' }
    429     { throw 'Too many admin requests - wait a minute and run this again.' }
    503     { throw 'ADMIN_API_KEY is not set on the Railway service.' }
    default { throw "Registration failed with HTTP $($r.Status)." }
}

$key = [string]$r.Data.apiKey
$adminKey = $null; $admin = $null

# 4. Save it. Folder locked so students can read the file (the app needs to)
#    but can't replace or delete it. SIDs work on any Windows language.
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
icacls $Dir /inheritance:r `
    /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null

$encrypted = [Security.Cryptography.ProtectedData]::Protect(
    [Text.Encoding]::UTF8.GetBytes($key), $null, 'LocalMachine')
[IO.File]::WriteAllBytes($KeyFile, $encrypted)

# 5. Prove it works.
if (Test-PcKey $key) {
    Write-Host "Done. $ComputerName is registered and its key is saved." -ForegroundColor Green
}
else {
    throw 'Key was saved but /v1/whoami rejected it. Run this script again.'
}
